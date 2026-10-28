-- Allow supporting files (medical letters, handover notes...) on leave requests.
create or replace function public.can_access_parent(p_type text, p_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_approved() and case p_type
    when 'task' then exists(select 1 from public.tasks t
      where t.id = p_id and (t.assigned_to = auth.uid() or t.assigned_by = auth.uid() or public.is_admin()))
    when 'announcement' then exists(select 1 from public.announcements a
      where a.id = p_id and (
        public.is_admin() or a.author_id = auth.uid()
        or (a.published and (a.audience = 'organization'
            or (a.audience = 'department' and a.department = (select department from public.staff_profiles where id = auth.uid()))))))
    when 'meeting' then exists(select 1 from public.meetings m where m.id = p_id)
    when 'message' then exists(select 1 from public.messages x
      where x.id = p_id and (x.sender_id = auth.uid() or x.recipient_id = auth.uid()))
    when 'discussion' then public.can_view_discussion(p_id)
    when 'discussion_reply' then coalesce(public.can_view_discussion(public.discussion_of('reply', p_id)), false)
    when 'leave_request' then exists(select 1 from public.leave_requests l
      join public.staff_profiles s on s.id = l.staff_id
      where l.id = p_id and (l.staff_id = auth.uid() or public.is_admin()
        or exists(select 1 from public.staff_profiles me where me.id = auth.uid()
                  and me.system_role = 'department_head' and me.department is not null and me.department = s.department)))
    else false end;
$$;

create or replace function public.can_attach_parent(p_type text, p_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_approved() and case p_type
    when 'task' then public.can_access_parent('task', p_id)
    when 'announcement' then exists(select 1 from public.announcements a
      where a.id = p_id and (a.author_id = auth.uid() or public.is_admin()))
    when 'meeting' then exists(select 1 from public.meetings m
      where m.id = p_id and (m.organizer_id = auth.uid() or public.is_admin()))
    when 'message' then exists(select 1 from public.messages x where x.id = p_id and x.sender_id = auth.uid())
    when 'discussion' then exists(select 1 from public.discussions d
      where d.id = p_id and (d.author_id = auth.uid() or public.is_admin()))
    when 'discussion_reply' then exists(select 1 from public.discussion_replies r
      where r.id = p_id and r.author_id = auth.uid())
    when 'leave_request' then exists(select 1 from public.leave_requests l where l.id = p_id and l.staff_id = auth.uid())
    else false end;
$$;

alter table public.attachments drop constraint if exists attachments_parent_type_check;
alter table public.attachments add constraint attachments_parent_type_check
  check (parent_type in ('task','announcement','meeting','message','discussion','discussion_reply','leave_request'));

-- remove attachment rows when a leave request is deleted
create or replace function public.cleanup_leave_attachments()
returns trigger language plpgsql security definer set search_path=public as $$
begin delete from public.attachments where parent_type='leave_request' and parent_id=old.id; return old; end $$;
drop trigger if exists cleanup_leave_attachments on public.leave_requests;
create trigger cleanup_leave_attachments before delete on public.leave_requests
  for each row execute function public.cleanup_leave_attachments();
