-- =====================================================================
-- Morning Slide: staff accounts (stage 1)
-- Paste into Supabase → SQL Editor → New query, then Run. Safe to run again: it only creates what's missing.
-- Timetable Maker's tables (tt_settings, tt_secret) and functions are not touched.
-- =====================================================================

-- Approved staff emails. Private: only admins can read or change it.
create table if not exists public.ms_allowed (
  email      text primary key check (email = lower(email)),
  role       text not null default 'teacher' check (role in ('teacher', 'admin')),
  added_at   timestamptz not null default now()
);

-- One row per account. Created automatically when someone signs up.
create table if not exists public.ms_staff (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null unique,
  name        text not null,                 -- title and surname as on iSAMS, e.g. "Mr Joshi"
  initials    text not null,
  role        text not null default 'teacher' check (role in ('teacher', 'admin')),
  status      text not null default 'pending' check (status in ('pending', 'approved')),
  created_at  timestamptz not null default now(),
  approved_at timestamptz
);

alter table public.ms_allowed enable row level security;
alter table public.ms_staff   enable row level security;

-- Who is signed in, and what they may do
create or replace function public.ms_is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from ms_staff where id = auth.uid() and status = 'approved');
$$;
create or replace function public.ms_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from ms_staff where id = auth.uid() and status = 'approved' and role = 'admin');
$$;

-- Rules: you see your own account; admins see and manage everyone.
drop policy if exists ms_staff_read on public.ms_staff;
create policy ms_staff_read on public.ms_staff for select
  using (id = auth.uid() or public.ms_is_admin());

drop policy if exists ms_allowed_admin on public.ms_allowed;
create policy ms_allowed_admin on public.ms_allowed for all
  using (public.ms_is_admin()) with check (public.ms_is_admin());

-- The school's forms come from Timetable Maker's settings (one list for both apps).
-- Signed-in, approved staff can read them; Timetable Maker stays the place to edit them.
create or replace function public.ms_forms() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not ms_is_staff() then return '[]'::jsonb; end if;
  return coalesce((select data->'forms' from tt_settings order by id limit 1), '[]'::jsonb);
end $$;

-- Adds an approved teacher to Timetable Maker's staff list ("Mr Joshi" → initials),
-- only if they aren't already there. Nothing else in Timetable Maker's settings changes.
create or replace function public.ms_add_to_tt(staff_name text, staff_initials text) returns void
language plpgsql security definer set search_path = public as $$
declare kind text;
begin
  if staff_name is null or staff_name = '(no name)' then return; end if;
  select jsonb_typeof(value) into kind from tt_settings, jsonb_each(coalesce(data->'staff', '{}'::jsonb)) limit 1;
  if kind is not null and kind <> 'string' then return; end if;   -- unexpected layout: leave it alone
  update tt_settings
     set data = data || jsonb_build_object('staff', coalesce(data->'staff', '{}'::jsonb) || jsonb_build_object(staff_name, staff_initials)),
         updated_at = now()
   where id = (select id from tt_settings order by id limit 1)
     and not coalesce(data->'staff', '{}'::jsonb) ? staff_name;
end $$;
revoke all on function public.ms_add_to_tt(text, text) from public, anon, authenticated;

-- Signing up: school addresses only. On the approved list → straight in; otherwise → waiting for an admin.
create or replace function public.ms_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  em   text  := lower(new.email);
  ok   ms_allowed;
begin
  if em !~ '@lambrookschool\.co\.uk$' then
    raise exception 'Only Lambrook School email addresses can sign up';
  end if;
  select * into ok from ms_allowed where email = em;
  insert into ms_staff (id, email, name, initials, role, status, approved_at)
  values (
    new.id, em,
    left(coalesce(nullif(trim(meta->>'name'), ''), '(no name)'), 60),
    upper(left(coalesce(nullif(trim(meta->>'initials'), ''), '?'), 5)),
    coalesce(ok.role, 'teacher'),
    case when ok.email is not null then 'approved' else 'pending' end,
    case when ok.email is not null then now() end
  );
  if ok.email is not null then
    perform ms_add_to_tt(left(coalesce(nullif(trim(meta->>'name'), ''), '(no name)'), 60), upper(left(coalesce(nullif(trim(meta->>'initials'), ''), '?'), 5)));
  end if;
  return new;
end $$;

drop trigger if exists ms_on_new_user on auth.users;
create trigger ms_on_new_user after insert on auth.users
  for each row execute function public.ms_new_user();

-- Admin actions
create or replace function public.ms_approve(uid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s ms_staff;
begin
  if not ms_is_admin() then raise exception 'Admins only'; end if;
  update ms_staff set status = 'approved', approved_at = now() where id = uid returning * into s;
  if s.id is null then raise exception 'No such account'; end if;
  insert into ms_allowed (email, role) values (s.email, s.role) on conflict (email) do nothing;
  perform ms_add_to_tt(s.name, s.initials);
end $$;

create or replace function public.ms_decline(uid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not ms_is_admin() then raise exception 'Admins only'; end if;
  if uid = auth.uid() then raise exception 'You can''t remove your own account'; end if;
  delete from auth.users where id = uid;          -- removes the login and its ms_staff row
end $$;

create or replace function public.ms_set_role(uid uuid, new_role text) returns void
language plpgsql security definer set search_path = public as $$
declare s ms_staff;
begin
  if not ms_is_admin() then raise exception 'Admins only'; end if;
  if new_role not in ('teacher', 'admin') then raise exception 'Unknown role'; end if;
  if uid = auth.uid() and new_role <> 'admin' then raise exception 'You can''t remove your own admin role'; end if;
  update ms_staff set role = new_role where id = uid returning * into s;
  update ms_allowed set role = new_role where email = s.email;
end $$;

-- Your own name and initials
create or replace function public.ms_update_me(new_name text, new_initials text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update ms_staff
     set name = left(coalesce(nullif(trim(new_name), ''), name), 60),
         initials = upper(left(coalesce(nullif(trim(new_initials), ''), initials), 5))
   where id = auth.uid();
end $$;

revoke all on function public.ms_approve(uuid), public.ms_decline(uuid), public.ms_set_role(uuid, text), public.ms_update_me(text, text) from public, anon;
grant execute on function public.ms_approve(uuid), public.ms_decline(uuid), public.ms_set_role(uuid, text), public.ms_update_me(text, text) to authenticated;
grant execute on function public.ms_is_staff(), public.ms_is_admin(), public.ms_forms() to authenticated;

-- ---------------------------------------------------------------------
-- The first admin. On a brand-new project, after running this file, open Table Editor → ms_allowed
-- and add a row with your school email and role "admin", then create your account on the site.
-- More admins can be made later from Setup → Admin.
-- ---------------------------------------------------------------------
