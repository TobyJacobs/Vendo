-- Block bookings: a class, club or group books the same room and time every week (or every 2 or 4 weeks) in one go.
-- Each session is an ordinary booking, so availability, buffers, holds and the clash check all apply to every date.
-- Sessions in one block share a series_id. Venues can offer a discount for blocks of a minimum length.

alter table public.bookings
  add column if not exists series_id uuid,
  add column if not exists series_no smallint check (series_no is null or series_no between 1 and 52);
create index if not exists bookings_series_idx on public.bookings (series_id) where series_id is not null;

alter table public.venues
  add column if not exists block_discount_pct smallint not null default 0 check (block_discount_pct between 0 and 50),
  add column if not exists block_min_sessions smallint not null default 4 check (block_min_sessions between 2 and 52);
