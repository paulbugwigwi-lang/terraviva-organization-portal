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
