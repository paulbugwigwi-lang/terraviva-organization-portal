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
3. In Supabase Auth, enable Email/Password.
4. Copy `.env.example` to `.env` and set `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`.
5. Run `npm install` then `npm run dev`.
6. Register the first leadership accounts through the portal, then use a controlled/admin workflow to assign their roles and approve them. Alternatively create the users in Supabase Auth and insert/update their `staff_profiles` records using the SQL Editor.
7. Deploy the project to Vercel and add the same two **public** environment variables.

### Leadership role values
- `ceo_chairperson` — Paul Bugwigwi
- `coo_treasurer` — Annolbert Alexander Mutalemwa
- `executive_secretary`
- `department_head`
- `staff`
- `super_admin`

### Important security note
Never put a Supabase **service-role key** in browser code or Vercel client environment variables. Only use the project URL and anon/public key in this frontend.
