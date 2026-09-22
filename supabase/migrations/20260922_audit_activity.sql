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
