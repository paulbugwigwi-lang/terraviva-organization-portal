-- Terraviva V1.7: attachments (task / announcement / meeting / message), delete options,
-- per-user message deletion. Safe to re-run.

-- columns used by the functions below must exist first
alter table public.messages add column if not exists hidden_by_sender boolean not null default false;
alter table public.messages add column if not exists hidden_by_recipient boolean not null default false;

-- =========================================================
-- 1. ATTACHMENTS
-- =========================================================
create table if not exists public.attachments (
  id uuid primary key default gen_random_uuid(),
  parent_type text not null check (parent_type in ('task','announcement','meeting','message')),
  parent_id uuid not null,
  file_name text not null,
  storage_path text not null unique,
  mime_type text,
  size_bytes bigint,
  uploaded_by uuid not null references public.staff_profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists attachments_parent_idx on public.attachments(parent_type, parent_id);
alter table public.attachments enable row level security;

-- Who may SEE the parent record (and therefore its attachments)
create or replace function public.can_access_parent(p_type text, p_id uuid)
returns boolean language sql stable security definer set search_path = public as $func$
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
    else false end;
$func$;

-- Who may ADD files to the parent record
create or replace function public.can_attach_parent(p_type text, p_id uuid)
returns boolean language sql stable security definer set search_path = public as $func$
  select public.is_approved() and case p_type
    when 'task' then public.can_access_parent('task', p_id)
    when 'announcement' then exists(select 1 from public.announcements a
      where a.id = p_id and (a.author_id = auth.uid() or public.is_admin()))
    when 'meeting' then exists(select 1 from public.meetings m
      where m.id = p_id and (m.organizer_id = auth.uid() or public.is_admin()))
    when 'message' then exists(select 1 from public.messages x where x.id = p_id and x.sender_id = auth.uid())
    else false end;
$func$;

-- Who may DELETE a stored file / its attachment row (looked up by storage path)
create or replace function public.can_delete_attachment_object(p_name text)
returns boolean language sql stable security definer set search_path = public as $func$
  select exists(
    select 1 from public.attachments a
    where a.storage_path = p_name and (
      a.uploaded_by = auth.uid()
      or (a.parent_type = 'task' and exists(select 1 from public.tasks t where t.id = a.parent_id and t.assigned_by = auth.uid()))
      or (a.parent_type = 'announcement' and exists(select 1 from public.announcements n where n.id = a.parent_id and n.author_id = auth.uid()))
      or (a.parent_type = 'meeting' and exists(select 1 from public.meetings m where m.id = a.parent_id and m.organizer_id = auth.uid()))
      or (a.parent_type <> 'message' and public.is_admin())
      or (a.parent_type = 'message' and exists(select 1 from public.messages m
            where m.id = a.parent_id and m.hidden_by_sender and m.hidden_by_recipient
              and (m.sender_id = auth.uid() or m.recipient_id = auth.uid())))
    ));
$func$;

create or replace function public.can_read_attachment_object(p_name text)
returns boolean language sql stable security definer set search_path = public as $func$
  select exists(select 1 from public.attachments a
    where a.storage_path = p_name and public.can_access_parent(a.parent_type, a.parent_id));
$func$;

drop policy if exists attachments_select on public.attachments;
create policy attachments_select on public.attachments for select to authenticated
  using (public.can_access_parent(parent_type, parent_id));

drop policy if exists attachments_insert on public.attachments;
create policy attachments_insert on public.attachments for insert to authenticated
  with check (uploaded_by = auth.uid() and public.can_attach_parent(parent_type, parent_id));

drop policy if exists attachments_delete on public.attachments;
create policy attachments_delete on public.attachments for delete to authenticated
  using (public.can_delete_attachment_object(storage_path));

-- Private bucket: every file format is allowed (no mime restriction).
-- Size is limited by the project-wide Storage limit (Supabase Free = 50 MB per file).
insert into storage.buckets (id, name, public)
values ('portal-attachments', 'portal-attachments', false)
on conflict (id) do update set public = false;

drop policy if exists portal_att_read on storage.objects;
create policy portal_att_read on storage.objects for select to authenticated
  using (bucket_id = 'portal-attachments'
         and (owner_id = auth.uid()::text or public.can_read_attachment_object(name)));

drop policy if exists portal_att_upload on storage.objects;
create policy portal_att_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'portal-attachments' and public.is_approved()
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists portal_att_delete on storage.objects;
create policy portal_att_delete on storage.objects for delete to authenticated
  using (bucket_id = 'portal-attachments'
         and (owner_id = auth.uid()::text or public.can_delete_attachment_object(name)));

-- Remove attachment rows automatically when the parent record is deleted
-- (the client removes the stored files first).
create or replace function public.cleanup_attachments()
returns trigger language plpgsql security definer set search_path = public as $func$
begin
  delete from public.attachments where parent_type = TG_ARGV[0] and parent_id = OLD.id;
  return OLD;
end;
$func$;

drop trigger if exists cleanup_task_attachments on public.tasks;
create trigger cleanup_task_attachments after delete on public.tasks
  for each row execute function public.cleanup_attachments('task');
drop trigger if exists cleanup_announcement_attachments on public.announcements;
create trigger cleanup_announcement_attachments after delete on public.announcements
  for each row execute function public.cleanup_attachments('announcement');
drop trigger if exists cleanup_meeting_attachments on public.meetings;
create trigger cleanup_meeting_attachments after delete on public.meetings
  for each row execute function public.cleanup_attachments('meeting');
drop trigger if exists cleanup_message_attachments on public.messages;
create trigger cleanup_message_attachments after delete on public.messages
  for each row execute function public.cleanup_attachments('message');

-- =========================================================
-- 2. NOTIFICATIONS: each user can delete their own
-- =========================================================
drop policy if exists notifications_delete on public.notifications;
create policy notifications_delete on public.notifications for delete to authenticated
  using (recipient_id = auth.uid());

-- =========================================================
-- 3. MESSAGES: "delete for me" (private messages stay private)
--    The other person keeps their copy until they delete it too.
--    When both sides have deleted, the row is purged (client removes files first).
-- =========================================================

drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages for select to authenticated
  using ((sender_id = auth.uid() and not hidden_by_sender)
      or (recipient_id = auth.uid() and not hidden_by_recipient));

-- direct hard deletes are replaced by the two functions below
drop policy if exists messages_delete on public.messages;

create or replace function public.delete_message_for_me(p_id uuid)
returns boolean language plpgsql security definer set search_path = public as $func$
declare m public.messages%rowtype;
begin
  select * into m from public.messages where id = p_id;
  if not found then return false; end if;
  if m.sender_id <> auth.uid() and m.recipient_id <> auth.uid() then
    raise exception 'Not allowed';
  end if;
  update public.messages
     set hidden_by_sender = hidden_by_sender or sender_id = auth.uid(),
         hidden_by_recipient = hidden_by_recipient or recipient_id = auth.uid()
   where id = p_id;
  -- true = both sides deleted -> caller should remove files, then call purge_hidden_message
  return exists(select 1 from public.messages where id = p_id and hidden_by_sender and hidden_by_recipient);
end;
$func$;

create or replace function public.purge_hidden_message(p_id uuid)
returns void language plpgsql security definer set search_path = public as $func$
begin
  delete from public.messages
   where id = p_id and hidden_by_sender and hidden_by_recipient
     and (sender_id = auth.uid() or recipient_id = auth.uid());
end;
$func$;

revoke all on function public.delete_message_for_me(uuid) from public, anon;
revoke all on function public.purge_hidden_message(uuid) from public, anon;
grant execute on function public.delete_message_for_me(uuid) to authenticated;
grant execute on function public.purge_hidden_message(uuid) to authenticated;

-- (tasks, announcements and meetings already have delete policies:
--  tasks: creator or admin | announcements: admin / department head | meetings: organizer or admin)
