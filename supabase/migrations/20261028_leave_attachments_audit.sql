-- Leave-request attachments (medical letters, handover notes...) + restore the audit trail and the missing notification triggers.

-- 1) attachments for leave requests
alter table public.attachments drop constraint if exists attachments_parent_type_check;
alter table public.attachments add constraint attachments_parent_type_check
  check (parent_type in ('task','announcement','meeting','message','discussion','discussion_reply','leave_request'));

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
      where l.id = p_id and (l.staff_id = auth.uid() or public.is_admin()
        or (public.is_department_head() and exists(select 1 from public.staff_profiles s
              where s.id = l.staff_id and s.department is not null
                and s.department = (select department from public.staff_profiles where id = auth.uid())))))
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

drop trigger if exists cleanup_leave_attachments on public.leave_requests;
create trigger cleanup_leave_attachments after delete on public.leave_requests
  for each row execute function public.cleanup_attachments('leave_request');

-- 2) audit trail (was missing in production)
create or replace function public.write_activity_log()
returns trigger language plpgsql security definer set search_path=public
as $func$
declare v_id uuid; v_details jsonb := '{}'::jsonb;
begin
 v_id := case when TG_OP='DELETE' then OLD.id else NEW.id end;
 if TG_TABLE_NAME='staff_profiles' then v_details=jsonb_build_object('name',coalesce(case when TG_OP='DELETE' then OLD.full_name else NEW.full_name end,''),'status',coalesce(case when TG_OP='DELETE' then OLD.account_status else NEW.account_status end,''),'role',coalesce(case when TG_OP='DELETE' then OLD.system_role else NEW.system_role end,''));
 elsif TG_TABLE_NAME='messages' then v_details=jsonb_build_object('subject',coalesce(case when TG_OP='DELETE' then OLD.subject else NEW.subject end,''));
 elsif TG_TABLE_NAME in ('meetings','announcements','documents','discussions') then v_details=jsonb_build_object('title',coalesce(case when TG_OP='DELETE' then OLD.title else NEW.title end,''));
 elsif TG_TABLE_NAME='tasks' then v_details=jsonb_build_object('title',coalesce(case when TG_OP='DELETE' then OLD.title else NEW.title end,''),'status',coalesce(case when TG_OP='DELETE' then OLD.status else NEW.status end,''));
 elsif TG_TABLE_NAME='leave_requests' then v_details=jsonb_build_object('status',coalesce(case when TG_OP='DELETE' then OLD.status else NEW.status end,''),'start_date',coalesce((case when TG_OP='DELETE' then OLD.start_date else NEW.start_date end)::text,''),'end_date',coalesce((case when TG_OP='DELETE' then OLD.end_date else NEW.end_date end)::text,'')); end if;
 insert into public.activity_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),lower(TG_OP)||'_'||TG_TABLE_NAME,TG_TABLE_NAME,v_id,v_details);
 if TG_OP='DELETE' then return OLD; else return NEW; end if;
end;
$func$;

drop trigger if exists audit_staff_profiles on public.staff_profiles; create trigger audit_staff_profiles after insert or update or delete on public.staff_profiles for each row execute function public.write_activity_log();
drop trigger if exists audit_messages on public.messages; create trigger audit_messages after insert or update or delete on public.messages for each row execute function public.write_activity_log();
drop trigger if exists audit_meetings on public.meetings; create trigger audit_meetings after insert or update or delete on public.meetings for each row execute function public.write_activity_log();
drop trigger if exists audit_announcements on public.announcements; create trigger audit_announcements after insert or update or delete on public.announcements for each row execute function public.write_activity_log();
drop trigger if exists audit_documents on public.documents; create trigger audit_documents after insert or update or delete on public.documents for each row execute function public.write_activity_log();
drop trigger if exists audit_tasks on public.tasks; create trigger audit_tasks after insert or update or delete on public.tasks for each row execute function public.write_activity_log();
drop trigger if exists audit_leave_requests on public.leave_requests; create trigger audit_leave_requests after insert or update or delete on public.leave_requests for each row execute function public.write_activity_log();
drop trigger if exists audit_discussions on public.discussions; create trigger audit_discussions after insert or update or delete on public.discussions for each row execute function public.write_activity_log();

-- 3) missing notification triggers
create or replace function public.notify_leave_submission()
returns trigger language plpgsql security definer set search_path=public
as $func$
begin
 insert into public.notifications(recipient_id,title,body,type)
 select s.id,'New leave request','A staff member has submitted a leave request for review.','leave'
 from public.staff_profiles s
 where s.account_status='approved' and s.id <> new.staff_id
   and (s.system_role in ('ceo_chairperson','coo_treasurer','executive_secretary')
        or (s.system_role='department_head' and s.department is not distinct from (select department from public.staff_profiles where id=new.staff_id)));
 return new;
end;
$func$;
drop trigger if exists notify_leave_submission on public.leave_requests;
create trigger notify_leave_submission after insert on public.leave_requests for each row execute function public.notify_leave_submission();

create or replace function public.notify_announcement_publish()
returns trigger language plpgsql security definer set search_path=public
as $func$
begin
 if new.published=true and (tg_op='INSERT' or old.published is distinct from new.published or old.title is distinct from new.title or old.body is distinct from new.body) then
   insert into public.notifications(recipient_id,title,body,type)
   select s.id,'New announcement: '||new.title,'A new Terraviva announcement has been published for '||case when new.audience='organization' then 'all staff' else coalesce(new.department,'your department') end||'.','announcement'
   from public.staff_profiles s
   where s.account_status='approved' and s.id<>new.author_id and (new.audience='organization' or s.department=new.department);
 end if;
 return new;
end;
$func$;
drop trigger if exists notify_announcement_publish on public.announcements;
create trigger notify_announcement_publish after insert or update on public.announcements for each row execute function public.notify_announcement_publish();

create or replace function public.notify_meeting_created()
returns trigger language plpgsql security definer set search_path=public
as $func$
begin
 insert into public.notifications(recipient_id,title,body,type)
 select s.id,'New meeting: '||new.title,'A Terraviva meeting has been scheduled for '||to_char(new.meeting_date,'YYYY-MM-DD HH24:MI')||'.','meeting'
 from public.staff_profiles s
 where s.account_status='approved' and s.id<>new.organizer_id and (new.audience='organization' or s.department=new.department);
 return new;
end;
$func$;
drop trigger if exists notify_meeting_created on public.meetings;
create trigger notify_meeting_created after insert on public.meetings for each row execute function public.notify_meeting_created();
