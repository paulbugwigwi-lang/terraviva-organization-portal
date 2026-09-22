# Terraviva Organization Portal — V4

Production-oriented internal NGO portal built with React, Vite and Supabase.

## Included
- Supabase email/password authentication
- Staff self-registration with **pending approval** workflow
- Full staff directory and profiles
- Leadership and departments
- Internal mail
- Meetings and scheduling
- Private organizational document storage
- Announcements with organization-wide or department targeting
- Administration and account approval/rejection
- Role-based permissions and PostgreSQL Row Level Security
- Private Storage bucket and signed document access
- Vercel SPA rewrite configuration

## Setup
1. Create a Supabase project.
2. Open **SQL Editor** and run `supabase/schema.sql` in one execution.
3. In Supabase Auth, enable **Email/Password** and keep email confirmation enabled if you want verified staff emails.
4. In **Authentication → URL Configuration**, keep the Site URL and Redirect URLs pointed to the actual Vercel domain. The application now uses `window.location.origin`, so the frontend does not depend on a hard-coded Vercel URL.
5. Copy `.env.example` to `.env` and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`.
6. Run `npm install` then `npm run dev`.
7. Register the first leadership account. The user must verify the email and then be approved by an administrator. For the very first administrator, use Supabase SQL Editor to approve and assign the role once; this avoids an insecure public self-admin bootstrap.
8. Deploy the project to Vercel and add the same two **public** environment variables. Vercel must use Node 20.19+ (the repository includes `.nvmrc`).

### Authentication troubleshooting
- **Verification link opens a dead page:** the code now redirects to the current site origin automatically. If the domain itself is unavailable, fix/redeploy the Vercel deployment; then resend the verification email.
- **Email verified but login says pending:** this is expected until an administrator changes `staff_profiles.account_status` to `approved`.
- **Forgot password:** use the link on the Login screen; Supabase sends the reset email.
- **Verification email missing:** use **Resend verification email** on the Login screen and check spam/junk.
- Never put a Supabase service-role key in Vercel or browser code.

### Leadership role values
- `ceo_chairperson` — Paul Bugwigwi
- `coo_treasurer` — Annolbert Alexander Mutalemwa
- `executive_secretary`
- `department_head`
- `staff`
- `super_admin`

### Important security note
Never put a Supabase **service-role key** in browser code or Vercel client environment variables. Only use the project URL and anon/public key in this frontend.
