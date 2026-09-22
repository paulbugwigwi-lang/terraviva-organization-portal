-- Terraviva Portal V2: leadership hierarchy + private coordination migration
alter table public.staff_profiles add column if not exists reporting_to_id uuid references public.staff_profiles(id) on delete set null;
create index if not exists idx_staff_reporting_to on public.staff_profiles(reporting_to_id);

create or replace function public.can_message(target_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
select exists(select 1 from public.staff_profiles me where me.id=auth.uid() and me.account_status='approved' and (
 me.id=target_id or public.is_admin() or me.reporting_to_id=target_id or
 exists(select 1 from public.staff_profiles child where child.id=target_id and child.reporting_to_id=me.id) or
 (me.department is not null and me.department=(select department from public.staff_profiles where id=target_id)) or
 (select system_role from public.staff_profiles where id=target_id) in ('ceo_chairperson','coo_treasurer','executive_secretary')
));
$$;

drop policy if exists messages_send on public.messages;
create policy messages_send on public.messages for insert to authenticated
with check (sender_id=auth.uid() and public.is_approved() and public.can_message(recipient_id));


-- Organization coordination modules
create table if not exists public.tasks (
 id uuid primary key default gen_random_uuid(), title text not null, description text, assigned_to uuid references public.staff_profiles(id) on delete set null,
 assigned_by uuid references public.staff_profiles(id) on delete set null, status text not null default 'pending' check(status in ('pending','in_progress','completed','cancelled')),
 priority text not null default 'normal' check(priority in ('low','normal','high','urgent')), due_date timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.notifications (
 id uuid primary key default gen_random_uuid(), recipient_id uuid not null references public.staff_profiles(id) on delete cascade, title text not null, body text not null,
 type text not null default 'info', is_read boolean not null default false, created_at timestamptz not null default now()
);
create table if not exists public.leave_requests (
 id uuid primary key default gen_random_uuid(), staff_id uuid not null references public.staff_profiles(id) on delete cascade, start_date date not null, end_date date not null,
 reason text, status text not null default 'pending' check(status in ('pending','approved','rejected')), reviewed_by uuid references public.staff_profiles(id) on delete set null,
 created_at timestamptz not null default now()
);
alter table public.tasks enable row level security; alter table public.notifications enable row level security; alter table public.leave_requests enable row level security;
drop policy if exists tasks_select on public.tasks; create policy tasks_select on public.tasks for select to authenticated using (public.is_approved() and (assigned_to=auth.uid() or assigned_by=auth.uid() or public.is_admin()));
drop policy if exists tasks_insert on public.tasks; create policy tasks_insert on public.tasks for insert to authenticated with check (public.is_approved() and assigned_by=auth.uid());
drop policy if exists tasks_update on public.tasks; create policy tasks_update on public.tasks for update to authenticated using (assigned_to=auth.uid() or assigned_by=auth.uid() or public.is_admin());
drop policy if exists notifications_select on public.notifications; create policy notifications_select on public.notifications for select to authenticated using (recipient_id=auth.uid() or public.is_admin());
drop policy if exists notifications_update on public.notifications; create policy notifications_update on public.notifications for update to authenticated using (recipient_id=auth.uid());
drop policy if exists leave_select on public.leave_requests; create policy leave_select on public.leave_requests for select to authenticated using (staff_id=auth.uid() or reviewed_by=auth.uid() or public.is_admin());
drop policy if exists leave_insert on public.leave_requests; create policy leave_insert on public.leave_requests for insert to authenticated with check (staff_id=auth.uid() and public.is_approved());
drop policy if exists leave_update on public.leave_requests; create policy leave_update on public.leave_requests for update to authenticated using (staff_id=auth.uid() or public.is_admin());


-- Automatic in-app notifications for coordination events
create or replace function public.notify_message() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into public.notifications(recipient_id,title,body,type) values(new.recipient_id,'New private message',coalesce(new.subject,'You received a new message'),'message'); return new; end; $$;
drop trigger if exists trg_notify_message on public.messages; create trigger trg_notify_message after insert on public.messages for each row execute function public.notify_message();
create or replace function public.notify_task() returns trigger language plpgsql security definer set search_path=public as $$
begin if new.assigned_to is not null then insert into public.notifications(recipient_id,title,body,type) values(new.assigned_to,'New task assigned',new.title,'task'); end if; return new; end; $$;
drop trigger if exists trg_notify_task on public.tasks; create trigger trg_notify_task after insert on public.tasks for each row execute function public.notify_task();
create or replace function public.notify_announcement() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into public.notifications(recipient_id,title,body,type) select id,new.title,'New Terraviva announcement','announcement' from public.staff_profiles where account_status='approved' and (new.audience='organization' or (new.audience='department' and department=new.department)); return new; end; $$;
drop trigger if exists trg_notify_announcement on public.announcements; create trigger trg_notify_announcement after insert on public.announcements for each row execute function public.notify_announcement();
