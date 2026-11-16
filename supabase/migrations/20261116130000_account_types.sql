-- Account types and sign-up details.
-- A profile is either a guest (planning an event) or a host (runs a venue). Hosts still need a Vendo admin
-- to put each venue live, so choosing "host" gives no extra access on its own.

alter table public.profiles
  add column if not exists account_type text not null default 'guest' check (account_type in ('guest', 'host')),
  add column if not exists business_name text check (business_name is null or char_length(business_name) <= 120),
  add column if not exists business_type text check (business_type is null or char_length(business_type) <= 60),
  add column if not exists terms_accepted_at timestamptz,
  add column if not exists marketing_opt_in boolean not null default false;

-- Copy the sign-up form's details into the new profile. Everything is length-limited and checked here,
-- because sign-up details come straight from the browser.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.profiles (id, full_name, phone, town, account_type, business_name, business_type, terms_accepted_at, marketing_opt_in)
  values (
    new.id,
    left(coalesce(m ->> 'full_name', ''), 80),
    nullif(left(coalesce(m ->> 'phone', ''), 30), ''),
    nullif(left(coalesce(m ->> 'town', ''), 60), ''),
    case when m ->> 'account_type' = 'host' then 'host' else 'guest' end,
    nullif(left(coalesce(m ->> 'business_name', ''), 120), ''),
    nullif(left(coalesce(m ->> 'business_type', ''), 60), ''),
    case when m ->> 'terms_accepted' = 'true' then now() end,
    coalesce(m ->> 'marketing_opt_in', '') = 'true'
  );
  return new;
end $$;
