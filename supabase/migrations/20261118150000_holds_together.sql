-- Booking holds (15 minutes, while someone fills in the booking form) and viewing holds (up to 7 days, while someone
-- views the venue) working together. Run after 20261118120000_booking_holds.sql and 20261118140000_viewing_holds.sql:
-- both of those replace check_booking_clash() and venue_busy_times(), and this puts back one version that knows
-- about both kinds of hold.

-- Anything in the way of a slot. Someone else's viewing hold counts as booked; someone else's 15-minute hold as held.
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
  ) or exists (
    select 1 from public.viewing_holds o
     where o.venue_id = p_venue and o.guest_id is distinct from p_guest and public.viewing_hold_is_active(o)
       and (o.room_id is null or p_room is null or o.room_id = p_room)
       and o.event_date between p_date - 1 and p_date + 1
       and public.booking_hold(o.room_id, o.event_date, o.start_time, o.hours) && h
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

-- New bookings: refuse anything in the way. Someone else's 15-minute hold only matters for new bookings.
-- A person's own 15-minute hold is used up by their booking (their viewing hold is closed by convert_viewing_hold()).
create or replace function public.check_booking_clash() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c text;
begin
  if new.status not in ('requested', 'confirmed') then return new; end if;
  perform pg_advisory_xact_lock(hashtext('booking:' || new.venue_id::text));
  c := public.slot_conflict(new.venue_id, new.room_id, new.event_date, new.start_time, new.hours, new.guest_id, new.id);
  if c = 'booked' or (c = 'held' and tg_op = 'INSERT') then
    raise exception '%', case c when 'held' then 'HOLD_TAKEN: Someone else is booking that time right now.'
      else 'BOOKING_CLASH: That time overlaps another event at this venue, including its setup and cleaning time.' end
      using errcode = 'P0001';
  end if;
  if tg_op = 'INSERT' then delete from public.booking_holds where holder_id = new.guest_id; end if;
  return new;
end $$;

-- Busy times: venue entries, bookings, everyone's viewing holds, and other people's 15-minute holds.
-- place_viewing_hold() checks against this, so a viewing hold can't be placed over someone mid-booking.
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
    union all
    select q.room_id, public.booking_hold(q.room_id, q.event_date, q.start_time, q.hours)
      from public.booking_holds q
     where q.venue_id = p_venue and q.event_date between p_from - 1 and p_to and q.expires_at > now()
       and q.holder_id is distinct from auth.uid()
  ) x
$$;
grant execute on function public.venue_busy_times(uuid, date, date) to anon, authenticated;
