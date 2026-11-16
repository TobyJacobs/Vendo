-- Checks admin access: a pretend admin and a pretend normal user, removed again at the end.
-- Run in the Supabase SQL editor; when it offers to "enable RLS" on admin_check, choose "Run without RLS" (temporary table).
begin;
create temp table admin_check (n serial, check_name text, result text);
grant all on admin_check to authenticated;
grant usage, select on sequence admin_check_n_seq to authenticated;
insert into public.admin_emails (email) values ('admin@rls-test.invalid');
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-00000000b001', 'Admin@RLS-test.invalid', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-00000000b002', 'guest@rls-test.invalid', 'authenticated', 'authenticated');
insert into admin_check (check_name, result) select 'Sign-up works, listed email made admin (want true)', is_admin::text from public.profiles where id = '00000000-0000-4000-8000-00000000b001';
insert into admin_check (check_name, result) select 'Other email not admin (want false)', is_admin::text from public.profiles where id = '00000000-0000-4000-8000-00000000b002';
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-4000-8000-00000000b002","role":"authenticated"}';
do $$ begin
  perform public.admin_stats();
  insert into admin_check (check_name, result) values ('Normal user reads stats', 'ALLOWED - problem');
exception when others then insert into admin_check (check_name, result) values ('Normal user reads stats', 'blocked');
end $$;
insert into admin_check (check_name, result) select 'Normal user sees costs (want 0)', count(*)::text from public.admin_costs;
do $$ begin
  update public.profiles set is_admin = true where id = auth.uid();
  insert into admin_check (check_name, result) values ('Normal user makes themselves admin', 'ALLOWED - problem');
exception when others then insert into admin_check (check_name, result) values ('Normal user makes themselves admin', 'blocked');
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims to '{"sub":"00000000-0000-4000-8000-00000000b001","role":"authenticated"}';
insert into admin_check (check_name, result) select 'Admin reads stats: venues live', (public.admin_stats() -> 'venues' ->> 'live');
insert into admin_check (check_name, result) select 'Admin reads stats: months returned', jsonb_array_length(public.admin_stats() -> 'months')::text;
insert into admin_check (check_name, result) select 'Admin sees costs', count(*)::text from public.admin_costs;
reset role;
delete from auth.users where email ilike '%@rls-test.invalid';
delete from public.admin_emails where email = 'admin@rls-test.invalid';
insert into admin_check (check_name, result) select 'Test data removed (want 0)',
  ((select count(*) from auth.users where email ilike '%@rls-test.invalid') + (select count(*) from public.admin_emails where email ilike '%@rls-test.invalid'))::text;
commit;
select check_name, result from admin_check order by n;
