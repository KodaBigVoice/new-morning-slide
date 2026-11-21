-- =====================================================================
-- Morning Slide: admins can correct a teacher's name and school initials
-- Paste into Supabase → SQL Editor → New query, then Run. Safe to run again.
-- Needs 00-all-in-one.sql to have been run first.
-- Announcements already posted keep the name and initials they were posted with.
-- =====================================================================
create or replace function public.ms_admin_update(uid uuid, new_name text, new_initials text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not ms_is_admin() then raise exception 'Only admins can do that'; end if;
  if coalesce(trim(new_name), '') = '' or coalesce(trim(new_initials), '') = '' then raise exception 'Name and school initials are both needed'; end if;
  update ms_staff
     set name = left(regexp_replace(trim(new_name), '\s+', ' ', 'g'), 60),
         initials = upper(left(regexp_replace(new_initials, '[^A-Za-z]', '', 'g'), 5))
   where id = uid;
end $$;
revoke all on function public.ms_admin_update(uuid, text, text) from public, anon;
grant execute on function public.ms_admin_update(uuid, text, text) to authenticated;
