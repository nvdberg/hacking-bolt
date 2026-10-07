-- Hospital on-call roster (intensivists from PetalMD + RGH cardiology from the monthly PDF) — one-time setup.
-- Paste into Supabase → SQL Editor → Run.
-- Filled by the Unit Board's "Sync roster" chip (run on a hospital PC); read by the app's Who's On.
-- One row per (date, unit, role). name = surname only; null = nobody assigned. Each sync re-sends the whole
-- range it read, so swaps overwrite the old name.
--   unit: SICU / MICU / PHICU (intensivists) · CCU (cardiology)
--   role: day (07/08–17) · oncall (17–next morning, keyed on the date the night STARTS)
--         stemi_day · stemi_oncall (interventional, cardiology blue ink) · consults (cardiology 8–5 ward consults)

create table if not exists public.oncall_roster (
  date        text not null,              -- "YYYY-MM-DD"
  unit        text not null,
  role        text not null,
  name        text,
  source      text,                       -- 'petal' | 'cardiology-pdf'
  imported_at timestamptz not null default now(),
  primary key (date, unit, role)
);

alter table public.oncall_roster enable row level security;

grant select, insert, update on public.oncall_roster to anon;
grant select, insert, update, delete on public.oncall_roster to service_role;

drop policy if exists "oncall_roster anon select" on public.oncall_roster;
drop policy if exists "oncall_roster anon insert" on public.oncall_roster;
drop policy if exists "oncall_roster anon update" on public.oncall_roster;
create policy "oncall_roster anon select" on public.oncall_roster for select using (true);
create policy "oncall_roster anon insert" on public.oncall_roster for insert with check (true);
create policy "oncall_roster anon update" on public.oncall_roster for update using (true) with check (true);
