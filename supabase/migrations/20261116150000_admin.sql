-- Admin access and the admin dashboard.
-- Admins are listed by email. Anyone on the list gets admin access when they create their account
-- (or straight away, if the account already exists). Nobody can give themselves admin access.

create table if not exists public.admin_emails (
  email     citext primary key,
  added_at  timestamptz not null default now()
);
alter table public.admin_emails enable row level security;   -- no policies: only the database itself reads it

insert into public.admin_emails (email) values ('tobyjacobs18@icloud.com') on conflict do nothing;

-- Runs after handle_new_user (triggers on the same table fire in name order), so the profile exists.
-- Compares lower-cased text: with an empty search_path the citext type isn't visible inside the function.
create or replace function public.apply_admin_list() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.profiles set is_admin = true
   where id = new.id and exists (select 1 from public.admin_emails a where lower(a.email::text) = lower(new.email));
  return new;
end $$;
drop trigger if exists on_auth_user_created_then_admin on auth.users;
create trigger on_auth_user_created_then_admin after insert on auth.users
  for each row execute function public.apply_admin_list();

-- Accounts that already exist.
update public.profiles p set is_admin = true
  from auth.users u where u.id = p.id and u.email::citext in (select email from public.admin_emails);

-- Running costs, so the dashboard can show profit. Only admins can see or change them.
create table if not exists public.admin_costs (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (char_length(name) between 1 and 80),
  monthly_pence  int  not null check (monthly_pence between 0 and 100000000),
  created_at     timestamptz not null default now()
);
alter table public.admin_costs enable row level security;
drop policy if exists "Admins manage costs" on public.admin_costs;
create policy "Admins manage costs" on public.admin_costs for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
insert into public.admin_costs (name, monthly_pence)
  select 'vendohire.com domain ($18 a year)', 120
  where not exists (select 1 from public.admin_costs);

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
        select v.id, v.name, v.place, v.kind, v.created_at, p.full_name as owner, p.business_name
          from public.venues v left join public.profiles p on p.id = v.owner_id
         where v.status = 'pending_review' order by v.created_at) t)
  ) into r;
  return r;
end $$;
revoke all on function public.admin_stats() from public, anon;
grant execute on function public.admin_stats() to authenticated;
