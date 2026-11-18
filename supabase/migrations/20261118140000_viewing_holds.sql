-- Viewing holds: a guest reserves a date for up to 7 days while they view the venue.
-- While a hold is active nobody else can book that room and time (setup and cleaning included). It ends when the
-- guest books (converted), when the guest or venue releases it, or by itself after 7 days, so the venue never loses
-- a bigger booking to someone who doesn't follow through. No scheduled job is needed: a hold only counts while
-- expires_at is in the future.

create type public.viewing_hold_status as enum ('active', 'converted', 'released');

create table public.viewing_holds (
  id             uuid primary key default gen_random_uuid(),
  venue_id       uuid not null references public.venues (id) on delete cascade,
  room_id        uuid references public.rooms (id) on delete set null,
  guest_id       uuid not null references public.profiles (id) on delete cascade,
  event_date     date not null,
  start_time     time not null,
  hours          smallint not null check (hours between 1 and 24),
  guests         int not null check (guests > 0),
  viewing_at     timestamp not null,                     -- venue's local time
  contact_name   text not null check (char_length(contact_name) between 1 and 80),
  contact_phone  text not null check (char_length(contact_phone) between 6 and 30),
  contact_email  text not null check (char_length(contact_email) <= 200),
  note           text check (note is null or char_length(note) <= 500),
  status         public.viewing_hold_status not null default 'active',
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null,
  ended_at       timestamptz
);
create index viewing_holds_venue_date_idx on public.viewing_holds (venue_id, event_date);
create index viewing_holds_guest_idx on public.viewing_holds (guest_id);

alter table public.viewing_holds enable row level security;
-- Read only: holds are made and ended through the functions below, which check everything.
create policy "Guests see their holds" on public.viewing_holds for select to authenticated using (guest_id = auth.uid());
create policy "Venues see holds on their venues" on public.viewing_holds for select to authenticated using (public.owns_venue(venue_id));
create policy "Admins see all holds" on public.viewing_holds for select to authenticated using (public.is_admin());

create or replace function public.viewing_hold_is_active(h public.viewing_holds) returns boolean
language sql stable set search_path = '' as $$
  select h.status = 'active' and h.expires_at > now()
$$;

-- Place a hold and book a viewing.
create or replace function public.place_viewing_hold(
  p_venue uuid, p_room uuid, p_date date, p_start time, p_hours int, p_guests int,
  p_viewing timestamp, p_name text, p_phone text, p_email text, p_note text)
returns public.viewing_holds
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  v_until timestamptz;
  span tsrange;
  h public.viewing_holds;
begin
  if me is null then raise exception 'HOLD_SIGN_IN: Sign in to hold a date.'; end if;
  if not exists (select 1 from public.venues where id = p_venue and status = 'live') then
    raise exception 'HOLD_VENUE: This venue is not taking bookings.'; end if;
  if p_room is not null and not exists (select 1 from public.rooms where id = p_room and venue_id = p_venue) then
    raise exception 'HOLD_VENUE: That room is not at this venue.'; end if;
  if p_date <= (now() at time zone 'Europe/London')::date then
    raise exception 'HOLD_DATE: Pick a date after today.'; end if;
  if p_hours not between 1 and 24 or p_guests < 1 then raise exception 'HOLD_DATE: Check the hours and guests.'; end if;

  -- 7 days, or until the morning of the event if that comes sooner.
  v_until := least(now() + interval '7 days', (p_date::timestamp) at time zone 'Europe/London');
  if p_viewing < (now() at time zone 'Europe/London') or (p_viewing at time zone 'Europe/London') > v_until then
    raise exception 'HOLD_VIEWING: Pick a viewing time before your hold ends.'; end if;

  perform pg_advisory_xact_lock(hashtext('booking:' || p_venue::text));
  if (select count(*) from public.viewing_holds x where x.guest_id = me and public.viewing_hold_is_active(x)) >= 3 then
    raise exception 'HOLD_LIMIT: You can hold up to 3 dates at a time. Release one first.'; end if;
  if exists (select 1 from public.viewing_holds x where x.guest_id = me and x.venue_id = p_venue and public.viewing_hold_is_active(x)) then
    raise exception 'HOLD_LIMIT: You already have a date held at this venue.'; end if;

  span := public.booking_hold(p_room, p_date, p_start, p_hours);
  if exists (select 1 from public.venue_busy_times(p_venue, p_date - 1, p_date + 1) b
              where (b.room_id is null or p_room is null or b.room_id = p_room)
                and tsrange(b.starts_at, b.ends_at, '[)') && span) then
    raise exception 'HOLD_CLASH: That time is no longer free. Pick another.'; end if;

  insert into public.viewing_holds (venue_id, room_id, guest_id, event_date, start_time, hours, guests, viewing_at,
                            contact_name, contact_phone, contact_email, note, expires_at)
  values (p_venue, p_room, me, p_date, p_start, p_hours, p_guests, p_viewing,
          left(trim(p_name), 80), left(trim(p_phone), 30), left(trim(p_email), 200), nullif(left(trim(coalesce(p_note, '')), 500), ''), v_until)
  returning * into h;
  return h;
end $$;
grant execute on function public.place_viewing_hold(uuid, uuid, date, time, int, int, timestamp, text, text, text, text) to authenticated;

-- End a hold early. The guest who made it or the venue can do this.
create or replace function public.release_viewing_hold(p_hold uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.viewing_holds set status = 'released', ended_at = now()
   where id = p_hold and status = 'active'
     and (guest_id = auth.uid() or public.owns_venue(venue_id) or public.is_admin());
  if not found then raise exception 'HOLD_GONE: That hold has already ended.'; end if;
end $$;
grant execute on function public.release_viewing_hold(uuid) to authenticated;

-- Active holds count as busy for everyone, setup and cleaning included.
create or replace function public.venue_busy_times(p_venue uuid, p_from date, p_to date)
returns table (room_id uuid, starts_at timestamp, ends_at timestamp)
language sql stable security definer set search_path = '' as $$
  select x.room_id, lower(x.h), upper(x.h) from (
    select b.room_id, public.block_hold(b.room_id, b.day, b.start_time, b.end_time, b.kind) h
      from public.availability_blocks b
     where b.venue_id = p_venue and b.day between p_from - 1 and p_to
    union all
    select k.room_id, public.booking_hold(k.room_id, k.event_date, k.start_time, k.hours)
      from public.bookings k
     where k.venue_id = p_venue and k.event_date between p_from - 1 and p_to and k.status in ('requested', 'confirmed')
    union all
    select o.room_id, public.booking_hold(o.room_id, o.event_date, o.start_time, o.hours)
      from public.viewing_holds o
     where o.venue_id = p_venue and o.event_date between p_from - 1 and p_to and public.viewing_hold_is_active(o)
  ) x
$$;

-- The day-level calendar (older app versions) treats held days as busy too.
create or replace function public.venue_busy_days(p_venue uuid, p_from date, p_to date)
returns table (day date, room_id uuid)
language sql stable security definer set search_path = '' as $$
  select b.day, b.room_id from public.availability_blocks b
   where b.venue_id = p_venue and b.day between p_from and p_to
  union all
  select k.event_date, k.room_id from public.bookings k
   where k.venue_id = p_venue and k.event_date between p_from and p_to and k.status in ('requested', 'confirmed')
  union all
  select o.event_date, o.room_id from public.viewing_holds o
   where o.venue_id = p_venue and o.event_date between p_from and p_to and public.viewing_hold_is_active(o)
$$;

-- Bookings may not clash with someone else's active hold. A guest's own hold doesn't block them.
create or replace function public.check_booking_clash() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  h tsrange;
begin
  if new.status not in ('requested', 'confirmed') then return new; end if;
  perform pg_advisory_xact_lock(hashtext('booking:' || new.venue_id::text));
  h := public.booking_hold(new.room_id, new.event_date, new.start_time, new.hours);
  if exists (
    select 1 from public.bookings k
     where k.venue_id = new.venue_id and k.id <> new.id and k.status in ('requested', 'confirmed')
       and (k.room_id is null or new.room_id is null or k.room_id = new.room_id)
       and k.event_date between new.event_date - 1 and new.event_date + 1
       and public.booking_hold(k.room_id, k.event_date, k.start_time, k.hours) && h
  ) or exists (
    select 1 from public.availability_blocks b
     where b.venue_id = new.venue_id
       and (b.room_id is null or new.room_id is null or b.room_id = new.room_id)
       and b.day between new.event_date - 1 and new.event_date + 1
       and public.block_hold(b.room_id, b.day, b.start_time, b.end_time, b.kind) && h
  ) or exists (
    select 1 from public.viewing_holds o
     where o.venue_id = new.venue_id and o.guest_id <> new.guest_id and public.viewing_hold_is_active(o)
       and (o.room_id is null or new.room_id is null or o.room_id = new.room_id)
       and o.event_date between new.event_date - 1 and new.event_date + 1
       and public.booking_hold(o.room_id, o.event_date, o.start_time, o.hours) && h
  ) then
    raise exception 'BOOKING_CLASH: That time overlaps another event at this venue, including its setup and cleaning time.'
      using errcode = 'P0001';
  end if;
  return new;
end $$;

-- When the guest books at the venue they held, their hold is done.
create or replace function public.convert_viewing_hold() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.viewing_holds set status = 'converted', ended_at = now()
   where guest_id = new.guest_id and venue_id = new.venue_id and status = 'active';
  return new;
end $$;
create trigger bookings_convert_viewing_hold after insert on public.bookings
  for each row execute function public.convert_viewing_hold();
