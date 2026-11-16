-- Vendo database: venues, rooms, availability, bookings, messages and two-way ratings.
-- Money is stored in pence (integers). Times are UK local dates and times.
-- Row level security is on for every table: people only see and change what they should.

create extension if not exists citext;

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------
create type public.venue_status as enum ('draft', 'pending_review', 'live', 'hidden');
create type public.cancellation_policy as enum ('flexible', 'moderate', 'strict');
create type public.booking_status as enum ('requested', 'confirmed', 'declined', 'cancelled', 'completed');
create type public.payment_plan as enum ('deposit', 'full');
create type public.block_kind as enum ('booking', 'block');
create type public.booking_source as enum ('phone', 'in_person', 'email', 'other');
create type public.payout_status as enum ('held', 'scheduled', 'paid');

-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------
-- One row per signed-up person, created automatically from Supabase Auth.
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text not null default '',
  phone       text,
  town        text,
  is_admin    boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table public.profiles is 'Guests and venue owners. Phone numbers are shared with a venue only once a booking is confirmed.';

-- ---------------------------------------------------------------------------
-- Venues and what they offer
-- ---------------------------------------------------------------------------
create table public.venues (
  id                   uuid primary key default gen_random_uuid(),
  slug                 text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  owner_id             uuid references public.profiles (id) on delete set null,
  status               public.venue_status not null default 'draft',
  is_demo              boolean not null default false,
  name                 text not null,
  kind                 text not null,                 -- e.g. 'Pub function room'
  venue_type           text not null,                 -- pub, hall, bar, club, leisure, barn ...
  place                text not null,                 -- 'Netherby St Clare, Gloucestershire'
  region               text not null,
  lat                  double precision,
  lng                  double precision,
  space_title          text not null default '',
  blurb                text not null default '',
  suits                text[] not null default '{}',  -- Weddings, Birthdays, Wakes ...
  features             text[] not null default '{}',
  house_rules          text[] not null default '{}',
  instant_book         boolean not null default false,
  reply_note           text,
  step_free            boolean not null default false,
  licensed_bar         boolean not null default false,
  outdoor_space        boolean not null default false,
  cancellation_policy  public.cancellation_policy not null default 'moderate',
  -- Good to know
  finish_time          text,
  music_note           text,
  parking              text,
  getting_there        text,
  own_cake_decor       text,
  if_it_rains          text,
  -- Price changes by day, in percent (e.g. -15 Mon to Thu, +10 Saturdays)
  pct_mon_thu          smallint not null default 0 check (pct_mon_thu between -50 and 100),
  pct_fri              smallint not null default 0 check (pct_fri between -50 and 100),
  pct_sat              smallint not null default 0 check (pct_sat between -50 and 100),
  pct_sun              smallint not null default 0 check (pct_sun between -50 and 100),
  pct_december         smallint not null default 0 check (pct_december between -50 and 100),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index venues_status_idx on public.venues (status);
create index venues_owner_idx on public.venues (owner_id);
create index venues_region_idx on public.venues (region);

create table public.rooms (
  id               uuid primary key default gen_random_uuid(),
  venue_id         uuid not null references public.venues (id) on delete cascade,
  name             text not null,
  note             text,
  seated           int not null check (seated >= 0),
  standing         int not null check (standing >= 0),
  hour_price_pence int not null check (hour_price_pence >= 0),
  day_price_pence  int not null check (day_price_pence >= 0),
  min_hours        smallint not null default 2 check (min_hours between 1 and 24),
  is_listed        boolean not null default true,
  sort_order       smallint not null default 0,
  created_at       timestamptz not null default now(),
  unique (venue_id, name)
);
create index rooms_venue_idx on public.rooms (venue_id);

create table public.addons (
  id           uuid primary key default gen_random_uuid(),
  venue_id     uuid not null references public.venues (id) on delete cascade,
  label        text not null,
  price_pence  int not null check (price_pence >= 0),
  per_head     boolean not null default false,
  sort_order   smallint not null default 0
);
create index addons_venue_idx on public.addons (venue_id);

-- ---------------------------------------------------------------------------
-- Availability the venue manages itself (phone bookings, closed dates)
-- ---------------------------------------------------------------------------
create table public.availability_blocks (
  id           uuid primary key default gen_random_uuid(),
  venue_id     uuid not null references public.venues (id) on delete cascade,
  room_id      uuid references public.rooms (id) on delete cascade,   -- null = whole venue
  day          date not null,
  kind         public.block_kind not null,
  guest_name   text,
  event_label  text,
  start_time   time,
  end_time     time,
  guests       int check (guests is null or guests > 0),
  source       public.booking_source,
  price_pence  int check (price_pence is null or price_pence >= 0),
  note         text,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);
create index blocks_venue_day_idx on public.availability_blocks (venue_id, day);

-- ---------------------------------------------------------------------------
-- Bookings made on Vendo
-- ---------------------------------------------------------------------------
create table public.bookings (
  id                 uuid primary key default gen_random_uuid(),
  ref                text not null unique default ('VND-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))),
  venue_id           uuid not null references public.venues (id) on delete restrict,
  room_id            uuid references public.rooms (id) on delete set null,
  guest_id           uuid not null references public.profiles (id) on delete restrict,
  status             public.booking_status not null default 'requested',
  event_date         date not null,
  start_time         time not null,
  hours              smallint not null check (hours between 1 and 24),
  guests             int not null check (guests > 0),
  event_type         text not null,
  event_label        text not null,
  notes              text,
  contact_name       text not null,
  contact_email      citext not null,
  contact_phone      text not null,
  payment_plan       public.payment_plan not null default 'deposit',
  hire_pence         int not null check (hire_pence >= 0),
  extras_pence       int not null default 0 check (extras_pence >= 0),
  fee_pence          int not null check (fee_pence >= 0),         -- guest booking fee (4%)
  total_pence        int not null check (total_pence >= 0),
  deposit_pence      int not null default 0 check (deposit_pence >= 0),
  balance_due_on     date,
  damage_hold_pence  int not null default 0 check (damage_hold_pence >= 0),
  checklist_done     smallint[] not null default '{}',
  stripe_payment_intent text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index bookings_venue_date_idx on public.bookings (venue_id, event_date);
create index bookings_guest_idx on public.bookings (guest_id);

create table public.booking_addons (
  booking_id   uuid not null references public.bookings (id) on delete cascade,
  addon_id     uuid references public.addons (id) on delete set null,
  label        text not null,
  price_pence  int not null check (price_pence >= 0),
  quantity     int not null default 1 check (quantity > 0),
  primary key (booking_id, label)
);

-- ---------------------------------------------------------------------------
-- Messages between a guest and a venue
-- ---------------------------------------------------------------------------
create table public.messages (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references public.venues (id) on delete cascade,
  guest_id    uuid not null references public.profiles (id) on delete cascade,
  booking_id  uuid references public.bookings (id) on delete set null,
  sender_id   uuid not null references public.profiles (id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 2000),
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);
create index messages_thread_idx on public.messages (venue_id, guest_id, created_at);

-- ---------------------------------------------------------------------------
-- Reviews both ways
-- ---------------------------------------------------------------------------
create table public.venue_reviews (
  id           uuid primary key default gen_random_uuid(),
  venue_id     uuid not null references public.venues (id) on delete cascade,
  booking_id   uuid unique references public.bookings (id) on delete set null,
  author_id    uuid references public.profiles (id) on delete set null,
  author_name  text not null,
  event_label  text,
  stars        smallint not null check (stars between 1 and 5),
  body         text not null,
  host_reply   text,
  created_at   timestamptz not null default now()
);
create index venue_reviews_venue_idx on public.venue_reviews (venue_id, created_at desc);

create table public.guest_ratings (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null unique references public.bookings (id) on delete cascade,
  guest_id    uuid not null references public.profiles (id) on delete cascade,
  venue_id    uuid not null references public.venues (id) on delete cascade,
  rated_by    uuid references public.profiles (id) on delete set null,
  stars       smallint not null check (stars between 1 and 5),
  tags        text[] not null default '{}',
  body        text,
  guest_reply text,
  created_at  timestamptz not null default now()
);
create index guest_ratings_guest_idx on public.guest_ratings (guest_id);

-- ---------------------------------------------------------------------------
-- Guest conveniences
-- ---------------------------------------------------------------------------
create table public.saved_venues (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  venue_id   uuid not null references public.venues (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, venue_id)
);

create table public.waitlist (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  venue_id   uuid not null references public.venues (id) on delete cascade,
  room_id    uuid references public.rooms (id) on delete cascade,
  day        date not null,
  created_at timestamptz not null default now(),
  unique (user_id, venue_id, room_id, day)
);

-- ---------------------------------------------------------------------------
-- Money paid out to venues (filled by the payments integration)
-- ---------------------------------------------------------------------------
create table public.payouts (
  id           uuid primary key default gen_random_uuid(),
  venue_id     uuid not null references public.venues (id) on delete cascade,
  booking_id   uuid not null unique references public.bookings (id) on delete cascade,
  gross_pence  int not null check (gross_pence >= 0),
  fee_pence    int not null check (fee_pence >= 0),     -- Vendo commission (8% of hire)
  net_pence    int generated always as (gross_pence - fee_pence) stored,
  status       public.payout_status not null default 'held',
  pay_on       date,
  paid_at      timestamptz,
  created_at   timestamptz not null default now()
);
create index payouts_venue_idx on public.payouts (venue_id, pay_on desc);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;

create trigger profiles_updated before update on public.profiles for each row execute function public.set_updated_at();
create trigger venues_updated before update on public.venues for each row execute function public.set_updated_at();
create trigger bookings_updated before update on public.bookings for each row execute function public.set_updated_at();

-- Create a profile when someone signs up.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, full_name) values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', ''));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

-- Only admins can make someone an admin, or put a venue live for the first time.
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
  end if;
  return new;
end $$;
create trigger profiles_guard before update on public.profiles for each row execute function public.guard_admin_fields();
create trigger venues_guard before update on public.venues for each row execute function public.guard_admin_fields();

create or replace function public.owns_venue(v uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.venues where id = v and owner_id = auth.uid())
$$;

create or replace function public.owns_any_venue() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.venues where owner_id = auth.uid())
$$;

-- Busy dates for a venue, without anyone's personal details. Used by the public calendar.
create or replace function public.venue_busy_days(p_venue uuid, p_from date, p_to date)
returns table (day date, room_id uuid)
language sql stable security definer set search_path = '' as $$
  select b.day, b.room_id from public.availability_blocks b
   where b.venue_id = p_venue and b.day between p_from and p_to
  union all
  select k.event_date, k.room_id from public.bookings k
   where k.venue_id = p_venue and k.event_date between p_from and p_to and k.status in ('requested', 'confirmed')
$$;

-- A guest's average rating from venues, shown to venues receiving a request.
create or replace view public.guest_scores with (security_invoker = true) as
  select guest_id, round(avg(stars)::numeric, 1) as score, count(*) as ratings
    from public.guest_ratings group by guest_id;

-- Public venue rating summary.
create or replace view public.venue_scores with (security_invoker = true) as
  select venue_id, round(avg(stars)::numeric, 1) as score, count(*) as reviews
    from public.venue_reviews group by venue_id;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------
alter table public.profiles            enable row level security;
alter table public.venues              enable row level security;
alter table public.rooms               enable row level security;
alter table public.addons              enable row level security;
alter table public.availability_blocks enable row level security;
alter table public.bookings            enable row level security;
alter table public.booking_addons      enable row level security;
alter table public.messages            enable row level security;
alter table public.venue_reviews       enable row level security;
alter table public.guest_ratings       enable row level security;
alter table public.saved_venues        enable row level security;
alter table public.waitlist            enable row level security;
alter table public.payouts             enable row level security;

-- Profiles: you, venues you've booked with, and admins.
create policy "Read own profile" on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy "Venues read their guests' profiles" on public.profiles for select to authenticated using (
  exists (select 1 from public.bookings b where b.guest_id = profiles.id and public.owns_venue(b.venue_id)));
create policy "Admins read profiles" on public.profiles for select to authenticated using (public.is_admin());
create policy "Update own profile" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- Venues: anyone can see live venues; owners manage their own; admins manage all.
create policy "Anyone reads live venues" on public.venues for select using (status = 'live');
create policy "Owners read own venues" on public.venues for select to authenticated using (owner_id = (select auth.uid()));
create policy "Owners create venues" on public.venues for insert to authenticated
  with check (owner_id = (select auth.uid()) and status in ('draft', 'pending_review'));
create policy "Owners update own venues" on public.venues for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy "Admins manage venues" on public.venues for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Rooms and extras: public when the venue is live; owners manage.
create policy "Anyone reads rooms of live venues" on public.rooms for select
  using (exists (select 1 from public.venues v where v.id = rooms.venue_id and v.status = 'live'));
create policy "Owners manage rooms" on public.rooms for all to authenticated
  using (public.owns_venue(venue_id) or public.is_admin()) with check (public.owns_venue(venue_id) or public.is_admin());
create policy "Anyone reads extras of live venues" on public.addons for select
  using (exists (select 1 from public.venues v where v.id = addons.venue_id and v.status = 'live'));
create policy "Owners manage extras" on public.addons for all to authenticated
  using (public.owns_venue(venue_id) or public.is_admin()) with check (public.owns_venue(venue_id) or public.is_admin());

-- Availability: only the venue sees the details. Guests use venue_busy_days().
create policy "Owners manage availability" on public.availability_blocks for all to authenticated
  using (public.owns_venue(venue_id) or public.is_admin())
  with check (public.owns_venue(venue_id) or public.is_admin());

-- Bookings: the guest and the venue can see them. Guests create requests; the venue confirms or declines.
create policy "Guests read own bookings" on public.bookings for select to authenticated using (guest_id = (select auth.uid()));
create policy "Venues read their bookings" on public.bookings for select to authenticated using (public.owns_venue(venue_id));
create policy "Admins read bookings" on public.bookings for select to authenticated using (public.is_admin());
create policy "Guests request bookings" on public.bookings for insert to authenticated
  with check (guest_id = (select auth.uid()) and status = 'requested'
    and exists (select 1 from public.venues v where v.id = venue_id and v.status = 'live'));
create policy "Venues update their bookings" on public.bookings for update to authenticated
  using (public.owns_venue(venue_id)) with check (public.owns_venue(venue_id));
create policy "Guests update own bookings" on public.bookings for update to authenticated
  using (guest_id = (select auth.uid())) with check (guest_id = (select auth.uid()) and status in ('requested', 'confirmed', 'cancelled'));

create policy "Read extras on visible bookings" on public.booking_addons for select to authenticated
  using (exists (select 1 from public.bookings b where b.id = booking_id and (b.guest_id = (select auth.uid()) or public.owns_venue(b.venue_id))));
create policy "Guests add extras to own requests" on public.booking_addons for insert to authenticated
  with check (exists (select 1 from public.bookings b where b.id = booking_id and b.guest_id = (select auth.uid()) and b.status = 'requested'));

-- Messages: only the guest and the venue in the conversation.
create policy "Read own conversations" on public.messages for select to authenticated
  using (guest_id = (select auth.uid()) or public.owns_venue(venue_id));
create policy "Send in own conversations" on public.messages for insert to authenticated
  with check (sender_id = (select auth.uid()) and (guest_id = (select auth.uid()) or public.owns_venue(venue_id)));

-- Venue reviews: public; written by the guest after a completed booking; the venue can reply.
create policy "Anyone reads venue reviews" on public.venue_reviews for select using (true);
create policy "Guests review completed bookings" on public.venue_reviews for insert to authenticated
  with check (author_id = (select auth.uid()) and exists (select 1 from public.bookings b
    where b.id = booking_id and b.guest_id = (select auth.uid()) and b.venue_id = venue_reviews.venue_id and b.status = 'completed'));
create policy "Venues reply to reviews" on public.venue_reviews for update to authenticated
  using (public.owns_venue(venue_id)) with check (public.owns_venue(venue_id));

-- Guest ratings: the guest sees their own; venue owners see them (to decide on requests); the venue rates after the event.
create policy "Guests read own ratings" on public.guest_ratings for select to authenticated using (guest_id = (select auth.uid()));
create policy "Venue owners read guest ratings" on public.guest_ratings for select to authenticated using (public.owns_any_venue());
create policy "Venues rate their guests" on public.guest_ratings for insert to authenticated
  with check (rated_by = (select auth.uid()) and public.owns_venue(venue_id) and exists (select 1 from public.bookings b
    where b.id = booking_id and b.venue_id = guest_ratings.venue_id and b.guest_id = guest_ratings.guest_id and b.status = 'completed'));
create policy "Guests reply to ratings" on public.guest_ratings for update to authenticated
  using (guest_id = (select auth.uid())) with check (guest_id = (select auth.uid()));

-- Saved venues and waiting lists: your own rows only.
create policy "Manage own saved venues" on public.saved_venues for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "Manage own waiting lists" on public.waitlist for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Payouts: venues read their own. Only the server (service role) writes them.
create policy "Venues read own payouts" on public.payouts for select to authenticated using (public.owns_venue(venue_id) or public.is_admin());

grant execute on function public.venue_busy_days(uuid, date, date) to anon, authenticated;
