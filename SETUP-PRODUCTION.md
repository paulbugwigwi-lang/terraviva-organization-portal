# Terraviva Organization Portal — Production Setup

## 1. Supabase
1. Create a Supabase project.
2. Open **SQL Editor** and run `supabase/schema.sql`.
3. In **Authentication → Providers**, enable Email.
4. In **Authentication → URL Configuration**, add your Vercel production URL.
5. Copy the project URL and the **anon/public** key into `.env`:

```env
VITE_SUPABASE_URL=https://YOUR-PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_ANON_PUBLIC_KEY
```

Never put the Supabase `service_role` key in Vite frontend code.

## 2. Create the first leadership account
Register the first leadership user from the portal using the official email. Then, from Supabase SQL Editor (admin only), run:

```sql
update public.staff_profiles
set account_status='approved', system_role='ceo_chairperson', title='CEO & Chairperson'
where official_email='YOUR-CEO-EMAIL';
```

For the COO/Treasurer:

```sql
update public.staff_profiles
set account_status='approved', system_role='coo_treasurer', title='COO & Treasurer'
where official_email='YOUR-COO-EMAIL';
```

Update the email values before running these statements.

## 3. Local build

```bash
npm install
npm run build
npm run dev
```

## 4. Vercel
- Import the project repository/folder into Vercel.
- Framework: Vite.
- Build command: `npm run build`.
- Output directory: `dist`.
- Add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` as Production/Preview environment variables.
- Redeploy after changing environment variables.

## 5. Important security model
- New accounts are `pending` and cannot enter the portal until approved.
- Approved users can access organizational records permitted by RLS.
- Leadership roles can approve staff and publish announcements.
- Storage bucket `staff-files` is private; documents are opened through short-lived signed URLs.
- Keep the Supabase service-role key server-side only.

## Production hardening included in V6
- Pending users can read their own profile status, so the approval gate works correctly.
- SQL can be safely re-run without failing because of duplicate public policies.
- Staff profile, message, meeting, document and announcement policies are separated by action.
- Useful indexes are included for directory, inbox, meetings, documents and announcements.
- The private `staff-files` bucket remains non-public.

## First leadership account
1. Create Paul Bugwigwi in Supabase Authentication > Users using `ceo@terraviva.org` (or the official address you choose).
2. Copy the user's UUID.
3. Insert/update his `staff_profiles` row with `system_role='ceo_chairperson'` and `account_status='approved'`.
4. Repeat for Annolbert Alexander Mutalemwa with `system_role='coo_treasurer'`.
5. Do not put a Supabase service-role key into Vercel environment variables used by the browser.
