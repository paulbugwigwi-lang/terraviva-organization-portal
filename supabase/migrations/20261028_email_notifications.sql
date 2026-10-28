-- Email delivery for every in-app notification.
-- Flow: INSERT into notifications -> trigger -> pg_net -> Edge Function "send-notification-email" -> Brevo/Resend.
create extension if not exists pg_net with schema extensions;

alter table public.staff_profiles add column if not exists email_notifications boolean not null default true;
alter table public.notifications add column if not exists emailed_at timestamptz;
alter table public.notifications add column if not exists email_error text;

-- Shared secret between the database trigger and the Edge Function (kept in Vault, never in the repo).
do $$ begin
  if not exists(select 1 from vault.secrets where name='email_webhook_secret') then
    perform vault.create_secret(replace(gen_random_uuid()::text||gen_random_uuid()::text,'-',''),'email_webhook_secret','Auth between notifications trigger and send-notification-email');
  end if;
end $$;

create or replace function public.email_webhook_secret()
returns text language sql security definer set search_path=public as $$
  select decrypted_secret from vault.decrypted_secrets where name='email_webhook_secret' limit 1;
$$;
revoke execute on function public.email_webhook_secret() from public, anon, authenticated;
grant execute on function public.email_webhook_secret() to service_role;

create or replace function public.send_notification_email_hook()
returns trigger language plpgsql security definer set search_path=public, extensions as $$
declare v_secret text;
begin
  if not exists(select 1 from public.staff_profiles
                where id = new.recipient_id and email_notifications and official_email is not null) then
    return new;
  end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name='email_webhook_secret' limit 1;
  if v_secret is null then return new; end if;
  perform net.http_post(
    url := 'https://fuhocpdvouphbppvjzof.supabase.co/functions/v1/send-notification-email',
    headers := jsonb_build_object('Content-Type','application/json','x-webhook-secret',v_secret),
    body := jsonb_build_object('id', new.id));
  return new;
exception when others then
  return new;  -- an email problem must never block the notification itself
end $$;
revoke execute on function public.send_notification_email_hook() from public, anon, authenticated;

drop trigger if exists send_notification_email on public.notifications;
create trigger send_notification_email after insert on public.notifications
  for each row execute function public.send_notification_email_hook();
