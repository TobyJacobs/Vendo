-- Venue submission and verification.
-- Venue owners add a venue, upload photos and their documents, and submit it for review.
-- An admin checks the owner's ID, premises licence and public liability insurance, then approves it.
-- The "Verified venue" badge shows only while all three checks are ticked.

alter table public.venues
  add column if not exists verified    boolean not null default false,
  add column if not exists photos      text[]  not null default '{}' check (cardinality(photos) <= 8),
  add column if not exists review_note text check (review_note is null or char_length(review_note) <= 1000),
  add column if not exists postcode    text check (postcode is null or char_length(postcode) <= 10);
comment on column public.venues.verified    is 'Set only by approve_venue(); cleared when an admin unticks a check.';
comment on column public.venues.review_note is 'What an admin asked the owner to change before the venue can be approved.';

-- The demo venues were written and checked by Vendo.
update public.venues set verified = true where is_demo;

-- Owners can't verify themselves, mark a venue as a demo, or edit the admin's note.
create or replace function public.guard_admin_fields() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or public.is_admin() then return new; end if;   -- server-side jobs and admins
  -- Separate IFs: PL/pgSQL doesn't short-circuit AND, so a profiles field must not be read on a venues row.
  if tg_table_name = 'profiles' then
    if new.is_admin is distinct from old.is_admin then
      raise exception 'Only an admin can change admin access';
    end if;
  elsif tg_table_name = 'venues' then
    if new.status = 'live' and old.status is distinct from 'live' then
      raise exception 'A Vendo admin reviews new venues before they go live';
    end if;
    if new.verified is distinct from old.verified or new.is_demo is distinct from old.is_demo
       or new.review_note is distinct from old.review_note then
      raise exception 'Only a Vendo admin can change verification';
    end if;
  end if;
  return new;
end $$;

drop policy if exists "Owners create venues" on public.venues;
create policy "Owners create venues" on public.venues for insert to authenticated
  with check (owner_id = (select auth.uid()) and status in ('draft', 'pending_review')
              and not verified and not is_demo and review_note is null);

-- ---------------------------------------------------------------------------
-- What the owner tells us, and where their documents are. Owners and admins only.
-- ---------------------------------------------------------------------------
create table if not exists public.venue_docs (
  venue_id            uuid primary key references public.venues (id) on delete cascade,
  legal_name          text check (legal_name is null or char_length(legal_name) <= 120),
  sells_alcohol       boolean not null default true,
  licence_number      text check (licence_number is null or char_length(licence_number) <= 60),
  licence_council     text check (licence_council is null or char_length(licence_council) <= 80),
  insurance_provider  text check (insurance_provider is null or char_length(insurance_provider) <= 80),
  insurance_cover     text check (insurance_cover is null or char_length(insurance_cover) <= 40),
  insurance_expiry    date,
  id_path             text,
  licence_path        text,
  insurance_path      text,
  submitted_at        timestamptz,
  updated_at          timestamptz not null default now(),
  -- Files must sit in the venue's own folder.
  check (id_path        is null or id_path        like venue_id::text || '/%'),
  check (licence_path   is null or licence_path   like venue_id::text || '/%'),
  check (insurance_path is null or insurance_path like venue_id::text || '/%')
);
drop trigger if exists venue_docs_updated on public.venue_docs;
create trigger venue_docs_updated before update on public.venue_docs for each row execute function public.set_updated_at();
alter table public.venue_docs enable row level security;
drop policy if exists "Owners manage own venue documents" on public.venue_docs;
create policy "Owners manage own venue documents" on public.venue_docs for all to authenticated
  using (public.owns_venue(venue_id) or public.is_admin()) with check (public.owns_venue(venue_id) or public.is_admin());

-- ---------------------------------------------------------------------------
-- The admin's checks. Admins only.
-- ---------------------------------------------------------------------------
create table if not exists public.venue_checks (
  venue_id      uuid primary key references public.venues (id) on delete cascade,
  id_ok         boolean not null default false,
  licence_ok    boolean not null default false,   -- licence checked, or not needed (no alcohol or regulated entertainment)
  insurance_ok  boolean not null default false,
  notes         text check (notes is null or char_length(notes) <= 2000),
  checked_by    uuid references public.profiles (id) on delete set null,
  checked_at    timestamptz not null default now()
);
alter table public.venue_checks enable row level security;
drop policy if exists "Admins manage venue checks" on public.venue_checks;
create policy "Admins manage venue checks" on public.venue_checks for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Unticking any check takes the badge away straight away.
create or replace function public.venue_checks_badge() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not (new.id_ok and new.licence_ok and new.insurance_ok) then
    update public.venues set verified = false where id = new.venue_id and verified;
  end if;
  return new;
end $$;
drop trigger if exists venue_checks_badge on public.venue_checks;
create trigger venue_checks_badge after insert or update on public.venue_checks
  for each row execute function public.venue_checks_badge();

-- Approve: all three checks must be ticked. Puts the venue live with the badge.
create or replace function public.approve_venue(p_venue uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Admins only' using errcode = '42501'; end if;
  if not exists (select 1 from public.venue_checks c where c.venue_id = p_venue and c.id_ok and c.licence_ok and c.insurance_ok) then
    raise exception 'Tick all three checks before approving';
  end if;
  update public.venues set status = 'live', verified = true, review_note = null where id = p_venue;
  if not found then raise exception 'Venue not found'; end if;
end $$;

-- Send back: the venue returns to draft with a note telling the owner what to change.
create or replace function public.send_back_venue(p_venue uuid, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Admins only' using errcode = '42501'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Say what needs changing'; end if;
  update public.venues set status = 'draft', verified = false, review_note = left(trim(p_note), 1000) where id = p_venue;
  if not found then raise exception 'Venue not found'; end if;
end $$;
revoke all on function public.approve_venue(uuid), public.send_back_venue(uuid, text) from public, anon;
grant execute on function public.approve_venue(uuid), public.send_back_venue(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- File storage. Paths are "{venue id}/{file}".
--   venue-docs   private: only the venue's owner and admins can open these.
--   venue-photos public:  listing photos, readable by anyone with the link.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('venue-docs',   'venue-docs',   false, 10485760, array['image/jpeg', 'image/png', 'image/heic', 'image/webp', 'application/pdf']),
  ('venue-photos', 'venue-photos', true,  8388608,  array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- True when the first folder of a storage path is a venue you own.
create or replace function public.owns_venue_folder(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.venues v
                  where v.id::text = (storage.foldername(p_name))[1] and v.owner_id = auth.uid())
$$;

drop policy if exists "Venue docs: owners and admins read"  on storage.objects;
drop policy if exists "Venue docs: owners upload"           on storage.objects;
drop policy if exists "Venue docs: owners replace"          on storage.objects;
drop policy if exists "Venue docs: owners delete"           on storage.objects;
drop policy if exists "Venue photos: owners upload"         on storage.objects;
drop policy if exists "Venue photos: owners replace"        on storage.objects;
drop policy if exists "Venue photos: owners delete"         on storage.objects;

create policy "Venue docs: owners and admins read" on storage.objects for select to authenticated
  using (bucket_id = 'venue-docs' and (public.owns_venue_folder(name) or public.is_admin()));
create policy "Venue docs: owners upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'venue-docs' and public.owns_venue_folder(name));
create policy "Venue docs: owners replace" on storage.objects for update to authenticated
  using (bucket_id = 'venue-docs' and public.owns_venue_folder(name))
  with check (bucket_id = 'venue-docs' and public.owns_venue_folder(name));
create policy "Venue docs: owners delete" on storage.objects for delete to authenticated
  using (bucket_id = 'venue-docs' and (public.owns_venue_folder(name) or public.is_admin()));

create policy "Venue photos: owners upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'venue-photos' and (public.owns_venue_folder(name) or public.is_admin()));
create policy "Venue photos: owners replace" on storage.objects for update to authenticated
  using (bucket_id = 'venue-photos' and (public.owns_venue_folder(name) or public.is_admin()))
  with check (bucket_id = 'venue-photos' and (public.owns_venue_folder(name) or public.is_admin()));
create policy "Venue photos: owners delete" on storage.objects for delete to authenticated
  using (bucket_id = 'venue-photos' and (public.owns_venue_folder(name) or public.is_admin()));

drop policy if exists "Venue photos: owners read" on storage.objects;
create policy "Venue photos: owners read" on storage.objects for select to authenticated
  using (bucket_id = 'venue-photos' and (public.owns_venue_folder(name) or public.is_admin()));

-- ---------------------------------------------------------------------------
-- Admin dashboard: pending venues now include the owner's email and when they submitted.
-- ---------------------------------------------------------------------------
-- Every figure the dashboard needs, in one call. Admins only.
-- Vendo's takings on a booking = the guest booking fee (4%) + the venue commission (8% of hire).
-- Card fees are estimated at 1.5% + 20p per paid booking (Stripe's UK card rate).
create or replace function public.admin_stats() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  if not public.is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;
  with b as (
    select k.*, k.status in ('confirmed', 'completed') as won,
           k.fee_pence + round(k.hire_pence * 0.08)::int as vendo_pence,
           round(k.total_pence * 0.015)::int + 20 as card_pence
      from public.bookings k
  ), months as (
    select generate_series(date_trunc('month', now()) - interval '11 months', date_trunc('month', now()), interval '1 month') as m
  )
  select jsonb_build_object(
    'generated_at', now(),
    'venues', coalesce((select jsonb_object_agg(status, n) from (select status::text, count(*) n from public.venues group by status) x), '{}'::jsonb),
    'venues_demo', (select count(*) from public.venues where is_demo),
    'customers', (select count(*) from public.profiles where account_type = 'guest'),
    'hosts', (select count(*) from public.profiles where account_type = 'host'),
    'signups_30d', (select count(*) from public.profiles where created_at > now() - interval '30 days'),
    'bookings', coalesce((select jsonb_object_agg(status, n) from (select status::text, count(*) n from b group by status) x), '{}'::jsonb),
    'gmv_pence', (select coalesce(sum(total_pence), 0) from b where won),
    'pipeline_pence', (select coalesce(sum(total_pence), 0) from b where status = 'requested'),
    'vendo_pence', (select coalesce(sum(vendo_pence), 0) from b where won),
    'card_pence', (select coalesce(sum(card_pence), 0) from b where won),
    'costs_monthly_pence', (select coalesce(sum(monthly_pence), 0) from public.admin_costs),
    'months', (select jsonb_agg(jsonb_build_object(
        'm', to_char(m, 'YYYY-MM'),
        'bookings', (select count(*) from b where date_trunc('month', b.created_at) = months.m),
        'gmv', (select coalesce(sum(total_pence), 0) from b where won and date_trunc('month', b.created_at) = months.m),
        'vendo', (select coalesce(sum(vendo_pence), 0) from b where won and date_trunc('month', b.created_at) = months.m),
        'card', (select coalesce(sum(card_pence), 0) from b where won and date_trunc('month', b.created_at) = months.m),
        'signups', (select count(*) from public.profiles p where date_trunc('month', p.created_at) = months.m)
      ) order by m) from months),
    'top_venues', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select v.name, v.slug, v.status::text, count(b.id) as bookings,
               coalesce(sum(b.total_pence) filter (where b.won), 0) as gmv
          from public.venues v left join b on b.venue_id = v.id
         group by v.id order by count(b.id) desc, v.name limit 8) t),
    'event_types', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select event_type, count(*) as n from b group by event_type order by count(*) desc limit 8) t),
    'recent_bookings', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select b.ref, b.status::text, b.event_label, b.event_date, b.guests, b.total_pence, b.created_at, b.contact_name, v.name as venue
          from b join public.venues v on v.id = b.venue_id order by b.created_at desc limit 10) t),
    'recent_signups', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select p.full_name, u.email, p.account_type, p.business_name, p.created_at
          from public.profiles p join auth.users u on u.id = p.id order by p.created_at desc limit 10) t),
    'pending_venues', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select v.id, v.name, v.place, v.kind, v.created_at, v.updated_at, p.full_name as owner, p.business_name, u.email as owner_email,
               d.submitted_at
          from public.venues v left join public.profiles p on p.id = v.owner_id left join auth.users u on u.id = v.owner_id
          left join public.venue_docs d on d.venue_id = v.id
         where v.status = 'pending_review' order by coalesce(d.submitted_at, v.created_at)) t),
    'verified_venues', (select count(*) from public.venues where verified and status = 'live')
  ) into r;
  return r;
end $$;
revoke all on function public.admin_stats() from public, anon;
grant execute on function public.admin_stats() to authenticated;
