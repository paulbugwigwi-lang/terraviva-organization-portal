-- 2026-10-28 Security fix (already applied to production).
-- The live database was missing the staff-field protection triggers, so any signed-in
-- user could promote themselves via profile_self_admin_update. These restore them.
-- auth.uid() is null for the SQL editor / service role, so the first administrator can still be approved manually.
create or replace function public.protect_staff_management_fields()
returns trigger language plpgsql security definer set search_path=public
as $func$
begin
 if auth.uid() is not null and not public.is_admin() then
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
create trigger protect_staff_management_fields before update on public.staff_profiles
  for each row execute function public.protect_staff_management_fields();

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
create trigger prevent_reporting_cycle before insert or update of reporting_to_id on public.staff_profiles
  for each row execute function public.prevent_reporting_cycle();

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
create trigger protect_task_assignee_changes before update on public.tasks
  for each row execute function public.protect_task_assignee_changes();
