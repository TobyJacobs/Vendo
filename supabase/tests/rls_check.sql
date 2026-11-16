-- Checks the security rules by acting as a visitor, a guest and a venue owner.
-- Run it in the Supabase SQL editor. It creates two pretend people, tries things as each,
-- records what happened, then removes everything it created. If any step errors, nothing is kept.
-- When the editor offers to "enable RLS" on rls_check, choose "Run without RLS": it's a temporary table.
begin;
create temp table rls_check (n serial, check_name text, result text);
grant all on rls_check to anon, authenticated;
grant usage, select on sequence rls_check_n_seq to anon, authenticated;

insert into rls_check (check_name, result) select 'Tables', count(*)::text from pg_tables where schemaname = 'public';
insert into rls_check (check_name, result) select 'Tables with row level security', count(*)::text from pg_tables where schemaname = 'public' and rowsecurity;
insert into rls_check (check_name, result) select 'Security policies', count(*)::text from pg_policies where schemaname = 'public';
insert into rls_check (check_name, result) select 'Venues / rooms / extras / reviews',
  (select count(*) from public.venues) || ' / ' || (select count(*) from public.rooms) || ' / ' || (select count(*) from public.addons) || ' / ' || (select count(*) from public.venue_reviews);

-- Pretend people
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-00000000a001', 'guest@rls-test.invalid', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-00000000a002', 'owner@rls-test.invalid', 'authenticated', 'authenticated');
update public.venues set owner_id = '00000000-0000-4000-8000-00000000a002' where slug = 'the-plough-and-harrow';
insert into public.availability_blocks (venue_id, day, kind, guest_name)
  select id, current_date + 10, 'booking', 'Phone guest' from public.venues where slug = 'the-plough-and-harrow';

-- 1. Anonymous visitor
set local role anon;
insert into rls_check (check_name, result) select 'Visitor sees live venues', count(*)::text from public.venues;
insert into rls_check (check_name, result) select 'Visitor sees phone-booking details (want 0)', count(*)::text from public.availability_blocks;
insert into rls_check (check_name, result) select 'Visitor sees busy dates, no names (want 1)', count(*)::text
  from public.venue_busy_days((select id from public.venues where slug = 'the-plough-and-harrow'), current_date, current_date + 30);
insert into rls_check (check_name, result) select 'Visitor sees profiles (want 0)', count(*)::text from public.profiles;
do $$ begin
  insert into public.venues (slug, name, kind, venue_type, place, region) values ('sneaky', 'x', 'x', 'x', 'x', 'x');
  insert into rls_check (check_name, result) values ('Visitor adds a venue', 'ALLOWED - problem');
exception when others then insert into rls_check (check_name, result) values ('Visitor adds a venue', 'blocked');
end $$;
reset role;

-- 2. Guest
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-4000-8000-00000000a001","role":"authenticated"}';
insert into rls_check (check_name, result) select 'Guest sees phone-booking details (want 0)', count(*)::text from public.availability_blocks;
insert into public.bookings (venue_id, guest_id, event_date, start_time, hours, guests, event_type, event_label,
    contact_name, contact_email, contact_phone, hire_pence, fee_pence, total_pence)
  select id, '00000000-0000-4000-8000-00000000a001', current_date + 40, '19:00', 5, 60, 'Birthdays', 'Birthday party',
    'Test Guest', 'guest@rls-test.invalid', '07700 900123', 47500, 1900, 49400
  from public.venues where slug = 'the-plough-and-harrow';
insert into rls_check (check_name, result) select 'Guest requests a booking (want 1)', count(*)::text from public.bookings;
do $$ begin
  insert into public.bookings (venue_id, guest_id, status, event_date, start_time, hours, guests, event_type, event_label,
      contact_name, contact_email, contact_phone, hire_pence, fee_pence, total_pence)
    select id, '00000000-0000-4000-8000-00000000a001', 'confirmed', current_date + 41, '19:00', 5, 60, 'x', 'x', 'x', 'x@x.invalid', '07700 900123', 1, 1, 1
    from public.venues where slug = 'the-plough-and-harrow';
  insert into rls_check (check_name, result) values ('Guest confirms their own booking', 'ALLOWED - problem');
exception when others then insert into rls_check (check_name, result) values ('Guest confirms their own booking', 'blocked');
end $$;
do $$ begin
  update public.profiles set is_admin = true where id = auth.uid();
  insert into rls_check (check_name, result) values ('Guest makes themselves admin', 'ALLOWED - problem');
exception when others then insert into rls_check (check_name, result) values ('Guest makes themselves admin', 'blocked');
end $$;
reset role;

-- 3. Venue owner
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-4000-8000-00000000a002","role":"authenticated"}';
insert into rls_check (check_name, result) select 'Owner sees own phone bookings (want 1)', count(*)::text from public.availability_blocks;
insert into rls_check (check_name, result) select 'Owner sees booking requests (want 1)', count(*)::text from public.bookings;
insert into rls_check (check_name, result) select 'Owner sees that guest''s profile (want 1)', count(*)::text
  from public.profiles where id = '00000000-0000-4000-8000-00000000a001';
update public.bookings set status = 'confirmed' where contact_email = 'guest@rls-test.invalid';
insert into rls_check (check_name, result) select 'Owner confirms the booking', status::text from public.bookings where contact_email = 'guest@rls-test.invalid';
reset role;

-- 4. Visitor again
set local role anon;
insert into rls_check (check_name, result) select 'Visitor sees bookings (want 0)', count(*)::text from public.bookings;
reset role;

-- Remove the pretend people and their data
delete from public.bookings where contact_email = 'guest@rls-test.invalid';
delete from public.availability_blocks where guest_name = 'Phone guest';
update public.venues set owner_id = null where slug = 'the-plough-and-harrow';
delete from auth.users where email like '%@rls-test.invalid';
insert into rls_check (check_name, result) select 'Test data removed (want 0)',
  ((select count(*) from auth.users where email like '%@rls-test.invalid') + (select count(*) from public.bookings))::text;
commit;

select check_name, result from rls_check order by n;
