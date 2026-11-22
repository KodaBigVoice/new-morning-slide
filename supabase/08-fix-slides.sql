-- =====================================================================
-- Morning Slide: fix for saving slides online (run once, after 06 and 07). Safe to run again.
-- The first save of a slide was refused, because the "who can see this slide" rule looked the
-- new slide up in the table before it was there. The rules now check the slide's owner directly.
-- =====================================================================
create or replace function public.ms_is_editor(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from ms_slide_editors e where e.slide_id = sid and e.user_id = auth.uid());
$$;
grant execute on function public.ms_is_editor(uuid) to authenticated;

drop policy if exists ms_slides_read on public.ms_slides;
create policy ms_slides_read on public.ms_slides for select
  using (public.ms_is_staff() and (owner = auth.uid() or public.ms_is_editor(id)));
drop policy if exists ms_slides_edit on public.ms_slides;
create policy ms_slides_edit on public.ms_slides for update
  using (public.ms_is_staff() and (owner = auth.uid() or public.ms_is_editor(id)))
  with check (public.ms_is_staff() and (owner = auth.uid() or public.ms_is_editor(id)));

-- Check: should say true
select exists (select 1 from pg_policies where policyname = 'ms_slides_read' and qual like '%ms_is_editor%') as fixed;
