-- Checks booking holds with two pretend guests (A and B) racing for the same slot. Everything is removed at the end.
-- Run in the Supabase SQL editor; when it offers to "enable RLS" on holds_check, choose "Run without RLS" (temporary table).
begin;
create temp table holds_check (n serial, check_name text, result text);
create temp table t (k text primary key, v text);
grant all on holds_check, t to authenticated, anon;
grant usage, select on sequence holds_check_n_seq to authenticated, anon;
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-00000000d001', 'guest-a@rls-test.invalid', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-00000000d002', 'guest-b@rls-test.invalid', 'authenticated', 'authenticated');
-- A live venue room, and a date far enough ahead to be clear of real bookings.
insert into t select 'venue', r.venue_id::text from public.rooms r join public.venues v on v.id = r.venue_id where v.status = 'live' and r.is_listed order by v.slug, r.sort_order limit 1;
insert into t select 'room', r.id::text from public.rooms r where r.venue_id = (select v::uuid from t where k = 'venue') and r.is_listed order by r.sort_order limit 1;
insert into t values ('day', (current_date + 400)::text);

-- Signed out
set local role anon;
set local request.jwt.claims to '{"role":"anon"}';
do $$ begin
  perform public.place_hold((select v::uuid from t where k='venue'), (select v::uuid from t where k='room'), (select v::date from t where k='day'), '14:00', 3);
  insert into holds_check (check_name, result) values ('Signed-out visitor holds a slot', 'ALLOWED - problem');
exception when others then insert into holds_check (check_name, result) values ('Signed-out visitor holds a slot', 'blocked');
end $$;
reset role;

-- Guest A holds 14:00 to 17:00
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-4000-8000-00000000d001","role":"authenticated"}';
insert into t select 'a_until', public.place_hold((select v::uuid from t where k='venue'), (select v::uuid from t where k='room'), (select v::date from t where k='day'), '14:00', 3)::text;
insert into holds_check (check_name, result) select 'A holds the slot: minutes left (want 15)', round(extract(epoch from (v::timestamptz - now())) / 60)::text from t where k = 'a_until';
insert into holds_check (check_name, result) select 'A sees their own hold as busy (want 0)', count(*)::text
  from public.venue_busy_times((select v::uuid from t where k='venue'), (select v::date from t where k='day'), (select v::date from t where k='day'))
 where starts_at::date = (select v::date from t where k='day');
-- Changing the start time on the same day keeps the same deadline
insert into t select 'a_until2', public.place_hold((select v::uuid from t where k='venue'), (select v::uuid from t where k='room'), (select v::date from t where k='day'), '15:00', 3)::text;
insert into holds_check (check_name, result) select 'A moves to 15:00: same deadline (want true)', ((select v from t where k='a_until') = (select v from t where k='a_until2'))::text;
reset role;

-- Guest B
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-4000-8000-00000000d002","role":"authenticated"}';
insert into holds_check (check_name, result) select 'B sees A''s hold as busy (want 1)', count(*)::text
  from public.venue_busy_times((select v::uuid from t where k='venue'), (select v::date from t where k='day'), (select v::date from t where k='day'))
 where starts_at::date = (select v::date from t where k='day');
insert into holds_check (check_name, result) select 'B can read A''s hold (want 0)', count(*)::text from public.booking_holds;
do $$ begin
  perform public.place_hold((select v::uuid from t where k='venue'), (select v::uuid from t where k='room'), (select v::date from t where k='day'), '16:00', 2);
  insert into holds_check (check_name, result) values ('B holds an overlapping time', 'ALLOWED - problem');
exception when others then insert into holds_check (check_name, result) values ('B holds an overlapping time', case when sqlerrm like 'HOLD_TAKEN%' then 'blocked (someone else is booking)' else 'blocked: ' || sqlerrm end);
end $$;
do $$ begin
  insert into public.bookings (venue_id, room_id, guest_id, event_date, start_time, hours, guests, event_type, event_label, contact_name, contact_email, contact_phone, hire_pence, fee_pence, total_pence)
  values ((select v::uuid from t where k='venue'), (select v::uuid from t where k='room'), auth.uid(), (select v::date from t where k='day'), '16:00', 2, 20, 'Birthdays', 'Test', 'Guest B', 'guest-b@rls-test.invalid', '07700900000', 100, 4, 104);
  insert into holds_check (check_name, result) values ('B books straight over A''s hold', 'ALLOWED - problem');
exception when others then insert into holds_check (check_name, result) values ('B books straight over A''s hold', case when sqlerrm like 'HOLD_TAKEN%' then 'blocked (someone else is booking)' else 'blocked: ' || sqlerrm end);
end $$;
-- A different day is fine
insert into holds_check (check_name, result)
  select 'B holds another day (want allowed)', case when public.place_hold((select v::uuid from t where k='venue'), (select v::uuid from t where k='room'), (select v::date from t where k='day') + 7, '14:00', 3) > now() then 'allowed' else 'problem' end;
reset role;

-- Guest A books their held slot
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-4000-8000-00000000d001","role":"authenticated"}';
insert into public.bookings (venue_id, room_id, guest_id, event_date, start_time, hours, guests, event_type, event_label, contact_name, contact_email, contact_phone, hire_pence, fee_pence, total_pence)
values ((select v::uuid from t where k='venue'), (select v::uuid from t where k='room'), auth.uid(), (select v::date from t where k='day'), '15:00', 3, 20, 'Birthdays', 'Test', 'Guest A', 'guest-a@rls-test.invalid', '07700900000', 100, 4, 104);
insert into holds_check (check_name, result) values ('A books their held slot', 'allowed');
insert into holds_check (check_name, result) select 'A''s hold used up by the booking (want 0)', count(*)::text from public.booking_holds;
reset role;

-- Guest B tries the now-booked slot; and B's own hold elsewhere expires
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-4000-8000-00000000d002","role":"authenticated"}';
do $$ begin
  perform public.place_hold((select v::uuid from t where k='venue'), (select v::uuid from t where k='room'), (select v::date from t where k='day'), '16:00', 2);
  insert into holds_check (check_name, result) values ('B holds the booked time', 'ALLOWED - problem');
exception when others then insert into holds_check (check_name, result) values ('B holds the booked time', case when sqlerrm like 'BOOKING_CLASH%' then 'blocked (already booked)' else 'blocked: ' || sqlerrm end);
end $$;
reset role;
update public.booking_holds set expires_at = now() - interval '1 minute' where holder_id = '00000000-0000-4000-8000-00000000d002';
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-4000-8000-00000000d001","role":"authenticated"}';
insert into holds_check (check_name, result)
  select 'A holds the slot B''s expired hold had (want allowed)', case when public.place_hold((select v::uuid from t where k='venue'), (select v::uuid from t where k='room'), (select v::date from t where k='day') + 7, '14:00', 3) > now() then 'allowed' else 'problem' end;
select public.release_hold();
insert into holds_check (check_name, result) select 'A lets go of the hold (want 0)', count(*)::text from public.booking_holds;
reset role;

-- Clean up
delete from public.bookings where guest_id in ('00000000-0000-4000-8000-00000000d001', '00000000-0000-4000-8000-00000000d002');
delete from auth.users where email ilike '%@rls-test.invalid';
insert into holds_check (check_name, result) select 'Test data removed (want 0)',
  ((select count(*) from auth.users where email ilike '%@rls-test.invalid') + (select count(*) from public.booking_holds where holder_id::text like '00000000-0000-4000-8000-00000000d00%')
   + (select count(*) from public.bookings where contact_email::text ilike '%@rls-test.invalid'))::text;
commit;
select check_name, result from holds_check order by n;
