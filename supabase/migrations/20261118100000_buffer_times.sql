-- Buffer times: setup before and cleaning after every booking.
-- Each room says how long it needs to get ready before an event and to clean up after one. A booking then holds
-- the room from (start - setup) to (end + cleaning), so nobody can book while the room is still being cleaned.
-- The database refuses clashing bookings itself, so this holds however a booking is made.

alter table public.rooms
  add column if not exists setup_mins smallint not null default 0  check (setup_mins between 0 and 240),
  add column if not exists clean_mins smallint not null default 60 check (clean_mins between 0 and 480);

-- When a booking holds its room, buffers included. Times are the venue's local time.
create or replace function public.booking_hold(p_room uuid, p_date date, p_start time, p_hours int)
returns tsrange
language sql stable security definer set search_path = '' as $$
  select tsrange(
    (p_date + p_start) - make_interval(mins => coalesce(r.setup_mins, 0)),
    (p_date + p_start) + make_interval(hours => p_hours) + make_interval(mins => coalesce(r.clean_mins, 60)),
    '[)')
  from (select 1) one left join public.rooms r on r.id = p_room
$$;

-- When a venue's own entry (phone booking or closed date) holds a room. No times means the whole day.
-- Phone bookings with times get the room's cleaning time too.
create or replace function public.block_hold(p_room uuid, p_day date, p_start time, p_end time, p_kind public.block_kind)
returns tsrange
language sql stable security definer set search_path = '' as $$
  select case
    when p_start is null or p_end is null then tsrange(p_day::timestamp, (p_day + 1)::timestamp, '[)')
    else tsrange(
      (p_day + p_start) - make_interval(mins => case when p_kind = 'booking' then coalesce(r.setup_mins, 0) else 0 end),
      (p_day + p_end) + case when p_end <= p_start then interval '1 day' else interval '0' end
        + make_interval(mins => case when p_kind = 'booking' then coalesce(r.clean_mins, 60) else 0 end),
      '[)')
  end
  from (select 1) one left join public.rooms r on r.id = p_room
$$;

-- Busy times for a venue, buffers included, without anyone's personal details. room_id null = whole venue.
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
  ) x
$$;
grant execute on function public.venue_busy_times(uuid, date, date) to anon, authenticated;

-- Refuse a booking that overlaps another booking or a venue's own entry for the same room (or the whole venue),
-- buffers included. The lock stops two people booking the same slot at the same moment.
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
  ) then
    raise exception 'BOOKING_CLASH: That time overlaps another event at this venue, including its setup and cleaning time.'
      using errcode = 'P0001';
  end if;
  return new;
end $$;

drop trigger if exists bookings_no_clash on public.bookings;
create trigger bookings_no_clash
  before insert or update of event_date, start_time, hours, room_id, status on public.bookings
  for each row execute function public.check_booking_clash();
