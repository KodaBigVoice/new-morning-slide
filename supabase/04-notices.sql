-- =====================================================================
-- Morning Slide: school notices (stage 2)
-- Paste into Supabase → SQL Editor → New query, then Run. Safe to run again.
-- Needs the accounts file (00-all-in-one.sql) to have been run first.
-- =====================================================================

-- One row per notice.
-- audience: {"all":true} or any of {"sections":["MS"],"years":[7],"forms":["8DE"]}
create table if not exists public.ms_notices (
  id              uuid primary key default gen_random_uuid(),
  author          uuid references public.ms_staff(id) on delete set null default auth.uid(),
  author_name     text not null default '',
  author_initials text not null default '',
  body            text not null check (char_length(trim(body)) between 1 and 140),
  start_date      date not null,
  end_date        date not null,
  audience        jsonb not null default '{"all":true}'::jsonb,
  prep_eve        boolean not null default true,       -- also on the prep slide the evening before
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (end_date >= start_date and end_date - start_date <= 31),
  check (jsonb_typeof(audience) = 'object')
);
create index if not exists ms_notices_end on public.ms_notices (end_date);

-- Notices a teacher has hidden from their own slide (follows their account to any laptop).
create table if not exists public.ms_notice_hides (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  notice_id  uuid not null references public.ms_notices(id) on delete cascade,
  primary key (user_id, notice_id)
);

alter table public.ms_notices      enable row level security;
alter table public.ms_notice_hides enable row level security;

-- Who wrote it is always the signed-in person, with their name and initials as they are now.
create or replace function public.ms_notice_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
declare s ms_staff;
begin
  if tg_op = 'INSERT' then
    new.author := auth.uid();
    new.created_at := now();
  else
    new.author := old.author; new.created_at := old.created_at;
    new.author_name := old.author_name; new.author_initials := old.author_initials;
  end if;
  if tg_op = 'INSERT' then
    select * into s from ms_staff where id = auth.uid();
    new.author_name := coalesce(s.name, '');
    new.author_initials := coalesce(s.initials, '');
  end if;
  new.body := trim(new.body);
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists ms_notice_stamp on public.ms_notices;
create trigger ms_notice_stamp before insert or update on public.ms_notices
  for each row execute function public.ms_notice_stamp();

-- Tidy up: notices that finished more than 30 days ago are deleted whenever someone posts.
create or replace function public.ms_notice_tidy() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from ms_notices where end_date < current_date - 30;
  return null;
end $$;
drop trigger if exists ms_notice_tidy on public.ms_notices;
create trigger ms_notice_tidy after insert on public.ms_notices
  for each statement execute function public.ms_notice_tidy();

-- Rules
--   approved staff can read every notice and post their own;
--   you can change or delete your own; admins can delete anyone's.
drop policy if exists ms_notices_read on public.ms_notices;
create policy ms_notices_read on public.ms_notices for select using (public.ms_is_staff());
drop policy if exists ms_notices_post on public.ms_notices;
create policy ms_notices_post on public.ms_notices for insert with check (public.ms_is_staff());
drop policy if exists ms_notices_edit on public.ms_notices;
create policy ms_notices_edit on public.ms_notices for update
  using (public.ms_is_staff() and author = auth.uid()) with check (public.ms_is_staff() and author = auth.uid());
drop policy if exists ms_notices_delete on public.ms_notices;
create policy ms_notices_delete on public.ms_notices for delete
  using ((public.ms_is_staff() and author = auth.uid()) or public.ms_is_admin());

drop policy if exists ms_hides_own on public.ms_notice_hides;
create policy ms_hides_own on public.ms_notice_hides for all
  using (user_id = auth.uid()) with check (user_id = auth.uid() and public.ms_is_staff());

grant select, insert, update, delete on public.ms_notices to authenticated;
grant select, insert, delete on public.ms_notice_hides to authenticated;
revoke all on public.ms_notices, public.ms_notice_hides from anon;

-- Check: should say 0 notices the first time.
select count(*) as notices from public.ms_notices;
