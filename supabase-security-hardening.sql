-- =====================================================================
--  Livestock Inspector app — SECURITY HARDENING (from the security audit)
--  Run ONCE in Supabase → SQL Editor, AFTER the other five files:
--    setup → circles → messages → abortion → subscriptions → THIS FILE
--  Safe to run again. Nothing here deletes or changes any record.
--
--  Fixes:
--   1. Circle members could promote themselves to "owner" (★) and rename
--      themselves to impersonate a colleague.
--   2. A sender could forge the "From" name on a task and pre-fill
--      system-only fields (closed / returned to sender / follow-up owner);
--      the recipient could rename the sender.
--   3. A user could put someone else's email into their own profile
--      (shown in the admin Subscription Manager and used by phone login).
--   4. Any signed-in user could ask whether another user is Pro / admin /
--      a member of a circle they are not in.
--   5. Defence in depth: the not-logged-in "anon" role gets no table
--      access at all; TRUNCATE / REFERENCES / TRIGGER removed; circles can
--      no longer be deleted through the API (deleting one would wipe the
--      other members' shared tasks and messages); profile settings size cap.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Circle membership rows: cannot be moved, role and name come from
--    the database (owner = the circle's creator; name = profile name)
-- ---------------------------------------------------------------------
create or replace function public.circle_member_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p public.profiles;
begin
  if tg_op = 'UPDATE' and (new.circle_id is distinct from old.circle_id
       or new.user_id is distinct from old.user_id or new.joined_at is distinct from old.joined_at) then
    raise exception 'Circle membership cannot be moved';
  end if;
  new.role := case when exists (select 1 from public.inspector_circles c
                                where c.id = new.circle_id and c.created_by = new.user_id)
                   then 'owner' else 'member' end;
  select * into p from public.profiles where id = new.user_id;
  if p.id is not null then
    new.display_name := coalesce(nullif(trim(p.full_name), ''), 'Inspector');
    new.hospital     := coalesce(p.hospital, '');
    new.area         := coalesce(p.area, '');
  end if;
  return new;
end $$;
drop trigger if exists circle_member_guard on public.circle_members;
create trigger circle_member_guard before insert or update on public.circle_members
  for each row execute function public.circle_member_guard();

-- keep member cards in step when an inspector edits their profile
create or replace function public.profile_to_member_cards() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.full_name is distinct from old.full_name or new.hospital is distinct from old.hospital
     or new.area is distinct from old.area then
    update public.circle_members set display_name = display_name where user_id = new.id;  -- guard refills from profile
  end if;
  return new;
end $$;
drop trigger if exists profile_to_member_cards on public.profiles;
create trigger profile_to_member_cards after update on public.profiles
  for each row execute function public.profile_to_member_cards();

-- repair any card that was already changed
update public.circle_members set display_name = display_name;


-- ---------------------------------------------------------------------
-- 2. Task allotments: names and system fields set by the database
-- ---------------------------------------------------------------------
create or replace function public.task_allotment_insert_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then return new; end if;            -- SQL Editor / service role
  new.from_user := auth.uid();
  if new.status is distinct from 'pending_acceptance' then raise exception 'A new task must start as pending acceptance'; end if;
  new.from_name := coalesce((select nullif(trim(full_name), '') from public.profiles where id = new.from_user), 'Inspector');
  new.to_name   := coalesce((select nullif(trim(full_name), '') from public.profiles where id = new.to_user), 'Inspector');
  new.accepted_at := null; new.closed_at := null; new.closed_by := null; new.closed_date := null;
  new.closure_note := null; new.response_note := null; new.declined_at := null;
  new.returned_to_sender := false; new.follow_up_owner_id := null;
  new.follow_up_status := null; new.follow_up_set_at := null;
  new.created_at := now(); new.updated_at := now();
  return new;
end $$;
drop trigger if exists task_allotment_insert_guard on public.task_allotments;
create trigger task_allotment_insert_guard before insert on public.task_allotments
  for each row execute function public.task_allotment_insert_guard();

create or replace function public.task_allotment_name_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if auth.uid() is not null and (new.from_name is distinct from old.from_name or new.to_name is distinct from old.to_name) then
    raise exception 'Task names cannot be changed';
  end if;
  return new;
end $$;
drop trigger if exists task_allotment_name_guard on public.task_allotments;
create trigger task_allotment_name_guard before update on public.task_allotments
  for each row execute function public.task_allotment_name_guard();


-- ---------------------------------------------------------------------
-- 3. Profile email always equals the real login email
-- ---------------------------------------------------------------------
create or replace function public.profile_email_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null then
    new.email := coalesce((select u.email::text from auth.users u where u.id = new.id), new.email);
  end if;
  return new;
end $$;
drop trigger if exists profile_email_guard on public.profiles;
create trigger profile_email_guard before insert or update on public.profiles
  for each row execute function public.profile_email_guard();

-- when the login email itself changes (after confirmation), copy it over
create or replace function public.auth_email_to_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.email is distinct from old.email then
    update public.profiles set email = new.email where id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed after update of email on auth.users
  for each row execute function public.auth_email_to_profile();

-- repair profiles that hold a different email than the login
update public.profiles p set email = u.email from auth.users u where u.id = p.id and p.email is distinct from u.email;

-- phone login looks up the REAL login email (not the editable profile copy)
create or replace function public.email_for_phone(p_phone text)
returns text language sql stable security definer set search_path = '' as $$
  select u.email::text from public.profiles p join auth.users u on u.id = p.id
  where p.phone = right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10)
    and length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) >= 10
  limit 1
$$;

-- admin list shows the real login email
create or replace function public.admin_overview()
returns table (
  user_id uuid, full_name text, email text, phone text, hospital text, area text,
  registered_at timestamptz, subscription_status text, subscription_start timestamptz,
  subscription_end timestamptz, days_left integer, request_status text, requested_at timestamptz,
  upi_ref_id text, review_note text, pending_payment_id uuid, pending_ref text,
  pending_amount integer, pending_at timestamptz, is_admin boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_app_admin(auth.uid()) then raise exception 'Admin only'; end if;
  return query
  select u.id, coalesce(p.full_name, ''), u.email::text, p.phone, p.hospital, p.area,
         u.created_at,
         case when coalesce(s.subscription_status, 'trial') = 'active' and coalesce(s.subscription_end, now()) <= now()
              then 'expired' else coalesce(s.subscription_status, 'trial') end,
         s.subscription_start, s.subscription_end,
         case when s.subscription_status = 'active' and s.subscription_end > now()
              then ceil(extract(epoch from (s.subscription_end - now())) / 86400)::int else 0 end,
         coalesce(s.request_status, 'none'), s.requested_at, s.upi_ref_id, s.review_note,
         pp.id, pp.upi_ref_id, pp.amount, pp.submitted_at,
         public.is_app_admin(u.id)
  from auth.users u
  left join public.profiles p on p.id = u.id
  left join public.subscriptions s on s.user_id = u.id
  left join public.subscription_payments pp on pp.user_id = u.id and pp.status = 'pending'
  order by (pp.id is null), pp.submitted_at desc nulls last, u.created_at desc;
end $$;
revoke all on function public.admin_overview() from public, anon;
grant execute on function public.admin_overview() to authenticated;

-- profile settings (reminder snooze list, target, signature) stay small
alter table public.profiles drop constraint if exists profiles_settings_size;
alter table public.profiles add constraint profiles_settings_size
  check (settings is null or pg_column_size(settings) <= 262144) not valid;


-- ---------------------------------------------------------------------
-- 4. Status checks answer only about yourself
--    (admins and the database itself may still ask about anyone)
-- ---------------------------------------------------------------------
create or replace function public.is_app_admin(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = '' as $$
  select p_user is not null
     and (auth.uid() is null or p_user = auth.uid()
          or exists (select 1 from public.app_admins a where a.user_id = auth.uid()))
     and exists (select 1 from public.app_admins a where a.user_id = p_user)
$$;

create or replace function public.has_pro(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = '' as $$
  select p_user is not null
     and (auth.uid() is null or p_user = auth.uid() or public.is_app_admin(auth.uid()))
     and (exists (select 1 from public.app_admins a where a.user_id = p_user)
          or exists (select 1 from public.subscriptions s
                     where s.user_id = p_user and s.subscription_status = 'active'
                       and s.subscription_end > now()))
$$;

create or replace function public.can_write_records(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = '' as $$
  select p_user is not null
     and (auth.uid() is null or p_user = auth.uid() or public.is_app_admin(auth.uid()))
     and (exists (select 1 from public.app_admins a where a.user_id = p_user)
          or not exists (select 1 from public.subscriptions s
                         where s.user_id = p_user
                           and (s.subscription_status = 'expired'
                                or (s.subscription_status = 'active' and coalesce(s.subscription_end, now()) <= now()))))
$$;

-- you can only ask about a circle you are in yourself
create or replace function public.is_circle_member(p_circle uuid, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = '' as $$
  select (auth.uid() is null or p_user = auth.uid()
          or exists (select 1 from public.circle_members me where me.circle_id = p_circle and me.user_id = auth.uid()))
     and exists (select 1 from public.circle_members m where m.circle_id = p_circle and m.user_id = p_user)
$$;


-- ---------------------------------------------------------------------
-- 5. Least privilege
-- ---------------------------------------------------------------------
-- not-logged-in visitors never touch tables (login by phone uses the
-- email_for_phone / phone_available functions, which stay available)
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from anon;
grant execute on function public.email_for_phone(text)  to anon, authenticated;
grant execute on function public.phone_available(text) to anon, authenticated;
-- PostgREST never needs these; remove them for defence in depth
revoke truncate, references, trigger on all tables in schema public from authenticated;
-- the app never deletes a whole circle; through the API it would wipe the
-- other members' shared tasks and messages. Members can still leave.
revoke delete on public.inspector_circles from authenticated;
-- keep future tables / functions closed for anon unless granted explicitly
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke execute on functions from anon;

-- Check (should list only email_for_phone and phone_available):
--   select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
--     and p.prorettype <> 'trigger'::regtype;
