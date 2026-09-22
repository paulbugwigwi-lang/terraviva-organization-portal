create extension if not exists pgcrypto;

create table if not exists public.staff_profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 staff_id text not null unique,
 official_email text not null unique,
 full_name text not null,
 title text,
 department text,
 reporting_to_id uuid references public.staff_profiles(id) on delete set null,
 phone text,
 location text,
 photo_url text,
 bio text,
 system_role text not null default 'staff' check (system_role in ('ceo_chairperson','coo_treasurer','executive_secretary','department_head','staff','super_admin')),
 account_status text not null default 'pending' check (account_status in ('pending','approved','rejected','suspended')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);

create table if not exists public.messages (
 id uuid primary key default gen_random_uuid(),
 sender_id uuid not null references public.staff_profiles(id) on delete cascade,
 recipient_id uuid not null references public.staff_profiles(id) on delete cascade,
 subject text not null,
 body text not null,
 is_read boolean not null default false,
 created_at timestamptz not null default now()
);

create table if not exists public.meetings (
 id uuid primary key default gen_random_uuid(),
 title text not null,
 description text,
 meeting_date timestamptz not null,
 location text,
 meeting_link text,
 organizer_id uuid not null references public.staff_profiles(id) on delete cascade,
 created_at timestamptz not null default now()
);

create table if not exists public.announcements (
 id uuid primary key default gen_random_uuid(),
 title text not null,
 body text not null,
 audience text not null default 'organization' check (audience in ('organization','department')),
 department text,
 published boolean not null default true,
 author_id uuid not null references public.staff_profiles(id) on delete cascade,
 created_at timestamptz not null default now()
);

create table if not exists public.documents (
 id uuid primary key default gen_random_uuid(),
 title text not null,
 description text,
 storage_path text not null unique,
 department text,
 uploaded_by uuid not null references public.staff_profiles(id) on delete cascade,
 created_at timestamptz not null default now()
);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists staff_updated_at on public.staff_profiles;
create trigger staff_updated_at
before update on public.staff_profiles
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.staff_profiles(id, staff_id, official_email, full_name)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'staff_id',
      'STAFF-' || upper(substr(replace(new.id::text,'-',''),1,8))
    ),
    lower(new.email),
    coalesce(new.raw_user_meta_data->>'full_name','New Staff')
  )
  on conflict(id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.is_approved()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.staff_profiles
    where id = auth.uid()
    and account_status = 'approved'
  );
$$;

create or replace function public.can_message(target_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $func$
  select exists(
    select 1 from public.staff_profiles me
    where me.id=auth.uid()
      and me.account_status='approved'
      and (
        me.id=target_id
        or public.is_admin()
        or me.reporting_to_id=target_id
        or exists(select 1 from public.staff_profiles child where child.id=target_id and child.reporting_to_id=me.id)
        or (me.department is not null and me.department=(select department from public.staff_profiles where id=target_id))
        or (select system_role from public.staff_profiles where id=target_id) in ('ceo_chairperson','coo_treasurer','executive_secretary')
      )
  );
$func$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.staff_profiles
    where id = auth.uid()
    and account_status = 'approved'
    and system_role in (
      'ceo_chairperson',
      'coo_treasurer',
      'executive_secretary',
      'super_admin'
    )
  );
$$;

alter table public.staff_profiles enable row level security;
alter table public.messages enable row level security;
alter table public.meetings enable row level security;
alter table public.announcements enable row level security;
alter table public.documents enable row level security;

drop policy if exists profile_read on public.staff_profiles;
create policy profile_read on public.staff_profiles
for select to authenticated
using (public.is_approved() or id = auth.uid());

drop policy if exists profile_self_insert on public.staff_profiles;
create policy profile_self_insert on public.staff_profiles
for insert to authenticated
with check (id = auth.uid());

drop policy if exists profile_self_admin_update on public.staff_profiles;
create policy profile_self_admin_update on public.staff_profiles
for update to authenticated
using (id = auth.uid() or public.is_admin())
with check (id = auth.uid() or public.is_admin());

drop policy if exists profile_admin_delete on public.staff_profiles;
create policy profile_admin_delete on public.staff_profiles
for delete to authenticated
using (public.is_admin());

drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages
for select to authenticated
using (sender_id = auth.uid() or recipient_id = auth.uid());

drop policy if exists messages_send on public.messages;
create policy messages_send on public.messages
for insert to authenticated
with check (sender_id = auth.uid() and public.is_approved() and public.can_message(recipient_id));

drop policy if exists messages_update_recipient on public.messages;
create policy messages_update_recipient on public.messages
for update to authenticated
using (recipient_id = auth.uid())
with check (recipient_id = auth.uid());

drop policy if exists messages_delete on public.messages;
create policy messages_delete on public.messages
for delete to authenticated
using (sender_id = auth.uid() or recipient_id = auth.uid());

drop policy if exists meetings_read on public.meetings;
create policy meetings_read on public.meetings
for select to authenticated
using (public.is_approved());

drop policy if exists meetings_manage on public.meetings;
create policy meetings_manage on public.meetings
for all to authenticated
using (organizer_id = auth.uid() or public.is_admin())
with check (organizer_id = auth.uid() or public.is_admin());

drop policy if exists announcements_read on public.announcements;
create policy announcements_read on public.announcements
for select to authenticated
using (
  public.is_approved()
  and published = true
  and (
    audience = 'organization'
    or (
      audience = 'department'
      and department = (
        select sp.department
        from public.staff_profiles sp
        where sp.id = auth.uid()
      )
    )
  )
);

drop policy if exists announcements_manage on public.announcements;
create policy announcements_manage on public.announcements
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists documents_read on public.documents;
create policy documents_read on public.documents
for select to authenticated
using (public.is_approved());

drop policy if exists documents_manage on public.documents;
create policy documents_manage on public.documents
for all to authenticated
using (uploaded_by = auth.uid() or public.is_admin())
with check (uploaded_by = auth.uid() or public.is_admin());

insert into storage.buckets(id, name, public)
values ('staff-files', 'staff-files', false)
on conflict(id) do update set public = false;

drop policy if exists staff_files_read on storage.objects;
create policy staff_files_read on storage.objects
for select to authenticated
using (bucket_id = 'staff-files' and public.is_approved());

drop policy if exists staff_files_upload on storage.objects;
create policy staff_files_upload on storage.objects
for insert to authenticated
with check (bucket_id = 'staff-files' and public.is_approved());

drop policy if exists staff_files_delete on storage.objects;
create policy staff_files_delete on storage.objects
for delete to authenticated
using (
  bucket_id = 'staff-files'
  and (public.is_admin() or owner_id = auth.uid()::text)
);

create index if not exists idx_staff_status
on public.staff_profiles(account_status);

create index if not exists idx_staff_department
on public.staff_profiles(department);

create index if not exists idx_messages_recipient
on public.messages(recipient_id, created_at desc);

create index if not exists idx_meetings_date
on public.meetings(meeting_date);


alter table public.staff_profiles add column if not exists reporting_to_id uuid references public.staff_profiles(id) on delete set null;
alter table public.documents add column if not exists description text;
alter table public.documents add column if not exists department text;
create index if not exists idx_staff_reporting_to on public.staff_profiles(reporting_to_id);


-- V2 coordination modules (included here for fresh installations)
create table if not exists public.tasks (
 id uuid primary key default gen_random_uuid(), title text not null, description text,
 assigned_to uuid references public.staff_profiles(id) on delete set null,
 assigned_by uuid references public.staff_profiles(id) on delete set null,
 status text not null default 'pending' check(status in ('pending','in_progress','completed','cancelled')),
 priority text not null default 'normal' check(priority in ('low','normal','high','urgent')),
 due_date timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.notifications (
 id uuid primary key default gen_random_uuid(), recipient_id uuid not null references public.staff_profiles(id) on delete cascade,
 title text not null, body text not null, type text not null default 'info', is_read boolean not null default false,
 created_at timestamptz not null default now()
);
create table if not exists public.leave_requests (
 id uuid primary key default gen_random_uuid(), staff_id uuid not null references public.staff_profiles(id) on delete cascade,
 start_date date not null, end_date date not null, reason text,
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 reviewed_by uuid references public.staff_profiles(id) on delete set null, created_at timestamptz not null default now(),
 constraint leave_dates_valid check (end_date >= start_date)
);
alter table public.tasks enable row level security;
alter table public.notifications enable row level security;
alter table public.leave_requests enable row level security;
drop policy if exists tasks_select on public.tasks;
create policy tasks_select on public.tasks for select to authenticated using (public.is_approved() and (assigned_to=auth.uid() or assigned_by=auth.uid() or public.is_admin()));
drop policy if exists tasks_insert on public.tasks;
create policy tasks_insert on public.tasks for insert to authenticated with check (public.is_approved() and assigned_by=auth.uid() and public.is_admin());
drop policy if exists tasks_update on public.tasks;
create policy tasks_update on public.tasks for update to authenticated using (assigned_to=auth.uid() or assigned_by=auth.uid() or public.is_admin()) with check (assigned_to=auth.uid() or assigned_by=auth.uid() or public.is_admin());
drop policy if exists tasks_delete on public.tasks;
create policy tasks_delete on public.tasks for delete to authenticated using (assigned_by=auth.uid() or public.is_admin());
drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications for select to authenticated using (recipient_id=auth.uid());
drop policy if exists notifications_update on public.notifications;
create policy notifications_update on public.notifications for update to authenticated using (recipient_id=auth.uid()) with check (recipient_id=auth.uid());
drop policy if exists leave_select on public.leave_requests;
create policy leave_select on public.leave_requests for select to authenticated using (staff_id=auth.uid() or public.is_admin());
drop policy if exists leave_insert on public.leave_requests;
create policy leave_insert on public.leave_requests for insert to authenticated with check (staff_id=auth.uid() and public.is_approved());
drop policy if exists leave_update on public.leave_requests;
create policy leave_update on public.leave_requests for update to authenticated using (staff_id=auth.uid() or public.is_admin()) with check (staff_id=auth.uid() or public.is_admin());
drop policy if exists leave_delete on public.leave_requests;
create policy leave_delete on public.leave_requests for delete to authenticated using (staff_id=auth.uid() or public.is_admin());

create or replace function public.notify_message() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into public.notifications(recipient_id,title,body,type) values(new.recipient_id,'New private message',coalesce(new.subject,'You received a new message'),'message'); return new; end; $$;
drop trigger if exists trg_notify_message on public.messages;
create trigger trg_notify_message after insert on public.messages for each row execute function public.notify_message();

create or replace function public.notify_task() returns trigger language plpgsql security definer set search_path=public as $$
begin if new.assigned_to is not null then insert into public.notifications(recipient_id,title,body,type) values(new.assigned_to,'New task assigned',new.title,'task'); end if; return new; end; $$;
drop trigger if exists trg_notify_task on public.tasks;
create trigger trg_notify_task after insert on public.tasks for each row execute function public.notify_task();

create or replace function public.notify_announcement() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into public.notifications(recipient_id,title,body,type)
select id,new.title,'New Terraviva announcement','announcement' from public.staff_profiles
where account_status='approved' and (new.audience='organization' or (new.audience='department' and department=new.department));
return new; end; $$;
drop trigger if exists trg_notify_announcement on public.announcements;
create trigger trg_notify_announcement after insert on public.announcements for each row execute function public.notify_announcement();

drop trigger if exists tasks_updated_at on public.tasks;
create trigger tasks_updated_at before update on public.tasks for each row execute function public.set_updated_at();
create index if not exists idx_tasks_assigned_to on public.tasks(assigned_to,created_at desc);
create index if not exists idx_notifications_recipient on public.notifications(recipient_id,is_read,created_at desc);
create index if not exists idx_leave_staff on public.leave_requests(staff_id,created_at desc);


-- V2.1 audit trail for administrative accountability
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
returns trigger
language plpgsql
security definer
set search_path=public
as $func$
declare
  v_id uuid;
  v_details jsonb := '{}'::jsonb;
begin
  v_id := coalesce((case when TG_OP='DELETE' then OLD.id else NEW.id end), gen_random_uuid());
  if TG_TABLE_NAME='staff_profiles' then
    v_details := jsonb_build_object('name',coalesce((case when TG_OP='DELETE' then OLD.full_name else NEW.full_name end),''),'status',coalesce((case when TG_OP='DELETE' then OLD.account_status else NEW.account_status end),''),'role',coalesce((case when TG_OP='DELETE' then OLD.system_role else NEW.system_role end),''));
  elsif TG_TABLE_NAME='messages' then
    v_details := jsonb_build_object('subject',coalesce((case when TG_OP='DELETE' then OLD.subject else NEW.subject end),''));
  elsif TG_TABLE_NAME='meetings' then
    v_details := jsonb_build_object('title',coalesce((case when TG_OP='DELETE' then OLD.title else NEW.title end),''));
  elsif TG_TABLE_NAME='announcements' then
    v_details := jsonb_build_object('title',coalesce((case when TG_OP='DELETE' then OLD.title else NEW.title end),''));
  elsif TG_TABLE_NAME='documents' then
    v_details := jsonb_build_object('title',coalesce((case when TG_OP='DELETE' then OLD.title else NEW.title end),''));
  elsif TG_TABLE_NAME='tasks' then
    v_details := jsonb_build_object('title',coalesce((case when TG_OP='DELETE' then OLD.title else NEW.title end),''),'status',coalesce((case when TG_OP='DELETE' then OLD.status else NEW.status end),''));
  elsif TG_TABLE_NAME='leave_requests' then
    v_details := jsonb_build_object('status',coalesce((case when TG_OP='DELETE' then OLD.status else NEW.status end),''),'start_date',coalesce((case when TG_OP='DELETE' then OLD.start_date else NEW.start_date end)::text,''),'end_date',coalesce((case when TG_OP='DELETE' then OLD.end_date else NEW.end_date end)::text,''));
  end if;
  insert into public.activity_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),lower(TG_OP)||'_'||TG_TABLE_NAME,TG_TABLE_NAME,v_id,v_details);
  if TG_OP='DELETE' then return OLD; else return NEW; end if;
end;
$func$;

drop trigger if exists audit_staff_profiles on public.staff_profiles;
create trigger audit_staff_profiles after insert or update or delete on public.staff_profiles for each row execute function public.write_activity_log();
drop trigger if exists audit_messages on public.messages;
create trigger audit_messages after insert or update or delete on public.messages for each row execute function public.write_activity_log();
drop trigger if exists audit_meetings on public.meetings;
create trigger audit_meetings after insert or update or delete on public.meetings for each row execute function public.write_activity_log();
drop trigger if exists audit_announcements on public.announcements;
create trigger audit_announcements after insert or update or delete on public.announcements for each row execute function public.write_activity_log();
drop trigger if exists audit_documents on public.documents;
create trigger audit_documents after insert or update or delete on public.documents for each row execute function public.write_activity_log();
drop trigger if exists audit_tasks on public.tasks;
create trigger audit_tasks after insert or update or delete on public.tasks for each row execute function public.write_activity_log();
drop trigger if exists audit_leave_requests on public.leave_requests;
create trigger audit_leave_requests after insert or update or delete on public.leave_requests for each row execute function public.write_activity_log();
