-- Checks venue submission and verification: a pretend admin and two pretend venue owners, removed again at the end.
-- Run in the Supabase SQL editor; when it offers to "enable RLS" on venue_check, choose "Run without RLS" (temporary table).
begin;
create temp table venue_check (n serial, check_name text, result text);
grant all on venue_check to authenticated, anon;
grant usage, select on sequence venue_check_n_seq to authenticated, anon;
insert into public.admin_emails (email) values ('admin@rls-test.invalid');
insert into auth.users (id, email, aud, role, raw_user_meta_data) values
  ('00000000-0000-4000-8000-00000000c001', 'admin@rls-test.invalid', 'authenticated', 'authenticated', '{}'),
  ('00000000-0000-4000-8000-00000000c002', 'host@rls-test.invalid',  'authenticated', 'authenticated', '{"account_type":"host"}'),
  ('00000000-0000-4000-8000-00000000c003', 'other@rls-test.invalid', 'authenticated', 'authenticated', '{"account_type":"host"}');

-- Venue owner
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-4000-8000-00000000c002","role":"authenticated"}';
do $$ begin
  insert into public.venues (slug, owner_id, status, verified, name, kind, venue_type, place, region)
  values ('rls-test-venue-0', auth.uid(), 'draft', true, 'Self-verified', 'Hall', 'hall', 'Testtown', 'Test');
  insert into venue_check (check_name, result) values ('Owner adds a venue already verified', 'ALLOWED - problem');
exception when others then insert into venue_check (check_name, result) values ('Owner adds a venue already verified', 'blocked');
end $$;
insert into public.venues (id, slug, owner_id, status, name, kind, venue_type, place, region)
values ('00000000-0000-4000-8000-0000000000e1', 'rls-test-venue-1', auth.uid(), 'pending_review', 'Test Hall', 'Village hall', 'hall', 'Testtown', 'Test');
insert into venue_check (check_name, result) values ('Owner submits a venue for review', 'allowed');
do $$ begin
  update public.venues set verified = true where slug = 'rls-test-venue-1';
  insert into venue_check (check_name, result) values ('Owner gives their venue the badge', 'ALLOWED - problem');
exception when others then insert into venue_check (check_name, result) values ('Owner gives their venue the badge', 'blocked');
end $$;
do $$ begin
  update public.venues set status = 'live' where slug = 'rls-test-venue-1';
  insert into venue_check (check_name, result) values ('Owner puts their venue live', 'ALLOWED - problem');
exception when others then insert into venue_check (check_name, result) values ('Owner puts their venue live', 'blocked');
end $$;
insert into public.venue_docs (venue_id, legal_name, licence_number, id_path)
values ('00000000-0000-4000-8000-0000000000e1', 'Test Owner', 'LN/123', '00000000-0000-4000-8000-0000000000e1/id.pdf');
insert into venue_check (check_name, result) select 'Owner saves their documents (want 1)', count(*)::text from public.venue_docs;
do $$ begin
  update public.venue_docs set id_path = 'someone-else/id.pdf' where venue_id = '00000000-0000-4000-8000-0000000000e1';
  insert into venue_check (check_name, result) values ('Owner points a document outside their folder', 'ALLOWED - problem');
exception when others then insert into venue_check (check_name, result) values ('Owner points a document outside their folder', 'blocked');
end $$;
insert into venue_check (check_name, result) select 'Owner sees admin checks (want 0)', count(*)::text from public.venue_checks;
do $$ begin
  insert into public.venue_checks (venue_id, id_ok, licence_ok, insurance_ok) values ('00000000-0000-4000-8000-0000000000e1', true, true, true);
  insert into venue_check (check_name, result) values ('Owner ticks their own checks', 'ALLOWED - problem');
exception when others then insert into venue_check (check_name, result) values ('Owner ticks their own checks', 'blocked');
end $$;
do $$ begin
  perform public.approve_venue('00000000-0000-4000-8000-0000000000e1');
  insert into venue_check (check_name, result) values ('Owner approves their venue', 'ALLOWED - problem');
exception when others then insert into venue_check (check_name, result) values ('Owner approves their venue', 'blocked');
end $$;
-- Files (undone at the end of the block, so nothing is left in storage)
do $$
declare own_ok text; other_sees text; other_up text; anon_sees text; admin_sees text; photo_ok text;
begin
  begin
    insert into storage.objects (bucket_id, name) values ('venue-docs', '00000000-0000-4000-8000-0000000000e1/id.pdf');
    own_ok := 'allowed';
  exception when others then own_ok := 'blocked - problem: ' || sqlerrm; end;
  begin
    insert into storage.objects (bucket_id, name) values ('venue-photos', '00000000-0000-4000-8000-0000000000e1/p1.jpg');
    photo_ok := 'allowed';
  exception when others then photo_ok := 'blocked - problem: ' || sqlerrm; end;
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000c003","role":"authenticated"}', true);
  select count(*)::text into other_sees from storage.objects where bucket_id = 'venue-docs' and name like '00000000-0000-4000-8000-0000000000e1/%';
  begin
    insert into storage.objects (bucket_id, name) values ('venue-docs', '00000000-0000-4000-8000-0000000000e1/fake.pdf');
    other_up := 'ALLOWED - problem';
  exception when others then other_up := 'blocked'; end;
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  select count(*)::text into anon_sees from storage.objects where bucket_id = 'venue-docs' and name like '00000000-0000-4000-8000-0000000000e1/%';
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000c001","role":"authenticated"}', true);
  select count(*)::text into admin_sees from storage.objects where bucket_id = 'venue-docs' and name like '00000000-0000-4000-8000-0000000000e1/%';
  raise exception 'undo' using detail = concat_ws('|', own_ok, photo_ok, other_sees, other_up, anon_sees, admin_sees);
exception when raise_exception then
  perform set_config('role', 'authenticated', true);
  declare d text; begin
    get stacked diagnostics d = pg_exception_detail;
    insert into venue_check (check_name, result) select * from unnest(
      array['Owner uploads a document', 'Owner uploads a photo', 'Other owner sees the document (want 0)', 'Other owner uploads into this venue',
            'Signed-out visitor sees the document (want 0)', 'Admin sees the document (want 1)'],
      string_to_array(d, '|'));
  end;
end $$;
-- Another owner
set local request.jwt.claims to '{"sub":"00000000-0000-4000-8000-00000000c003","role":"authenticated"}';
insert into venue_check (check_name, result) select 'Other owner sees the documents (want 0)', count(*)::text from public.venue_docs;
insert into venue_check (check_name, result) select 'Other owner sees the draft venue (want 0)', count(*)::text from public.venues where slug = 'rls-test-venue-1';
reset role;

-- Signed-out visitor
set local role anon;
set local request.jwt.claims to '{"role":"anon"}';
insert into venue_check (check_name, result) select 'Visitor sees the documents (want 0)', count(*)::text from public.venue_docs;
insert into venue_check (check_name, result) select 'Visitor sees the pending venue (want 0)', count(*)::text from public.venues where slug = 'rls-test-venue-1';
reset role;

-- Admin
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-4000-8000-00000000c001","role":"authenticated"}';
insert into venue_check (check_name, result) select 'Admin sees it waiting, with owner email',
  (select t ->> 'owner_email' from jsonb_array_elements(public.admin_stats() -> 'pending_venues') t where t ->> 'name' = 'Test Hall');
insert into venue_check (check_name, result) select 'Admin reads the documents (want 1)', count(*)::text from public.venue_docs where venue_id = '00000000-0000-4000-8000-0000000000e1';
do $$ begin
  perform public.approve_venue('00000000-0000-4000-8000-0000000000e1');
  insert into venue_check (check_name, result) values ('Admin approves before ticking checks', 'ALLOWED - problem');
exception when others then insert into venue_check (check_name, result) values ('Admin approves before ticking checks', 'blocked');
end $$;
insert into public.venue_checks (venue_id, id_ok, licence_ok, insurance_ok, checked_by)
values ('00000000-0000-4000-8000-0000000000e1', true, true, true, auth.uid());
select public.approve_venue('00000000-0000-4000-8000-0000000000e1');
insert into venue_check (check_name, result) select 'After approval (want live, true)', status::text || ', ' || verified::text from public.venues where slug = 'rls-test-venue-1';
update public.venue_checks set insurance_ok = false where venue_id = '00000000-0000-4000-8000-0000000000e1';
insert into venue_check (check_name, result) select 'Insurance unticked: badge (want false)', verified::text from public.venues where slug = 'rls-test-venue-1';
select public.send_back_venue('00000000-0000-4000-8000-0000000000e1', 'Please upload an insurance certificate that has not expired.');
insert into venue_check (check_name, result) select 'Sent back (want draft, note)', status::text || ', ' || left(review_note, 20) from public.venues where slug = 'rls-test-venue-1';
reset role;

-- Owner can't clear the admin's note
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-4000-8000-00000000c002","role":"authenticated"}';
do $$ begin
  update public.venues set review_note = null where slug = 'rls-test-venue-1';
  insert into venue_check (check_name, result) values ('Owner clears the admin note', 'ALLOWED - problem');
exception when others then insert into venue_check (check_name, result) values ('Owner clears the admin note', 'blocked');
end $$;
update public.venues set status = 'pending_review' where slug = 'rls-test-venue-1';
insert into venue_check (check_name, result) select 'Owner resubmits (want pending_review)', status::text from public.venues where slug = 'rls-test-venue-1';
reset role;

-- Clean up
delete from public.venues where slug like 'rls-test-venue-%';
delete from auth.users where email ilike '%@rls-test.invalid';
delete from public.admin_emails where email = 'admin@rls-test.invalid';
insert into venue_check (check_name, result) select 'Test data removed (want 0)',
  ((select count(*) from auth.users where email ilike '%@rls-test.invalid') + (select count(*) from public.venues where slug like 'rls-test-venue-%')
   + (select count(*) from public.venue_docs where venue_id = '00000000-0000-4000-8000-0000000000e1'))::text;
commit;
select check_name, result from venue_check order by n;
