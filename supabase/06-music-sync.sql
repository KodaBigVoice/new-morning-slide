-- =====================================================================
-- Morning Slide: data protection agreement, the school's music lessons, and slides saved online
-- Paste into Supabase → SQL Editor → New query, then Run. Safe to run again.
-- Needs 00-all-in-one.sql and 04-notices.sql to have been run first.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Data protection: when each person agreed to the staff guidance
-- ---------------------------------------------------------------------
alter table public.ms_staff add column if not exists agreed_at timestamptz;

create or replace function public.ms_agree() returns timestamptz
language plpgsql security definer set search_path = public as $$
declare t timestamptz := now();
begin
  update ms_staff set agreed_at = t where id = auth.uid();
  return t;
end $$;
grant execute on function public.ms_agree() to authenticated;

-- ---------------------------------------------------------------------
-- 2. Music lessons: one row per week (week_start is always a Monday), uploaded by an admin.
--    rows: [[form, pupil (first name + surname initial), day, minutes after midnight, teacher], ...]
--    Approved staff can read them; only admins can change them.
--    Weeks are deleted automatically two weeks after they finish.
-- ---------------------------------------------------------------------
create table if not exists public.ms_music (
  week_start    date primary key check (extract(isodow from week_start) = 1),
  file_name     text not null default '',
  rows          jsonb not null check (jsonb_typeof(rows) = 'array'),
  published_by  uuid default auth.uid(),
  published_at  timestamptz not null default now()
);
alter table public.ms_music enable row level security;

drop policy if exists ms_music_read on public.ms_music;
create policy ms_music_read on public.ms_music for select using (public.ms_is_staff());
drop policy if exists ms_music_admin on public.ms_music;
create policy ms_music_admin on public.ms_music for all using (public.ms_is_admin()) with check (public.ms_is_admin());

create or replace function public.ms_music_stamp() returns trigger
language plpgsql set search_path = public as $$
begin
  new.published_by := auth.uid();
  new.published_at := now();
  return new;
end $$;
drop trigger if exists ms_music_stamp on public.ms_music;
create trigger ms_music_stamp before insert or update on public.ms_music
  for each row execute function public.ms_music_stamp();

create or replace function public.ms_music_tidy() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from ms_music where week_start < current_date - 19;   -- Monday + 5 days (Saturday) + 14 days
  return null;
end $$;
drop trigger if exists ms_music_tidy on public.ms_music;
create trigger ms_music_tidy after insert or update on public.ms_music
  for each statement execute function public.ms_music_tidy();

revoke all on public.ms_music from anon;
grant select, insert, update, delete on public.ms_music to authenticated;

-- ---------------------------------------------------------------------
-- 3. Slides saved online: each teacher's own slide (timetable, notes, preps, design...).
--    Pictures and videos added to a slide stay on the laptop they were added on.
--    The owner can let other staff (e.g. their assistant tutor) edit it with their own account.
-- ---------------------------------------------------------------------
create table if not exists public.ms_slides (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null unique default auth.uid() references public.ms_staff(id) on delete cascade,
  data        jsonb not null check (jsonb_typeof(data) = 'object'),
  version     integer not null default 1,
  updated_at  timestamptz not null default now(),
  updated_by  uuid default auth.uid()
);
create table if not exists public.ms_slide_editors (
  slide_id  uuid not null references public.ms_slides(id) on delete cascade,
  user_id   uuid not null references public.ms_staff(id) on delete cascade,
  added_at  timestamptz not null default now(),
  primary key (slide_id, user_id)
);
alter table public.ms_slides        enable row level security;
alter table public.ms_slide_editors enable row level security;

create or replace function public.ms_can_edit(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select ms_is_staff() and exists (
    select 1 from ms_slides s where s.id = sid and (s.owner = auth.uid()
      or exists (select 1 from ms_slide_editors e where e.slide_id = sid and e.user_id = auth.uid())));
$$;

create or replace function public.ms_is_editor(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from ms_slide_editors e where e.slide_id = sid and e.user_id = auth.uid());
$$;
grant execute on function public.ms_is_editor(uuid) to authenticated;
-- (Checks the row's owner directly, so a new slide can be read back the moment it's saved.)
drop policy if exists ms_slides_read on public.ms_slides;
create policy ms_slides_read on public.ms_slides for select
  using (public.ms_is_staff() and (owner = auth.uid() or public.ms_is_editor(id)));
drop policy if exists ms_slides_new on public.ms_slides;
create policy ms_slides_new on public.ms_slides for insert with check (public.ms_is_staff() and owner = auth.uid());
drop policy if exists ms_slides_edit on public.ms_slides;
create policy ms_slides_edit on public.ms_slides for update
  using (public.ms_is_staff() and (owner = auth.uid() or public.ms_is_editor(id)))
  with check (public.ms_is_staff() and (owner = auth.uid() or public.ms_is_editor(id)));
drop policy if exists ms_slides_delete on public.ms_slides;
create policy ms_slides_delete on public.ms_slides for delete using (owner = auth.uid());

-- Editors are added and removed through the functions below; you can see the rows that involve you.
drop policy if exists ms_editors_read on public.ms_slide_editors;
create policy ms_editors_read on public.ms_slide_editors for select
  using (user_id = auth.uid() or exists (select 1 from ms_slides s where s.id = slide_id and s.owner = auth.uid()));

-- Owner stays the owner; the time, the version and who saved it are filled in by the database.
create or replace function public.ms_slide_stamp() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    new.owner := old.owner;
    new.version := old.version + 1;
  else
    new.owner := auth.uid();
    new.version := 1;
  end if;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;
drop trigger if exists ms_slide_stamp on public.ms_slides;
create trigger ms_slide_stamp before insert or update on public.ms_slides
  for each row execute function public.ms_slide_stamp();

-- The slides you can edit: your own, and any shared with you.
create or replace function public.ms_my_slides()
returns table (id uuid, mine boolean, owner_name text, owner_initials text, form text, version integer, updated_at timestamptz, updated_by_name text)
language sql stable security definer set search_path = public as $$
  select s.id, s.owner = auth.uid(), o.name, o.initials, coalesce(s.data->>'form', ''), s.version, s.updated_at, u.name
  from ms_slides s join ms_staff o on o.id = s.owner left join ms_staff u on u.id = s.updated_by
  where ms_is_staff() and (s.owner = auth.uid() or exists (select 1 from ms_slide_editors e where e.slide_id = s.id and e.user_id = auth.uid()))
  order by s.owner = auth.uid() desc, o.name;
$$;

-- People who can edit your slide.
create or replace function public.ms_my_editors()
returns table (user_id uuid, name text, initials text, email text)
language sql stable security definer set search_path = public as $$
  select e.user_id, p.name, p.initials, p.email
  from ms_slide_editors e join ms_slides s on s.id = e.slide_id join ms_staff p on p.id = e.user_id
  where s.owner = auth.uid() order by p.name;
$$;

-- Let someone edit your slide, by their school email. They need an approved account.
create or replace function public.ms_share_slide(their_email text) returns text
language plpgsql security definer set search_path = public as $$
declare sid uuid; who ms_staff;
begin
  if not ms_is_staff() then raise exception 'Not signed in'; end if;
  select id into sid from ms_slides where owner = auth.uid();
  if sid is null then raise exception 'Your slide isn''t saved online yet'; end if;
  select * into who from ms_staff where email = lower(trim(their_email)) and status = 'approved';
  if who.id is null then raise exception 'No approved Morning Slide account for %', lower(trim(their_email)); end if;
  if who.id = auth.uid() then raise exception 'That''s you'; end if;
  insert into ms_slide_editors (slide_id, user_id) values (sid, who.id) on conflict do nothing;
  return who.name;
end $$;

-- Owner removes an editor, or an editor stops editing someone's slide.
create or replace function public.ms_unshare_slide(sid uuid, uid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from ms_slide_editors e
  where e.slide_id = sid and e.user_id = uid
    and (uid = auth.uid() or exists (select 1 from ms_slides s where s.id = sid and s.owner = auth.uid()));
end $$;

grant select, insert, update, delete on public.ms_slides to authenticated;
grant select on public.ms_slide_editors to authenticated;
revoke all on public.ms_slides, public.ms_slide_editors from anon;
grant execute on function public.ms_can_edit(uuid), public.ms_my_slides(), public.ms_my_editors(),
  public.ms_share_slide(text), public.ms_unshare_slide(uuid, uuid) to authenticated;

-- Check: should say 0 and 0 the first time.
select (select count(*) from public.ms_music) as music_weeks, (select count(*) from public.ms_slides) as slides;
