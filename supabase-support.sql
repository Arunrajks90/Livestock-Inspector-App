-- =====================================================================
--  Livestock Inspector app — Admin User Directory + Support Chat
--  Run ONCE in Supabase → SQL Editor, AFTER the other six files:
--    setup → circles → messages → abortion → subscriptions
--    → security-hardening → THIS FILE
--  Safe to run again. Nothing here deletes or changes clinical records.
--
--  * user_profiles : a protected VIEW of each inspector's registration
--    details + plan. It reads the existing `profiles` table (filled at
--    sign-up and on every profile edit) so there is no second copy that
--    could drift. Inspector → only own row. Admin → every row.
--    Passwords are never stored here: they live only inside Supabase Auth
--    (auth.users), and nothing in this file reads the password column.
--  * support_messages : one support thread per inspector.
--    Inspector → reads / writes only own thread. Admin → all threads,
--    replies to any inspector.
--  * Admin access = accounts listed in public.app_admins (you),
--    checked inside the database.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. "Last seen" + support contact settings
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists last_seen_at timestamptz;

alter table public.app_settings add column if not exists support_email text not null default '';
alter table public.app_settings add column if not exists support_phone text not null default '';
-- first install: use the admin's login email as the support email (change it in the app)
update public.app_settings s set support_email = u.email
from public.app_admins a join auth.users u on u.id = a.user_id
where s.id = 1 and s.support_email = '';

-- the app calls this on every login / app open (and every few minutes while open)
create or replace function public.mark_seen() returns void
language sql security definer set search_path = '' as $$
  update public.profiles set last_seen_at = now() where id = auth.uid();
$$;
revoke all on function public.mark_seen() from public, anon;
grant execute on function public.mark_seen() to authenticated;


-- ---------------------------------------------------------------------
-- 2. user_profiles (own row for everyone, all rows for the admin)
-- ---------------------------------------------------------------------
drop view if exists public.user_profiles;
create view public.user_profiles as
select u.id,
       coalesce(p.full_name, '')                        as full_name,
       u.email::text                                    as email,
       p.phone                                          as phone_number,
       p.area                                           as district_or_area,
       concat_ws(' · ', nullif(p.hospital, ''), nullif(p.qualification, '')) as office_or_designation,
       p.hospital,
       p.qualification,
       p.age,
       p.gender,
       case when coalesce(s.subscription_status, 'trial') = 'active' and coalesce(s.subscription_end, now()) <= now()
            then 'expired' else coalesce(s.subscription_status, 'trial') end as subscription_status,
       s.subscription_end,
       p.last_seen_at,
       u.created_at
from auth.users u
left join public.profiles p on p.id = u.id
left join public.subscriptions s on s.user_id = u.id
where u.id = (select auth.uid()) or (select public.is_app_admin());
-- (the WHERE clause is the access rule; the view never shows settings)
revoke all on public.user_profiles from anon, public;
grant select on public.user_profiles to authenticated;

-- inspectors keep inserting / updating their OWN row through `profiles`
-- (existing policies: auth.uid() = id). Admin plan changes go through the
-- admin_activate / admin_revoke functions from supabase-subscriptions.sql.


-- ---------------------------------------------------------------------
-- 3. Admin directory: everything needed for the Users list
--    (contact + login details; NEVER the password)
-- ---------------------------------------------------------------------
create or replace function public.admin_user_directory()
returns table (
  user_id uuid, full_name text, email text, phone_number text, district_or_area text,
  hospital text, qualification text, age text, gender text,
  registered_at timestamptz, email_confirmed_at timestamptz, last_sign_in_at timestamptz,
  last_seen_at timestamptz, subscription_status text, subscription_end timestamptz,
  days_left integer, request_status text, is_admin boolean,
  support_total integer, support_unread integer, support_last_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_app_admin(auth.uid()) then raise exception 'Admin only'; end if;
  return query
  select u.id, coalesce(p.full_name, ''), u.email::text, p.phone, p.area,
         p.hospital, p.qualification, p.age::text, p.gender,
         u.created_at, u.email_confirmed_at, u.last_sign_in_at,
         p.last_seen_at,
         case when coalesce(s.subscription_status, 'trial') = 'active' and coalesce(s.subscription_end, now()) <= now()
              then 'expired' else coalesce(s.subscription_status, 'trial') end,
         s.subscription_end,
         case when s.subscription_status = 'active' and s.subscription_end > now()
              then ceil(extract(epoch from (s.subscription_end - now())) / 86400)::int else 0 end,
         coalesce(s.request_status, 'none'),
         public.is_app_admin(u.id),
         (select count(*)::int from public.support_messages m where m.user_id = u.id),
         (select count(*)::int from public.support_messages m where m.user_id = u.id and m.sender_role = 'user' and m.read_by_admin_at is null),
         (select max(m.created_at) from public.support_messages m where m.user_id = u.id)
  from auth.users u
  left join public.profiles p on p.id = u.id
  left join public.subscriptions s on s.user_id = u.id
  order by greatest(coalesce(p.last_seen_at, u.last_sign_in_at, u.created_at), coalesce(u.last_sign_in_at, u.created_at)) desc;
end $$;


-- ---------------------------------------------------------------------
-- 4. Support messages (one thread per inspector)
-- ---------------------------------------------------------------------
create table if not exists public.support_messages (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,   -- whose thread
  sender_id        uuid references auth.users(id) on delete set null,
  sender_role      text not null check (sender_role in ('user','admin')),
  body             text not null check (char_length(trim(body)) between 1 and 2000),
  created_at       timestamptz not null default now(),
  read_by_user_at  timestamptz,
  read_by_admin_at timestamptz
);
create index if not exists support_messages_thread_idx on public.support_messages (user_id, created_at);
create index if not exists support_messages_unread_admin_idx on public.support_messages (user_id)
  where sender_role = 'user' and read_by_admin_at is null;
create index if not exists support_messages_unread_user_idx on public.support_messages (user_id)
  where sender_role = 'admin' and read_by_user_at is null;

alter table public.support_messages enable row level security;
drop policy if exists "support: read own thread"     on public.support_messages;
drop policy if exists "support: admin read all"      on public.support_messages;
drop policy if exists "support: user writes own"     on public.support_messages;
drop policy if exists "support: admin replies"       on public.support_messages;
create policy "support: read own thread" on public.support_messages
  for select to authenticated using (user_id = (select auth.uid()));
create policy "support: admin read all" on public.support_messages
  for select to authenticated using ((select public.is_app_admin()));
create policy "support: user writes own" on public.support_messages
  for insert to authenticated
  with check (user_id = (select auth.uid()) and sender_id = (select auth.uid()) and sender_role = 'user');
create policy "support: admin replies" on public.support_messages
  for insert to authenticated
  with check ((select public.is_app_admin()) and sender_id = (select auth.uid()) and sender_role = 'admin'
              and user_id <> (select auth.uid()));
-- no update / delete policies: messages cannot be edited or removed.
-- Read receipts are set only through support_mark_read() below.
revoke all on public.support_messages from anon;
revoke update, delete, truncate, references, trigger on public.support_messages from authenticated;
grant select, insert on public.support_messages to authenticated;

-- server sets time + read flags; simple flood limit (30 messages / 10 min)
create or replace function public.support_message_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then return new; end if;            -- SQL Editor / service role
  new.sender_id := auth.uid();
  new.body := trim(new.body);
  new.created_at := now();
  new.read_by_user_at := case when new.sender_role = 'user' then now() else null end;
  new.read_by_admin_at := case when new.sender_role = 'admin' then now() else null end;
  if (select count(*) from public.support_messages m
      where m.sender_id = auth.uid() and m.created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'Too many messages — please wait a few minutes';
  end if;
  return new;
end $$;
drop trigger if exists support_message_guard on public.support_messages;
create trigger support_message_guard before insert on public.support_messages
  for each row execute function public.support_message_guard();

-- mark a thread as read (inspector: own thread; admin: any inspector's thread)
create or replace function public.support_mark_read(p_user uuid default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); n integer;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if p_user is null or p_user = me then
    update public.support_messages set read_by_user_at = now()
     where user_id = me and sender_role = 'admin' and read_by_user_at is null;
  else
    if not public.is_app_admin(me) then raise exception 'Admin only'; end if;
    update public.support_messages set read_by_admin_at = now()
     where user_id = p_user and sender_role = 'user' and read_by_admin_at is null;
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

-- admin inbox: one row per thread
create or replace function public.admin_support_threads()
returns table (user_id uuid, full_name text, email text, phone_number text, district_or_area text,
               last_at timestamptz, last_body text, last_role text, total integer, unread integer)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_app_admin(auth.uid()) then raise exception 'Admin only'; end if;
  return query
  select t.user_id, coalesce(p.full_name, ''), u.email::text, p.phone, p.area,
         l.created_at, left(l.body, 160), l.sender_role, t.total, t.unread
  from (select m.user_id, count(*)::int total,
               count(*) filter (where m.sender_role = 'user' and m.read_by_admin_at is null)::int unread
        from public.support_messages m group by m.user_id) t
  join auth.users u on u.id = t.user_id
  left join public.profiles p on p.id = t.user_id
  join lateral (select m.created_at, m.body, m.sender_role from public.support_messages m
                where m.user_id = t.user_id order by m.created_at desc limit 1) l on true
  order by (t.unread > 0) desc, l.created_at desc;
end $$;

revoke all on function public.admin_user_directory()     from public, anon;
revoke all on function public.admin_support_threads()    from public, anon;
revoke all on function public.support_mark_read(uuid)    from public, anon;
grant execute on function public.admin_user_directory()  to authenticated;
grant execute on function public.admin_support_threads() to authenticated;
grant execute on function public.support_mark_read(uuid) to authenticated;

-- live updates (Supabase Realtime also applies the row security above)
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'support_messages') then
    alter publication supabase_realtime add table public.support_messages;
  end if;
end $$;

-- Checks:
--   select * from public.user_profiles;                       -- as admin: everyone
--   select support_email, support_phone from public.app_settings;
