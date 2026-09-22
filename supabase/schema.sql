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
as $
  select exists(select 1 from public.staff_profiles me where me.id=auth.uid() and me.account_status='approved' and (me.id=target_id or public.is_admin() or me.reporting_to_id=target_id or exists(select 1 from public.staff_profiles child where child.id=target_id and child.reporting_to_id=me.id) or (me.department is not null and me.department=(select department from public.staff_profiles where id=target_id) and me.system_role='department_head')));
$;

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
