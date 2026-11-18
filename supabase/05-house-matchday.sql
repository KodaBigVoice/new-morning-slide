-- =====================================================================
-- Morning Slide: the school's house meeting schedule, and matchday lunch queues
-- Paste into Supabase → SQL Editor → New query, then Run. Safe to run again.
-- Needs the accounts file (00-all-in-one.sql) to have been run first.
-- Neither table holds anyone's name: rooms, team labels, doors and times only.
-- Everyone can read them (signed in or not); only admins can change them.
-- =====================================================================

-- One row per house meeting date: congers, or a room for each house.
create table if not exists public.ms_house (
  date        date primary key,
  congers     boolean not null default false,
  rooms       jsonb not null default '{}'::jsonb,     -- {"Athlone":"DJC","Alexander":"Sports Hall",...}
  updated_at  timestamptz not null default now(),
  check (jsonb_typeof(rooms) = 'object')
);

-- One row per matchday: the lunch queues published from Matchday Queues.
create table if not exists public.ms_matchday (
  date          date primary key,
  data          jsonb not null,
  published_by  uuid default auth.uid(),
  published_at  timestamptz not null default now(),
  check (jsonb_typeof(data) = 'object')
);

alter table public.ms_house    enable row level security;
alter table public.ms_matchday enable row level security;

drop policy if exists ms_house_read on public.ms_house;
create policy ms_house_read on public.ms_house for select using (true);
drop policy if exists ms_house_admin on public.ms_house;
create policy ms_house_admin on public.ms_house for all using (public.ms_is_admin()) with check (public.ms_is_admin());

drop policy if exists ms_matchday_read on public.ms_matchday;
create policy ms_matchday_read on public.ms_matchday for select using (true);
drop policy if exists ms_matchday_admin on public.ms_matchday;
create policy ms_matchday_admin on public.ms_matchday for all using (public.ms_is_admin()) with check (public.ms_is_admin());

-- Who published, and when, is always filled in by the database.
create or replace function public.ms_matchday_stamp() returns trigger
language plpgsql set search_path = public as $$
begin
  new.published_by := auth.uid();
  new.published_at := now();
  return new;
end $$;
drop trigger if exists ms_matchday_stamp on public.ms_matchday;
create trigger ms_matchday_stamp before insert or update on public.ms_matchday
  for each row execute function public.ms_matchday_stamp();

create or replace function public.ms_house_stamp() returns trigger
language plpgsql set search_path = public as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists ms_house_stamp on public.ms_house;
create trigger ms_house_stamp before insert or update on public.ms_house
  for each row execute function public.ms_house_stamp();

grant select on public.ms_house, public.ms_matchday to anon, authenticated;
grant insert, update, delete on public.ms_house, public.ms_matchday to authenticated;

-- This term's schedule, as it was built into Morning Slide (dates already there are left alone).
insert into public.ms_house (date, congers, rooms) values
  ('2026-09-24', false, '{"Athlone": "DJC", "Alexander": "Sports Hall", "Goodhart": "BG Room", "Dewar": "Dining Room"}'::jsonb),
  ('2026-10-01', true, '{}'::jsonb),
  ('2026-10-08', false, '{"Athlone": "Sports Hall", "Alexander": "BG Room", "Goodhart": "Dining Room", "Dewar": "DJC (Talent show)"}'::jsonb),
  ('2026-10-15', false, '{"Athlone": "BG Room", "Alexander": "Dining Room", "Goodhart": "DJC (Talent show)", "Dewar": "Sports Hall"}'::jsonb),
  ('2026-10-22', true, '{}'::jsonb),
  ('2026-11-12', false, '{"Athlone": "Dining Room", "Alexander": "DJC (Talent show)", "Goodhart": "Sports Hall", "Dewar": "BG Room"}'::jsonb),
  ('2026-11-19', true, '{}'::jsonb),
  ('2026-11-26', false, '{"Athlone": "DJC (Talent show)", "Alexander": "Sports Hall", "Goodhart": "BG Room", "Dewar": "Dining Room"}'::jsonb),
  ('2026-12-03', false, '{"Athlone": "Sports Hall", "Alexander": "BG Room", "Goodhart": "Dining Room", "Dewar": "DJC"}'::jsonb)
on conflict (date) do nothing;

-- Check: how many house meeting dates there are now.
select count(*) as house_dates from public.ms_house;
