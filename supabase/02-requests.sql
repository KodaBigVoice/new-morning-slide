-- =====================================================================
-- Morning Slide: access requests with "has confirmed their email" (stage 1, part 2)
-- Paste into Supabase → SQL Editor → New query, then Run. Safe to run again.
-- =====================================================================

-- Admins only: people waiting for approval, and whether they've clicked the link in their confirmation email.
create or replace function public.ms_requests()
returns table (id uuid, email text, name text, initials text, created_at timestamptz, confirmed boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not ms_is_admin() then raise exception 'Admins only'; end if;
  return query
    select s.id, s.email, s.name, s.initials, s.created_at, (u.email_confirmed_at is not null)
      from ms_staff s join auth.users u on u.id = s.id
     where s.status = 'pending'
     order by s.created_at;
end $$;

revoke all on function public.ms_requests() from public, anon;
grant execute on function public.ms_requests() to authenticated;
