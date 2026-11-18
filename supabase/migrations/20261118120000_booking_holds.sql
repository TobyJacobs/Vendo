-- Booking holds: while someone is filling in the booking form, their time slot is reserved for 15 minutes,
-- so nobody else can book it from under them. Holds need an account, and each person has at most one at a time.
-- Holds cover the same time as the booking would, setup and cleaning included (see booking_hold()).

create table if not exists public.booking_holds (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references public.venues (id) on delete cascade,
  room_id     uuid references public.rooms (id) on delete cascade,
  holder_id   uuid not null unique references public.profiles (id) on delete cascade,
  event_date  date not null,
  start_time  time not null,
  hours       smallint not null check (hours between 1 and 24),
  expires_at  timestamptz not null,
  created_at  timestamptz not null default now()
);
create index if not exists booking_holds_venue_idx on public.booking_holds (venue_id, event_date);
alter table public.booking_holds enable row level security;
-- People can see their own hold. Holds are only created or removed through the functions below.
drop policy if exists "Read own hold" on public.booking_holds;
create policy "Read own hold" on public.booking_holds for select to authenticated using (holder_id = (select auth.uid()));

-- What, if anything, is in the way of this slot: 'booked' (a booking or the venue's own entry) or 'held'
-- (someone else is booking it right now). p_guest is ignored, so a person's own hold never blocks them.
create or replace function public.slot_conflict(p_venue uuid, p_room uuid, p_date date, p_start time, p_hours int,
                                                p_guest uuid, p_ignore_booking uuid default null)
returns text
language plpgsql stable security definer set search_path = '' as $$
declare h tsrange := public.booking_hold(p_room, p_date, p_start, p_hours);
begin
  if exists (
    select 1 from public.bookings k
     where k.venue_id = p_venue and k.id is distinct from p_ignore_booking and k.status in ('requested', 'confirmed')
       and (k.room_id is null or p_room is null or k.room_id = p_room)
       and k.event_date between p_date - 1 and p_date + 1
       and public.booking_hold(k.room_id, k.event_date, k.start_time, k.hours) && h
  ) or exists (
    select 1 from public.availability_blocks b
     where b.venue_id = p_venue and (b.room_id is null or p_room is null or b.room_id = p_room)
       and b.day between p_date - 1 and p_date + 1
       and public.block_hold(b.room_id, b.day, b.start_time, b.end_time, b.kind) && h
  ) then return 'booked'; end if;
  if exists (
    select 1 from public.booking_holds x
     where x.venue_id = p_venue and x.holder_id is distinct from p_guest and x.expires_at > now()
       and (x.room_id is null or p_room is null or x.room_id = p_room)
       and x.event_date between p_date - 1 and p_date + 1
       and public.booking_hold(x.room_id, x.event_date, x.start_time, x.hours) && h
  ) then return 'held'; end if;
  return null;
end $$;
revoke all on function public.slot_conflict(uuid, uuid, date, time, int, uuid, uuid) from public, anon, authenticated;

-- Reserve a slot for the signed-in person for 15 minutes. Replaces any hold they already have.
-- Changing the time or room on the same venue and date keeps the original deadline, so a hold can't be stretched
-- forever by fiddling with the form. Returns when the hold runs out.
create or replace function public.place_hold(p_venue uuid, p_room uuid, p_date date, p_start time, p_hours int)
returns timestamptz
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  c text;
  old public.booking_holds;
  until timestamptz;
begin
  if me is null then raise exception 'SIGN_IN: Sign in to hold a date.' using errcode = '42501'; end if;
  if p_hours is null or p_hours not between 1 and 24 then raise exception 'Choose between 1 and 24 hours.'; end if;
  if p_date < current_date then raise exception 'That date has passed.'; end if;
  if not exists (select 1 from public.venues v where v.id = p_venue and v.status = 'live') then raise exception 'Venue not found.'; end if;
  if p_room is not null and not exists (select 1 from public.rooms r where r.id = p_room and r.venue_id = p_venue) then raise exception 'Room not found.'; end if;
  perform pg_advisory_xact_lock(hashtext('booking:' || p_venue::text));   -- same lock as new bookings
  delete from public.booking_holds where venue_id = p_venue and expires_at <= now();
  c := public.slot_conflict(p_venue, p_room, p_date, p_start, p_hours, me);
  if c = 'booked' then raise exception 'BOOKING_CLASH: That time overlaps another event at this venue, including its setup and cleaning time.' using errcode = 'P0001'; end if;
  if c = 'held' then raise exception 'HOLD_TAKEN: Someone else is booking that time right now.' using errcode = 'P0001'; end if;
  select * into old from public.booking_holds where holder_id = me;
  until := case when old.id is not null and old.venue_id = p_venue and old.event_date = p_date and old.expires_at > now()
                then old.expires_at else now() + interval '15 minutes' end;
  insert into public.booking_holds (venue_id, room_id, holder_id, event_date, start_time, hours, expires_at)
  values (p_venue, p_room, me, p_date, p_start, p_hours, until)
  on conflict (holder_id) do update set venue_id = excluded.venue_id, room_id = excluded.room_id, event_date = excluded.event_date,
    start_time = excluded.start_time, hours = excluded.hours, expires_at = excluded.expires_at;
  return until;
end $$;

-- Let go of the signed-in person's hold (they left the booking form).
create or replace function public.release_hold() returns void
language sql security definer set search_path = '' as $$
  delete from public.booking_holds where holder_id = auth.uid()
$$;
revoke all on function public.place_hold(uuid, uuid, date, time, int), public.release_hold() from public, anon;
grant execute on function public.place_hold(uuid, uuid, date, time, int), public.release_hold() to authenticated;

-- New bookings: also refuse a slot someone else is holding. A person's own hold is used up by their booking.
create or replace function public.check_booking_clash() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c text;
begin
  if new.status not in ('requested', 'confirmed') then return new; end if;
  perform pg_advisory_xact_lock(hashtext('booking:' || new.venue_id::text));
  c := public.slot_conflict(new.venue_id, new.room_id, new.event_date, new.start_time, new.hours, new.guest_id, new.id);
  -- Someone else's hold only matters when a new booking is made, not when a venue updates an existing one.
  if c = 'booked' or (c = 'held' and tg_op = 'INSERT') then
    raise exception '%', case c when 'held' then 'HOLD_TAKEN: Someone else is booking that time right now.'
      else 'BOOKING_CLASH: That time overlaps another event at this venue, including its setup and cleaning time.' end
      using errcode = 'P0001';
  end if;
  if tg_op = 'INSERT' then delete from public.booking_holds where holder_id = new.guest_id; end if;
  return new;
end $$;

-- Busy times now include other people's live holds (never your own), so held slots show as taken.
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
      from public.booking_holds o
     where o.venue_id = p_venue and o.event_date between p_from - 1 and p_to and o.expires_at > now()
       and o.holder_id is distinct from auth.uid()
  ) x
$$;
grant execute on function public.venue_busy_times(uuid, date, date) to anon, authenticated;
