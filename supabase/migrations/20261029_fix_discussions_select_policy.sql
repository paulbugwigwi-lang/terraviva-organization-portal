-- The select policy must not call a function that re-queries "discussions": a STABLE function cannot see the row
-- being inserted, so "insert ... returning" failed with "new row violates row-level security policy".
drop policy if exists discussions_select on public.discussions;
create policy discussions_select on public.discussions for select to authenticated
  using (
    public.is_approved() and (
      author_id = (select auth.uid())
      or audience = 'organization'
      or public.is_admin()
      or (audience = 'department' and department is not distinct from
          (select department from public.staff_profiles where id = (select auth.uid())))
    )
  );
