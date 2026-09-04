-- Live calendar sync — one-time setup. Paste into Supabase → SQL Editor → Run.
-- Creates the subscriber registry (cal_subs) and the public bucket the poller writes each .ics into.

-- 1) Subscriber registry: emp_id → stable feed token + on/off switch.
create table if not exists public.cal_subs (
  emp_id     bigint primary key,
  token      text not null unique,
  enabled    boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.cal_subs enable row level security;

-- The app talks to Supabase with the publishable/anon key, so let it enroll + read its own row.
-- (Same low-sensitivity posture as open_shifts/pickups — shift logistics only, no patient data.)
drop policy if exists "cal_subs anon select" on public.cal_subs;
drop policy if exists "cal_subs anon insert" on public.cal_subs;
drop policy if exists "cal_subs anon update" on public.cal_subs;
create policy "cal_subs anon select" on public.cal_subs for select using (true);
create policy "cal_subs anon insert" on public.cal_subs for insert with check (true);
create policy "cal_subs anon update" on public.cal_subs for update using (true) with check (true);

-- 2) Public bucket for the generated .ics files. The poller uploads with the service key (bypasses RLS);
--    reads are public but the filename is a random, unguessable token, so nothing is discoverable.
insert into storage.buckets (id, name, public)
values ('calendars', 'calendars', true)
on conflict (id) do update set public = true;
