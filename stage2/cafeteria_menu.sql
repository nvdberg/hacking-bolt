-- Cafeteria menus (RGH / Pasqua) — one-time setup. Paste into Supabase → SQL Editor → Run.
-- Filled by the Unit Board's Capture tab (pasted from the intranet menu pages); read by the app's easter egg.
-- The menus are a rotating cycle (pages RGH1, RGH2, …), so we store one row per page and the app works
-- out which page applies to a date from the printed dates.

create table if not exists public.cafeteria_menu (
  site        text not null,              -- 'RGH' | 'PH' (| 'WRC')
  page        int  not null,              -- the N in cafeteriamenuRGH<N>.htm
  first_date  text,                       -- printed Sunday of that page, "YYYY-MM-DD" (year inferred)
  days        jsonb not null,             -- [{ "date": "YYYY-MM-DD", "weekday": "SUNDAY",
                                          --    "sections": [{ "label": "Today's Soup",
                                          --                   "items": [{ "name": "…", "price": "$2.25" }] }] }]
  imported_at timestamptz not null default now(),
  primary key (site, page)
);

alter table public.cafeteria_menu enable row level security;

grant select, insert, update on public.cafeteria_menu to anon;
grant select, insert, update, delete on public.cafeteria_menu to service_role;

drop policy if exists "cafeteria_menu anon select" on public.cafeteria_menu;
drop policy if exists "cafeteria_menu anon insert" on public.cafeteria_menu;
drop policy if exists "cafeteria_menu anon update" on public.cafeteria_menu;
create policy "cafeteria_menu anon select" on public.cafeteria_menu for select using (true);
create policy "cafeteria_menu anon insert" on public.cafeteria_menu for insert with check (true);
create policy "cafeteria_menu anon update" on public.cafeteria_menu for update using (true) with check (true);
