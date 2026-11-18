-- New pricing: guests pay no booking fee, and venues pay Vendo 10% of each paid booking (room hire and extras).
-- The admin dashboard's takings now count 10% of hire and extras. fee_pence (the old 4% guest fee) is still added,
-- so earlier bookings that carried it keep counting it; new bookings save 0 there.
create or replace function public.admin_stats() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  if not public.is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;
  with b as (
    select k.*, k.status in ('confirmed', 'completed') as won,
           k.fee_pence + round((k.hire_pence + k.extras_pence) * 0.10)::int as vendo_pence,
           round(k.total_pence * 0.015)::int + 20 as card_pence
      from public.bookings k
  ), months as (
    select generate_series(date_trunc('month', now()) - interval '11 months', date_trunc('month', now()), interval '1 month') as m
  )
  select jsonb_build_object(
    'generated_at', now(),
    'venues', coalesce((select jsonb_object_agg(status, n) from (select status::text, count(*) n from public.venues group by status) x), '{}'::jsonb),
    'venues_demo', (select count(*) from public.venues where is_demo),
    'customers', (select count(*) from public.profiles where account_type = 'guest'),
    'hosts', (select count(*) from public.profiles where account_type = 'host'),
    'signups_30d', (select count(*) from public.profiles where created_at > now() - interval '30 days'),
    'bookings', coalesce((select jsonb_object_agg(status, n) from (select status::text, count(*) n from b group by status) x), '{}'::jsonb),
    'gmv_pence', (select coalesce(sum(total_pence), 0) from b where won),
    'pipeline_pence', (select coalesce(sum(total_pence), 0) from b where status = 'requested'),
    'vendo_pence', (select coalesce(sum(vendo_pence), 0) from b where won),
    'card_pence', (select coalesce(sum(card_pence), 0) from b where won),
    'costs_monthly_pence', (select coalesce(sum(monthly_pence), 0) from public.admin_costs),
    'months', (select jsonb_agg(jsonb_build_object(
        'm', to_char(m, 'YYYY-MM'),
        'bookings', (select count(*) from b where date_trunc('month', b.created_at) = months.m),
        'gmv', (select coalesce(sum(total_pence), 0) from b where won and date_trunc('month', b.created_at) = months.m),
        'vendo', (select coalesce(sum(vendo_pence), 0) from b where won and date_trunc('month', b.created_at) = months.m),
        'card', (select coalesce(sum(card_pence), 0) from b where won and date_trunc('month', b.created_at) = months.m),
        'signups', (select count(*) from public.profiles p where date_trunc('month', p.created_at) = months.m)
      ) order by m) from months),
    'top_venues', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select v.name, v.slug, v.status::text, count(b.id) as bookings,
               coalesce(sum(b.total_pence) filter (where b.won), 0) as gmv
          from public.venues v left join b on b.venue_id = v.id
         group by v.id order by count(b.id) desc, v.name limit 8) t),
    'event_types', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select event_type, count(*) as n from b group by event_type order by count(*) desc limit 8) t),
    'recent_bookings', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select b.ref, b.status::text, b.event_label, b.event_date, b.guests, b.total_pence, b.created_at, b.contact_name, v.name as venue
          from b join public.venues v on v.id = b.venue_id order by b.created_at desc limit 10) t),
    'recent_signups', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select p.full_name, u.email, p.account_type, p.business_name, p.created_at
          from public.profiles p join auth.users u on u.id = p.id order by p.created_at desc limit 10) t),
    'pending_venues', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
        select v.id, v.name, v.place, v.kind, v.created_at, v.updated_at, p.full_name as owner, p.business_name, u.email as owner_email,
               d.submitted_at
          from public.venues v left join public.profiles p on p.id = v.owner_id left join auth.users u on u.id = v.owner_id
          left join public.venue_docs d on d.venue_id = v.id
         where v.status = 'pending_review' order by coalesce(d.submitted_at, v.created_at)) t),
    'verified_venues', (select count(*) from public.venues where verified and status = 'live')
  ) into r;
  return r;
end $$;
revoke all on function public.admin_stats() from public, anon;
grant execute on function public.admin_stats() to authenticated;
