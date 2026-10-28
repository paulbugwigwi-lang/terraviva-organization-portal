-- Terraviva Organization Portal: Discussions (threads, replies, reactions) with multi-file attachments.
-- Attachments reuse the polymorphic public.attachments table via parent types 'discussion' and 'discussion_reply'.

-- ---------- notifications: deep links ----------
alter table public.notifications add column if not exists link_type text;
alter table public.notifications add column if not exists link_id uuid;
create index if not exists notifications_recipient_idx on public.notifications(recipient_id, is_read, created_at desc);

-- ---------- tables ----------
create table if not exists public.discussions (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 3 and 200),
  body text not null default '' check (char_length(body) <= 20000),
  category text not null default 'general' check (category in ('general','project','question','idea','announcement','urgent')),
  audience text not null default 'organization' check (audience in ('organization','department')),
  department text,
  author_id uuid not null references public.staff_profiles(id) on delete cascade,
  pinned boolean not null default false,
  locked boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_activity_at timestamptz not null default now(),
  check (audience <> 'department' or department is not null)
);
create index if not exists discussions_activity_idx on public.discussions(pinned desc, last_activity_at desc);
create index if not exists discussions_author_idx on public.discussions(author_id);

create table if not exists public.discussion_replies (
  id uuid primary key default gen_random_uuid(),
  discussion_id uuid not null references public.discussions(id) on delete cascade,
  author_id uuid not null references public.staff_profiles(id) on delete cascade,
  reply_to_id uuid references public.discussion_replies(id) on delete set null,
  body text not null default '' check (char_length(body) <= 20000),
  created_at timestamptz not null default now(),
  edited_at timestamptz
);
create index if not exists discussion_replies_thread_idx on public.discussion_replies(discussion_id, created_at);
create index if not exists discussion_replies_author_idx on public.discussion_replies(author_id);
create index if not exists discussion_replies_reply_to_idx on public.discussion_replies(reply_to_id);

create table if not exists public.discussion_reactions (
  id uuid primary key default gen_random_uuid(),
  target_type text not null check (target_type in ('discussion','reply')),
  target_id uuid not null,
  user_id uuid not null references public.staff_profiles(id) on delete cascade,
  emoji text not null default '👍' check (emoji in ('👍','❤️','🎉','👏','🙏','💡')),
  created_at timestamptz not null default now(),
  unique (target_type, target_id, user_id, emoji)
);
create index if not exists discussion_reactions_target_idx on public.discussion_reactions(target_type, target_id);
create index if not exists discussion_reactions_user_idx on public.discussion_reactions(user_id);

-- ---------- access helpers ----------
create or replace function public.can_view_discussion(p_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_approved() and exists(
    select 1 from public.discussions d
    where d.id = p_id and (
      d.author_id = auth.uid() or public.is_admin() or d.audience = 'organization'
      or (d.audience = 'department' and d.department is not distinct from
          (select department from public.staff_profiles where id = auth.uid()))));
$$;

create or replace function public.discussion_of(p_type text, p_id uuid)
returns uuid language sql stable security definer set search_path=public as $$
  select case p_type
    when 'discussion' then (select id from public.discussions where id = p_id)
    when 'reply' then (select discussion_id from public.discussion_replies where id = p_id)
  end;
$$;

-- ---------- attachment access: add the two new parent types ----------
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
    else false end;
$$;

create or replace function public.can_delete_attachment_object(p_name text)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from public.attachments a
    where a.storage_path = p_name and (
      a.uploaded_by = auth.uid()
      or (a.parent_type = 'task' and exists(select 1 from public.tasks t where t.id = a.parent_id and t.assigned_by = auth.uid()))
      or (a.parent_type = 'announcement' and exists(select 1 from public.announcements n where n.id = a.parent_id and n.author_id = auth.uid()))
      or (a.parent_type = 'meeting' and exists(select 1 from public.meetings m where m.id = a.parent_id and m.organizer_id = auth.uid()))
      or (a.parent_type = 'discussion' and exists(select 1 from public.discussions d where d.id = a.parent_id and d.author_id = auth.uid()))
      or (a.parent_type <> 'message' and public.is_admin())
      or (a.parent_type = 'message' and exists(select 1 from public.messages m
            where m.id = a.parent_id and m.hidden_by_sender and m.hidden_by_recipient
              and (m.sender_id = auth.uid() or m.recipient_id = auth.uid())))
    ));
$$;

alter table public.attachments drop constraint if exists attachments_parent_type_check;
alter table public.attachments add constraint attachments_parent_type_check
  check (parent_type in ('task','announcement','meeting','message','discussion','discussion_reply'));
create index if not exists attachments_parent_idx on public.attachments(parent_type, parent_id);

-- ---------- RLS ----------
alter table public.discussions enable row level security;
alter table public.discussion_replies enable row level security;
alter table public.discussion_reactions enable row level security;

drop policy if exists discussions_select on public.discussions;
create policy discussions_select on public.discussions for select to authenticated
  using (public.can_view_discussion(id));
drop policy if exists discussions_insert on public.discussions;
create policy discussions_insert on public.discussions for insert to authenticated
  with check (public.is_approved() and author_id = (select auth.uid())
    and (audience = 'organization' or public.is_admin()
         or department is not distinct from (select department from public.staff_profiles where id = (select auth.uid()))));
drop policy if exists discussions_update on public.discussions;
create policy discussions_update on public.discussions for update to authenticated
  using (public.is_approved() and (author_id = (select auth.uid()) or public.is_admin()))
  with check (public.is_approved() and (author_id = (select auth.uid()) or public.is_admin()));
drop policy if exists discussions_delete on public.discussions;
create policy discussions_delete on public.discussions for delete to authenticated
  using (public.is_approved() and (author_id = (select auth.uid()) or public.is_admin()));

drop policy if exists replies_select on public.discussion_replies;
create policy replies_select on public.discussion_replies for select to authenticated
  using (public.can_view_discussion(discussion_id));
drop policy if exists replies_insert on public.discussion_replies;
create policy replies_insert on public.discussion_replies for insert to authenticated
  with check (author_id = (select auth.uid()) and public.can_view_discussion(discussion_id)
    and (public.is_admin() or not exists(select 1 from public.discussions d where d.id = discussion_id and d.locked)));
drop policy if exists replies_update on public.discussion_replies;
create policy replies_update on public.discussion_replies for update to authenticated
  using (author_id = (select auth.uid())) with check (author_id = (select auth.uid()));
drop policy if exists replies_delete on public.discussion_replies;
create policy replies_delete on public.discussion_replies for delete to authenticated
  using (public.is_approved() and (author_id = (select auth.uid()) or public.is_admin()));

drop policy if exists reactions_select on public.discussion_reactions;
create policy reactions_select on public.discussion_reactions for select to authenticated
  using (public.can_view_discussion(public.discussion_of(target_type, target_id)));
drop policy if exists reactions_insert on public.discussion_reactions;
create policy reactions_insert on public.discussion_reactions for insert to authenticated
  with check (user_id = (select auth.uid()) and public.can_view_discussion(public.discussion_of(target_type, target_id)));
drop policy if exists reactions_delete on public.discussion_reactions;
create policy reactions_delete on public.discussion_reactions for delete to authenticated
  using (user_id = (select auth.uid()));

-- ---------- triggers ----------
create or replace function public.discussions_guard()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op = 'UPDATE' then
    if new.author_id is distinct from old.author_id then raise exception 'Discussion author cannot be changed'; end if;
    if auth.uid() is not null and not public.is_admin() then
      if new.pinned is distinct from old.pinned or new.locked is distinct from old.locked then
        raise exception 'Only administrators can pin or lock discussions'; end if;
      if new.audience is distinct from old.audience or new.department is distinct from old.department then
        raise exception 'Audience cannot be changed after posting'; end if;
    end if;
    if new.title is distinct from old.title or new.body is distinct from old.body then new.updated_at := now(); end if;
  elsif tg_op = 'INSERT' and auth.uid() is not null and not public.is_admin() and (new.pinned or new.locked) then
    new.pinned := false; new.locked := false;
  end if;
  return new;
end $$;
drop trigger if exists discussions_guard on public.discussions;
create trigger discussions_guard before insert or update on public.discussions
  for each row execute function public.discussions_guard();

create or replace function public.replies_guard()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.discussion_id is distinct from old.discussion_id or new.author_id is distinct from old.author_id then
    raise exception 'Reply thread and author cannot be changed'; end if;
  if new.body is distinct from old.body then new.edited_at := now(); end if;
  return new;
end $$;
drop trigger if exists replies_guard on public.discussion_replies;
create trigger replies_guard before update on public.discussion_replies
  for each row execute function public.replies_guard();

create or replace function public.notify_new_discussion()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_name text;
begin
  select coalesce(full_name,'A colleague') into v_name from public.staff_profiles where id = new.author_id;
  insert into public.notifications(recipient_id,title,body,type,link_type,link_id)
  select s.id, 'New discussion: '||left(new.title,120), v_name||' started a discussion'||
         case when new.audience='department' then ' in '||new.department else '' end||'.',
         'discussion','discussion',new.id
  from public.staff_profiles s
  where s.account_status='approved' and s.id <> new.author_id
    and (new.audience='organization' or s.department is not distinct from new.department
         or s.system_role in ('ceo_chairperson','coo_treasurer','executive_secretary','super_admin'));
  return new;
end $$;
drop trigger if exists notify_new_discussion on public.discussions;
create trigger notify_new_discussion after insert on public.discussions
  for each row execute function public.notify_new_discussion();

create or replace function public.notify_new_reply()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_name text; v_title text;
begin
  update public.discussions set last_activity_at = now() where id = new.discussion_id;
  select coalesce(full_name,'A colleague') into v_name from public.staff_profiles where id = new.author_id;
  select title into v_title from public.discussions where id = new.discussion_id;
  insert into public.notifications(recipient_id,title,body,type,link_type,link_id)
  select distinct u.uid, 'New reply: '||left(v_title,120), v_name||' replied in a discussion you follow.',
         'discussion','discussion',new.discussion_id
  from (
    select author_id uid from public.discussions where id = new.discussion_id
    union select author_id from public.discussion_replies where discussion_id = new.discussion_id
    union select author_id from public.discussion_replies where id = new.reply_to_id
  ) u
  join public.staff_profiles s on s.id = u.uid and s.account_status='approved'
  where u.uid <> new.author_id;
  return new;
end $$;
drop trigger if exists notify_new_reply on public.discussion_replies;
create trigger notify_new_reply after insert on public.discussion_replies
  for each row execute function public.notify_new_reply();

-- remove attachment rows (and reactions) when their parent goes away
create or replace function public.cleanup_discussion_children()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_table_name = 'discussions' then
    delete from public.attachments where (parent_type='discussion' and parent_id=old.id)
      or (parent_type='discussion_reply' and parent_id in (select id from public.discussion_replies where discussion_id=old.id));
    delete from public.discussion_reactions where (target_type='discussion' and target_id=old.id)
      or (target_type='reply' and target_id in (select id from public.discussion_replies where discussion_id=old.id));
  else
    delete from public.attachments where parent_type='discussion_reply' and parent_id=old.id;
    delete from public.discussion_reactions where target_type='reply' and target_id=old.id;
  end if;
  return old;
end $$;
drop trigger if exists cleanup_discussion on public.discussions;
create trigger cleanup_discussion before delete on public.discussions
  for each row execute function public.cleanup_discussion_children();
drop trigger if exists cleanup_reply on public.discussion_replies;
create trigger cleanup_reply before delete on public.discussion_replies
  for each row execute function public.cleanup_discussion_children();

-- ---------- realtime ----------
do $$ begin
  begin alter publication supabase_realtime add table public.notifications; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.discussions; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.discussion_replies; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.discussion_reactions; exception when duplicate_object then null; end;
end $$;

-- helper functions are for RLS only
revoke execute on function public.can_view_discussion(uuid) from anon;
revoke execute on function public.discussion_of(text, uuid) from anon;
