-- Owner-only colleague notes for "Who could cover?" (locum / retired / ED main gig / no nights …) — one-time setup.
-- Paste into Supabase → SQL Editor → Run.
--
-- PRIVATE: the public app key can NOT read or write these tables. The only door is functions that check the
-- owner's secret (stored here as a SHA-256 hash only). Nobody types it: the owner's app makes a random secret,
-- keeps it in the owner's iCloud Keychain (follows to a new phone) and claims the table with it on first run —
-- first claim wins, after that it's locked. To reset (lost Keychain): delete from public.owner_secret; — the
-- app re-claims on its next open. No names live in this file or in GitHub — the seed rows are pasted separately.

create table if not exists public.cover_notes (
  name       text primary key,                 -- LB display name ("Jane Smith"); a single word matches one person
  tags       text[] not null default '{}',     -- locum · retired · notstarted · nosicu · ed · rarecca · nonights · hospitalist
  note       text,
  updated_at timestamptz not null default now()
);
create table if not exists public.owner_secret (
  id   int primary key default 1 check (id = 1),
  hash text not null                           -- hex SHA-256 of the owner's app secret
);
alter table public.cover_notes  enable row level security;   -- no policies → no direct API access
alter table public.owner_secret enable row level security;
revoke all on public.cover_notes, public.owner_secret from anon, authenticated;

create or replace function public.owner_ok(pass text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from owner_secret where hash = encode(sha256(convert_to(pass, 'UTF8')), 'hex'))
$$;
revoke all on function public.owner_ok(text) from public, anon, authenticated;

create or replace function public.cover_notes_get(pass text) returns setof public.cover_notes
language plpgsql stable security definer set search_path = public as $$
begin
  if not owner_ok(pass) then raise exception 'not allowed' using errcode = '42501'; end if;
  return query select * from cover_notes order by name;
end $$;

-- Empty tags + empty note = delete the row.
create or replace function public.cover_notes_put(pass text, p_name text, p_tags text[], p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not owner_ok(pass) then raise exception 'not allowed' using errcode = '42501'; end if;
  if coalesce(array_length(p_tags, 1), 0) = 0 and coalesce(trim(p_note), '') = '' then
    delete from cover_notes where name = p_name;
  else
    insert into cover_notes (name, tags, note, updated_at) values (p_name, coalesce(p_tags, '{}'), nullif(trim(p_note), ''), now())
    on conflict (name) do update set tags = excluded.tags, note = excluded.note, updated_at = now();
  end if;
end $$;

-- First run: the owner's app registers its secret. Only works while no secret is set; true = this secret is the owner's.
create or replace function public.owner_claim(pass text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if length(coalesce(pass, '')) < 32 then return false; end if;
  insert into owner_secret (id, hash) values (1, encode(sha256(convert_to(pass, 'UTF8')), 'hex')) on conflict (id) do nothing;
  return owner_ok(pass);
end $$;

revoke all on function public.cover_notes_get(text), public.cover_notes_put(text, text, text[], text), public.owner_claim(text) from public;
grant execute on function public.cover_notes_get(text), public.cover_notes_put(text, text, text[], text), public.owner_claim(text) to anon;
