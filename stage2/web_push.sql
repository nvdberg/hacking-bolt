-- Web Push subscriptions for the Working-Bolt web version (browser notifications, same alerts as the app's APNs push).
-- No table policies: anon can neither read nor list subscriptions. Browsers add/remove their OWN subscription through
-- two SECURITY DEFINER functions keyed on the push endpoint (an unguessable URL only that browser knows).
-- The poller (service role) reads the table to send.
create table if not exists public.web_push (
  endpoint   text primary key check (endpoint like 'https://%' and length(endpoint) < 1200),
  p256dh     text not null check (length(p256dh) < 200),
  auth       text not null check (length(auth) < 100),
  emp_id     integer not null,
  ua         text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.web_push enable row level security;

create or replace function public.web_push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_emp integer, p_ua text default null)
returns void language sql security definer set search_path = public as $$
  insert into web_push (endpoint, p256dh, auth, emp_id, ua) values (p_endpoint, p_p256dh, p_auth, p_emp, left(p_ua, 200))
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, emp_id = excluded.emp_id,
                                       ua = excluded.ua, updated_at = now();
$$;
create or replace function public.web_push_unsubscribe(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from web_push where endpoint = p_endpoint;
$$;
revoke all on function public.web_push_subscribe(text, text, text, integer, text) from public;
revoke all on function public.web_push_unsubscribe(text) from public;
grant execute on function public.web_push_subscribe(text, text, text, integer, text) to anon, authenticated;
grant execute on function public.web_push_unsubscribe(text) to anon, authenticated;
