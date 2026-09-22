-- Terraviva Portal V2.1 audit trail migration
create table if not exists public.activity_logs (
 id uuid primary key default gen_random_uuid(),
 actor_id uuid references public.staff_profiles(id) on delete set null,
 action text not null,
 entity_type text not null,
 entity_id uuid,
 details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
alter table public.activity_logs enable row level security;
drop policy if exists activity_logs_admin_read on public.activity_logs;
create policy activity_logs_admin_read on public.activity_logs for select to authenticated using (public.is_admin());
create index if not exists idx_activity_logs_created on public.activity_logs(created_at desc);
create index if not exists idx_activity_logs_actor on public.activity_logs(actor_id,created_at desc);

create or replace function public.write_activity_log()
returns trigger language plpgsql security definer set search_path=public
as $func$
declare v_id uuid; v_details jsonb := '{}'::jsonb;
begin
 v_id := case when TG_OP='DELETE' then OLD.id else NEW.id end;
 if TG_TABLE_NAME='staff_profiles' then v_details=jsonb_build_object('name',coalesce(case when TG_OP='DELETE' then OLD.full_name else NEW.full_name end,''),'status',coalesce(case when TG_OP='DELETE' then OLD.account_status else NEW.account_status end,''),'role',coalesce(case when TG_OP='DELETE' then OLD.system_role else NEW.system_role end,''));
 elsif TG_TABLE_NAME='messages' then v_details=jsonb_build_object('subject',coalesce(case when TG_OP='DELETE' then OLD.subject else NEW.subject end,''));
 elsif TG_TABLE_NAME='meetings' then v_details=jsonb_build_object('title',coalesce(case when TG_OP='DELETE' then OLD.title else NEW.title end,''));
 elsif TG_TABLE_NAME='announcements' then v_details=jsonb_build_object('title',coalesce(case when TG_OP='DELETE' then OLD.title else NEW.title end,''));
 elsif TG_TABLE_NAME='documents' then v_details=jsonb_build_object('title',coalesce(case when TG_OP='DELETE' then OLD.title else NEW.title end,''));
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


-- V2.2 role and department permissions
create or replace function public.is_department_head()
returns boolean language sql stable security definer set search_path=public
as $func$ select exists(select 1 from public.staff_profiles where id=auth.uid() and account_status='approved' and system_role='department_head'); $func$;
create or replace function public.can_manage_department(p_department text)
returns boolean language sql stable security definer set search_path=public
as $func$ select public.is_admin() or exists(select 1 from public.staff_profiles where id=auth.uid() and account_status='approved' and system_role='department_head' and department is not null and department=p_department); $func$;

drop policy if exists tasks_insert on public.tasks;
create policy tasks_insert on public.tasks for insert to authenticated with check (public.is_approved() and assigned_by=auth.uid() and (public.is_admin() or (public.is_department_head() and exists(select 1 from public.staff_profiles target where target.id=assigned_to and target.department=(select department from public.staff_profiles where id=auth.uid()) and target.account_status='approved'))));

drop policy if exists announcements_manage on public.announcements;
create policy announcements_manage on public.announcements for all to authenticated using (public.is_admin() or (public.is_department_head() and audience='department' and department=(select department from public.staff_profiles where id=auth.uid()))) with check (public.is_admin() or (public.is_department_head() and audience='department' and department=(select department from public.staff_profiles where id=auth.uid())));

drop policy if exists documents_read on public.documents;
create policy documents_read on public.documents for select to authenticated using (public.is_approved() and (department is null or department=(select department from public.staff_profiles where id=auth.uid()) or public.is_admin()));
drop policy if exists documents_manage on public.documents;
create policy documents_manage on public.documents for all to authenticated using (uploaded_by=auth.uid() or public.is_admin() or (public.is_department_head() and department=(select department from public.staff_profiles where id=auth.uid()))) with check (public.is_admin() or (public.is_department_head() and department=(select department from public.staff_profiles where id=auth.uid())) or (uploaded_by=auth.uid() and (department is null or department=(select department from public.staff_profiles where id=auth.uid()))));

insert into storage.buckets(id,name,public) values('profile-photos','profile-photos',true) on conflict(id) do update set public=true;
drop policy if exists profile_photos_read on storage.objects; create policy profile_photos_read on storage.objects for select to authenticated using (bucket_id='profile-photos' and public.is_approved());
drop policy if exists profile_photos_upload on storage.objects; create policy profile_photos_upload on storage.objects for insert to authenticated with check (bucket_id='profile-photos' and public.is_approved() and (name like auth.uid()::text || '/%'));
drop policy if exists profile_photos_update on storage.objects; create policy profile_photos_update on storage.objects for update to authenticated using (bucket_id='profile-photos' and owner_id=auth.uid()::text) with check (bucket_id='profile-photos' and owner_id=auth.uid()::text);
drop policy if exists profile_photos_delete on storage.objects; create policy profile_photos_delete on storage.objects for delete to authenticated using (bucket_id='profile-photos' and (owner_id=auth.uid()::text or public.is_admin()));

drop policy if exists staff_files_read on storage.objects; create policy staff_files_read on storage.objects for select to authenticated using (bucket_id='staff-files' and public.is_approved() and exists(select 1 from public.documents d where d.storage_path=name and (d.department is null or d.department=(select department from public.staff_profiles where id=auth.uid()) or public.is_admin())));


-- V2.3 hardened role permissions and task field protection
create or replace function public.can_manage_staff(target_id uuid)
returns boolean language sql stable security definer set search_path=public
as $func$
 select public.is_admin()
   or exists(
     select 1 from public.staff_profiles me
     join public.staff_profiles target on target.id=target_id
     where me.id=auth.uid()
       and me.account_status='approved'
       and me.system_role='department_head'
       and me.department is not null
       and me.department=target.department
       and target.account_status='approved'
   );
$func$;

drop policy if exists profile_self_admin_update on public.staff_profiles;
create policy profile_self_admin_update on public.staff_profiles
for update to authenticated
using (id=auth.uid() or public.is_admin() or public.can_manage_staff(id))
with check (id=auth.uid() or public.is_admin() or public.can_manage_staff(id));

create or replace function public.protect_task_assignee_changes()
returns trigger language plpgsql security definer set search_path=public
as $func$
begin
 if auth.uid() = old.assigned_to and not public.is_admin() and auth.uid() <> old.assigned_by then
   if new.title is distinct from old.title
      or new.description is distinct from old.description
      or new.assigned_to is distinct from old.assigned_to
      or new.assigned_by is distinct from old.assigned_by
      or new.priority is distinct from old.priority
      or new.due_date is distinct from old.due_date then
      raise exception 'Assigned staff may only update task status';
   end if;
 end if;
 return new;
end;
$func$;
drop trigger if exists protect_task_assignee_changes on public.tasks;
create trigger protect_task_assignee_changes before update on public.tasks for each row execute function public.protect_task_assignee_changes();

-- Department heads may manage staff within their own department; role/status changes remain administrator-only in the UI.


-- V2.4 staff management hardening: protect sensitive role/status fields and reporting cycles
create or replace function public.protect_staff_management_fields()
returns trigger language plpgsql security definer set search_path=public
as $func$
begin
 if not public.is_admin() then
   if new.system_role is distinct from old.system_role
      or new.account_status is distinct from old.account_status
      or new.department is distinct from old.department then
     raise exception 'Only Terraviva administrators may change staff role, account status or department';
   end if;
   if auth.uid() = old.id and new.reporting_to_id is distinct from old.reporting_to_id then
     raise exception 'Staff cannot change their own reporting line';
   end if;
   if new.staff_id is distinct from old.staff_id or new.official_email is distinct from old.official_email then
     raise exception 'Staff ID and official email are administrator-managed fields';
   end if;
 end if;
 return new;
end;
$func$;
drop trigger if exists protect_staff_management_fields on public.staff_profiles;
create trigger protect_staff_management_fields before update on public.staff_profiles for each row execute function public.protect_staff_management_fields();

create or replace function public.prevent_reporting_cycle()
returns trigger language plpgsql security definer set search_path=public
as $func$
declare v_id uuid;
begin
 if new.reporting_to_id is null then return new; end if;
 if new.reporting_to_id = new.id then raise exception 'A staff member cannot report to themselves'; end if;
 v_id := new.reporting_to_id;
 while v_id is not null loop
   if v_id = new.id then raise exception 'Reporting line would create an organization hierarchy cycle'; end if;
   select reporting_to_id into v_id from public.staff_profiles where id=v_id;
 end loop;
 return new;
end;
$func$;
drop trigger if exists prevent_reporting_cycle on public.staff_profiles;
create trigger prevent_reporting_cycle before insert or update of reporting_to_id on public.staff_profiles for each row execute function public.prevent_reporting_cycle();


-- V2.5 department leave coordination
 drop policy if exists leave_admin_manage on public.leave_requests;
 create policy leave_admin_manage on public.leave_requests for all to authenticated
 using (
   public.is_admin()
   or staff_id=auth.uid()
   or (public.is_department_head() and exists(select 1 from public.staff_profiles target where target.id=staff_id and target.account_status='approved' and target.department=(select department from public.staff_profiles where id=auth.uid())))
 )
 with check (
   public.is_admin()
   or staff_id=auth.uid()
   or (public.is_department_head() and exists(select 1 from public.staff_profiles target where target.id=staff_id and target.account_status='approved' and target.department=(select department from public.staff_profiles where id=auth.uid())))
 );


-- V2.6 department heads may manage only department-targeted announcements
 drop policy if exists announcements_manage on public.announcements;
 create policy announcements_manage on public.announcements for all to authenticated
 using (
   public.is_admin()
   or (public.is_department_head() and audience='department' and department=(select department from public.staff_profiles where id=auth.uid()))
 )
 with check (
   public.is_admin()
   or (public.is_department_head() and audience='department' and department=(select department from public.staff_profiles where id=auth.uid()))
 );


-- V2.7 coordination automation: notify recipients when key workflow records are created
create or replace function public.notify_task_assignment()
returns trigger language plpgsql security definer set search_path=public
as $func$
begin
 insert into public.notifications(recipient_id,title,body,type)
 values(new.assigned_to,'New task assigned: '||new.title,'You have been assigned a '||new.priority||' priority task. Please review the task details and update its status.','task');
 return new;
end;
$func$;
drop trigger if exists notify_task_assignment on public.tasks;
create trigger notify_task_assignment after insert on public.tasks for each row execute function public.notify_task_assignment();

create or replace function public.notify_new_message()
returns trigger language plpgsql security definer set search_path=public
as $func$
begin
 insert into public.notifications(recipient_id,title,body,type)
 values(new.recipient_id,'New private message','You received a new private message from a Terraviva staff member.','message');
 return new;
end;
$func$;
drop trigger if exists notify_new_message on public.messages;
create trigger notify_new_message after insert on public.messages for each row execute function public.notify_new_message();

create or replace function public.notify_leave_submission()
returns trigger language plpgsql security definer set search_path=public
as $func$
declare v_id uuid;
begin
 for v_id in select id from public.staff_profiles where account_status='approved' and (system_role in ('ceo_chairperson','coo_treasurer','executive_secretary') or (system_role='department_head' and department=(select department from public.staff_profiles where id=new.staff_id))) loop
   if v_id <> new.staff_id then
     insert into public.notifications(recipient_id,title,body,type) values(v_id,'New leave request','A staff member has submitted a leave request for review.','leave');
   end if;
 end loop;
 return new;
end;
$func$;
drop trigger if exists notify_leave_submission on public.leave_requests;
create trigger notify_leave_submission after insert on public.leave_requests for each row execute function public.notify_leave_submission();


-- V2.8 notify a task creator when an assigned staff member completes a task
create or replace function public.notify_task_completion()
returns trigger language plpgsql security definer set search_path=public
as $func$
declare v_title text;
begin
 if old.status is distinct from new.status and new.status='completed' and new.assigned_by is not null and new.assigned_by <> new.assigned_to then
   select title into v_title from public.tasks where id=new.id;
   insert into public.notifications(recipient_id,title,body,type)
   values(new.assigned_by,'Task completed: '||coalesce(v_title,'Task'),'The assigned staff member has marked this task as completed.','task');
 end if;
 return new;
end;
$func$;
drop trigger if exists notify_task_completion on public.tasks;
create trigger notify_task_completion after update of status on public.tasks for each row execute function public.notify_task_completion();

-- V2.8 notify leave requester after a review decision
create or replace function public.notify_leave_decision()
returns trigger language plpgsql security definer set search_path=public
as $func$
begin
 if old.status is distinct from new.status and new.status in ('approved','rejected') then
   insert into public.notifications(recipient_id,title,body,type)
   values(new.staff_id,'Leave request '||initcap(new.status),'Your leave request for '||new.start_date||' to '||new.end_date||' has been '||new.status||'.','leave');
 end if;
 return new;
end;
$func$;
drop trigger if exists notify_leave_decision on public.leave_requests;
create trigger notify_leave_decision after update of status on public.leave_requests for each row execute function public.notify_leave_decision();


-- V2.9 notify the intended audience when an announcement is published
create or replace function public.notify_announcement_publish()
returns trigger language plpgsql security definer set search_path=public
as $func$
declare v_id uuid;
begin
 if new.published=true and (tg_op='INSERT' or old.published is distinct from new.published or old.title is distinct from new.title or old.body is distinct from new.body) then
   for v_id in select id from public.staff_profiles where account_status='approved' and id<>new.author_id and (new.audience='organization' or department=new.department) loop
     insert into public.notifications(recipient_id,title,body,type)
     values(v_id,'New announcement: '||new.title,'A new Terraviva announcement has been published for '||case when new.audience='organization' then 'all staff' else coalesce(new.department,'your department') end||'.','announcement');
   end loop;
 end if;
 return new;
end;
$func$;
drop trigger if exists notify_announcement_publish on public.announcements;
create trigger notify_announcement_publish after insert or update on public.announcements for each row execute function public.notify_announcement_publish();

-- V2.9 notify staff when a meeting is created
create or replace function public.notify_meeting_created()
returns trigger language plpgsql security definer set search_path=public
as $func$
declare v_id uuid;
begin
 for v_id in select id from public.staff_profiles where account_status='approved' and id<>new.organizer_id loop
   insert into public.notifications(recipient_id,title,body,type)
   values(v_id,'New meeting: '||new.title,'A Terraviva meeting has been scheduled for '||to_char(new.meeting_date,'YYYY-MM-DD HH24:MI')||'.','meeting');
 end loop;
 return new;
end;
$func$;
drop trigger if exists notify_meeting_created on public.meetings;
create trigger notify_meeting_created after insert on public.meetings for each row execute function public.notify_meeting_created();


-- V2.10 meeting coordination: allow organizers to target a department or all staff
alter table public.meetings add column if not exists audience text not null default 'organization' check (audience in ('organization','department'));
alter table public.meetings add column if not exists department text;
create or replace function public.notify_meeting_created()
returns trigger language plpgsql security definer set search_path=public
as $func$
declare v_id uuid;
begin
 for v_id in select id from public.staff_profiles where account_status='approved' and id<>new.organizer_id and (new.audience='organization' or department=new.department) loop
   insert into public.notifications(recipient_id,title,body,type) values(v_id,'New meeting: '||new.title,'A Terraviva meeting has been scheduled for '||to_char(new.meeting_date,'YYYY-MM-DD HH24:MI')||'.','meeting');
 end loop; return new;
end;
$func$;


drop trigger if exists notify_meeting_created on public.meetings;
create trigger notify_meeting_created after insert on public.meetings for each row execute function public.notify_meeting_created();

-- V2.12 explicit conversation threads for private reporting
alter table public.messages add column if not exists thread_id uuid;
create index if not exists messages_thread_idx on public.messages(thread_id,created_at);
create or replace function public.can_message(target_id uuid)
returns boolean language sql stable security definer set search_path=public
as $func$
 select exists(select 1 from public.staff_profiles me where me.id=auth.uid() and me.account_status='approved' and (me.id=target_id or public.is_admin() or me.reporting_to_id=target_id or exists(select 1 from public.staff_profiles child where child.id=target_id and child.reporting_to_id=me.id) or (me.department is not null and me.department=(select department from public.staff_profiles where id=target_id)) or (select system_role from public.staff_profiles where id=target_id) in ('ceo_chairperson','coo_treasurer','executive_secretary')));
$func$;


-- V2.15 final permission hardening
drop policy if exists meetings_manage on public.meetings;
create policy meetings_manage on public.meetings
for all to authenticated
using (
  public.is_admin()
  or (
    organizer_id=auth.uid()
    and (
      audience='organization' and public.is_admin()
      or audience='department' and department=(select department from public.staff_profiles where id=auth.uid())
    )
  )
)
with check (
  public.is_admin()
  or (
    organizer_id=auth.uid()
    and (
      audience='organization' and public.is_admin()
      or audience='department' and department=(select department from public.staff_profiles where id=auth.uid())
    )
  )
);

drop policy if exists leave_admin_manage on public.leave_requests;
create policy leave_admin_manage on public.leave_requests
for all to authenticated
using (
  public.is_admin()
  or staff_id=auth.uid()
  or (
    public.is_department_head()
    and staff_id<>auth.uid()
    and exists(
      select 1 from public.staff_profiles target
      where target.id=staff_id
        and target.account_status='approved'
        and target.department=(select department from public.staff_profiles where id=auth.uid())
    )
  )
)
with check (
  public.is_admin()
  or staff_id=auth.uid()
  or (
    public.is_department_head()
    and staff_id<>auth.uid()
    and exists(
      select 1 from public.staff_profiles target
      where target.id=staff_id
        and target.account_status='approved'
        and target.department=(select department from public.staff_profiles where id=auth.uid())
    )
  )
);

create index if not exists messages_thread_created_idx on public.messages(thread_id, created_at desc);
create index if not exists notifications_recipient_read_idx on public.notifications(recipient_id, is_read, created_at desc);
create index if not exists tasks_assignee_status_idx on public.tasks(assigned_to, status, due_date);
create index if not exists leave_department_status_idx on public.leave_requests(staff_id, status, start_date);
