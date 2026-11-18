-- =====================================================================
-- Morning Slide: let signed-in staff reach the account tables (stage 1, part 3)
-- Paste into Supabase → SQL Editor → New query, then Run. Safe to run again.
-- The row-level rules from 01-accounts.sql still decide what each person sees:
-- you see your own account; only admins see everyone and the approved list.
-- =====================================================================
grant usage on schema public to authenticated;
grant select on public.ms_staff to authenticated;
grant select, insert, update, delete on public.ms_allowed to authenticated;
revoke all on public.ms_staff, public.ms_allowed from anon;

-- Check: this should list your account, approved, as admin.
select email, name, initials, role, status from public.ms_staff;
