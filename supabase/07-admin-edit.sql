-- =====================================================================
-- Morning Slide: admins can correct a teacher's name and school initials.
-- Corrections (by an admin, or by the teacher in Setup → Account) also update
-- Timetable Maker's staff list, so both apps agree.
-- Paste into Supabase → SQL Editor → New query, then Run. Safe to run again.
-- Needs 00-all-in-one.sql to have been run first.
-- Announcements already posted keep the name and initials they were posted with.
-- =====================================================================

-- Timetable Maker's staff list: swap the old name for the new one, with the new initials.
-- Leaves Timetable Maker alone if its staff list isn't laid out as expected.
create or replace function public.ms_rename_in_tt(old_name text, new_name text, new_initials text) returns void
language plpgsql security definer set search_path = public as $$
declare kind text; staff jsonb;
begin
  if new_name is null or new_name = '' then return; end if;
  select jsonb_typeof(value) into kind from tt_settings, jsonb_each(coalesce(data->'staff', '{}'::jsonb)) limit 1;
  if kind is not null and kind <> 'string' then return; end if;
  select coalesce(data->'staff', '{}'::jsonb) into staff from tt_settings order by id limit 1;
  if staff is null then return; end if;
  if old_name is not null and old_name <> new_name then staff := staff - old_name; end if;
  staff := staff || jsonb_build_object(new_name, new_initials);
  update tt_settings set data = data || jsonb_build_object('staff', staff), updated_at = now()
   where id = (select id from tt_settings order by id limit 1);
end $$;
revoke all on function public.ms_rename_in_tt(text, text, text) from public, anon, authenticated;

-- An admin corrects someone's name and school initials.
create or replace function public.ms_admin_update(uid uuid, new_name text, new_initials text) returns void
language plpgsql security definer set search_path = public as $$
declare s ms_staff; nm text; ini text;
begin
  if not ms_is_admin() then raise exception 'Only admins can do that'; end if;
  nm := left(regexp_replace(trim(coalesce(new_name, '')), '\s+', ' ', 'g'), 60);
  ini := upper(left(regexp_replace(coalesce(new_initials, ''), '[^A-Za-z]', '', 'g'), 5));
  if nm = '' or ini = '' then raise exception 'Name and school initials are both needed'; end if;
  select * into s from ms_staff where id = uid;
  if s.id is null then raise exception 'No such account'; end if;
  update ms_staff set name = nm, initials = ini where id = uid;
  if s.status = 'approved' then perform ms_rename_in_tt(s.name, nm, ini); end if;   -- only approved staff are in Timetable Maker
end $$;
revoke all on function public.ms_admin_update(uuid, text, text) from public, anon;
grant execute on function public.ms_admin_update(uuid, text, text) to authenticated;

-- A teacher changes their own details (Setup → Account): same as before, and Timetable Maker follows.
create or replace function public.ms_update_me(new_name text, new_initials text) returns void
language plpgsql security definer set search_path = public as $$
declare s ms_staff; old_name text;
begin
  select name into old_name from ms_staff where id = auth.uid();
  if old_name is null then return; end if;
  update ms_staff
     set name = left(coalesce(nullif(trim(new_name), ''), name), 60),
         initials = upper(left(coalesce(nullif(trim(new_initials), ''), initials), 5))
   where id = auth.uid()
  returning * into s;
  if s.status = 'approved' then perform ms_rename_in_tt(old_name, s.name, s.initials); end if;
end $$;
