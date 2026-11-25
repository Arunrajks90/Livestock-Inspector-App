-- =====================================================================
-- Livestock Inspector – Inspector Circles, Task Allotment / Handover,
-- and Follow-up Closure columns.
-- Run this AFTER supabase-setup.sql, in Supabase → SQL Editor → New query → Run.
-- Safe to run again. It does not change or expose any existing records:
-- farmers, animals, treatments, ai_records and feed_supplies stay
-- strictly private (auth.uid() = user_id).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Circles (teams) and their members
-- ---------------------------------------------------------------------
create table if not exists public.inspector_circles (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) between 2 and 60),
  invite_code text not null unique,
  created_by  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);

-- Only a public "name card" of each member is stored here (name, hospital, area),
-- so circle members can see each other without reading anyone's private profile or records.
create table if not exists public.circle_members (
  circle_id    uuid not null references public.inspector_circles(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  display_name text not null default '',
  hospital     text not null default '',
  area         text not null default '',
  role         text not null default 'member' check (role in ('owner','member')),
  joined_at    timestamptz not null default now(),
  primary key (circle_id, user_id)
);
create index if not exists circle_members_user_idx on public.circle_members (user_id);

-- ---------------------------------------------------------------------
-- 2. Task allotments (handover of ONE task, with its own description)
-- ---------------------------------------------------------------------
create table if not exists public.task_allotments (
  id               uuid primary key default gen_random_uuid(),
  circle_id        uuid not null references public.inspector_circles(id) on delete cascade,
  from_user        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  to_user          uuid not null references auth.users(id) on delete cascade,
  from_name        text not null default '',
  to_name          text not null default '',
  task_type        text not null check (task_type in ('treatment','treatment_followup','ai','ai_followup')),
  source_record_id text,                       -- id of the sender's own record (stays private to the sender)
  title            text not null default '',
  due_date         text,
  description      text not null default '',   -- note written by the sender
  payload          jsonb not null default '{}'::jsonb,  -- ONLY this task: farmer contact, animal summary, task details
  status           text not null default 'pending_acceptance'
                   check (status in ('pending_acceptance','accepted','declined','closed','cancelled')),
  response_note    text,                       -- reason when declined / cancelled
  accepted_at      timestamptz,
  closed_at        timestamptz,
  closed_by        uuid references auth.users(id) on delete set null,
  closure_note     text,                       -- closure description / reason
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (from_user <> to_user)
);
create index if not exists task_allot_to_idx   on public.task_allotments (to_user, status);
create index if not exists task_allot_from_idx on public.task_allotments (from_user, status);

-- ---------------------------------------------------------------------
-- 3. Helper checks (security definer so policies do not loop on themselves)
-- ---------------------------------------------------------------------
create or replace function public.is_circle_member(p_circle uuid, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.circle_members m where m.circle_id = p_circle and m.user_id = p_user)
$$;
revoke all on function public.is_circle_member(uuid, uuid) from public;
grant execute on function public.is_circle_member(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Row Level Security
-- ---------------------------------------------------------------------
alter table public.inspector_circles enable row level security;
alter table public.circle_members    enable row level security;
alter table public.task_allotments   enable row level security;

-- circles: members can see their circle; only the creator can rename / delete it.
drop policy if exists "circles: members read"   on public.inspector_circles;
drop policy if exists "circles: owner update"   on public.inspector_circles;
drop policy if exists "circles: owner delete"   on public.inspector_circles;
create policy "circles: members read" on public.inspector_circles for select to authenticated
  using (public.is_circle_member(id) or created_by = (select auth.uid()));
create policy "circles: owner update" on public.inspector_circles for update to authenticated
  using (created_by = (select auth.uid())) with check (created_by = (select auth.uid()));
create policy "circles: owner delete" on public.inspector_circles for delete to authenticated
  using (created_by = (select auth.uid()));
-- (creating a circle and joining one go through the create_circle / join_circle functions below)

-- members: you can see the name cards of people in your own circles only.
drop policy if exists "members: circle read"        on public.circle_members;
drop policy if exists "members: update own card"    on public.circle_members;
drop policy if exists "members: leave or owner remove" on public.circle_members;
create policy "members: circle read" on public.circle_members for select to authenticated
  using (public.is_circle_member(circle_id));
create policy "members: update own card" on public.circle_members for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "members: leave or owner remove" on public.circle_members for delete to authenticated
  using (user_id = (select auth.uid())
         or exists (select 1 from public.inspector_circles c where c.id = circle_id and c.created_by = (select auth.uid())));

-- allotments: only the sender and the recipient can ever see a task.
drop policy if exists "allot: sender or recipient read" on public.task_allotments;
drop policy if exists "allot: send to circle member"    on public.task_allotments;
drop policy if exists "allot: sender or recipient update" on public.task_allotments;
create policy "allot: sender or recipient read" on public.task_allotments for select to authenticated
  using (from_user = (select auth.uid()) or to_user = (select auth.uid()));
create policy "allot: send to circle member" on public.task_allotments for insert to authenticated
  with check (from_user = (select auth.uid())
              and status = 'pending_acceptance'
              and public.is_circle_member(circle_id)
              and public.is_circle_member(circle_id, to_user));
create policy "allot: sender or recipient update" on public.task_allotments for update to authenticated
  using (from_user = (select auth.uid()) or to_user = (select auth.uid()))
  with check (from_user = (select auth.uid()) or to_user = (select auth.uid()));
-- no delete policy: allotments are kept as an audit trail.

grant select, update, delete on public.inspector_circles to authenticated;
grant select, update, delete on public.circle_members    to authenticated;
grant select, insert, update on public.task_allotments   to authenticated;

-- Allowed status changes, and nobody can rewrite who/what a task is.
--   recipient: pending_acceptance → accepted / declined;  accepted → closed
--   sender:    pending_acceptance → cancelled;  pending_acceptance / accepted → closed (handled elsewhere)
create or replace function public.task_allotment_guard() returns trigger
language plpgsql set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if new.from_user is distinct from old.from_user or new.to_user is distinct from old.to_user
     or new.circle_id is distinct from old.circle_id or new.task_type is distinct from old.task_type
     or new.source_record_id is distinct from old.source_record_id or new.payload is distinct from old.payload
     or new.description is distinct from old.description or new.title is distinct from old.title
     or new.created_at is distinct from old.created_at then
    raise exception 'Task details cannot be changed after allotment';
  end if;
  if new.status is distinct from old.status then
    if old.status in ('declined','closed','cancelled') then
      raise exception 'This task is already %', old.status;
    end if;
    if me = old.to_user and not (
         (old.status = 'pending_acceptance' and new.status in ('accepted','declined'))
      or (old.status = 'accepted' and new.status = 'closed')) then
      raise exception 'Recipient cannot change status from % to %', old.status, new.status;
    end if;
    if me = old.from_user and me <> old.to_user and not (
         (old.status = 'pending_acceptance' and new.status in ('cancelled','closed'))
      or (old.status = 'accepted' and new.status = 'closed')) then
      raise exception 'Sender cannot change status from % to %', old.status, new.status;
    end if;
    if new.status = 'accepted' then new.accepted_at := now(); end if;
    if new.status = 'closed' then new.closed_at := coalesce(new.closed_at, now()); new.closed_by := me; end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists task_allotment_guard on public.task_allotments;
create trigger task_allotment_guard before update on public.task_allotments
  for each row execute function public.task_allotment_guard();

-- ---------------------------------------------------------------------
-- 5. Create / join a circle (invite code)
-- ---------------------------------------------------------------------
create or replace function public.create_circle(p_name text) returns public.inspector_circles
language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); c public.inspector_circles; code text; p public.profiles;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'Circle name is too short'; end if;
  loop
    code := upper(substr(md5(gen_random_uuid()::text), 1, 6));
    exit when not exists (select 1 from public.inspector_circles where invite_code = code);
  end loop;
  insert into public.inspector_circles (name, invite_code, created_by) values (trim(p_name), code, me) returning * into c;
  select * into p from public.profiles where id = me;
  insert into public.circle_members (circle_id, user_id, display_name, hospital, area, role)
  values (c.id, me, coalesce(p.full_name,''), coalesce(p.hospital,''), coalesce(p.area,''), 'owner');
  return c;
end $$;

create or replace function public.join_circle(p_code text) returns public.inspector_circles
language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); c public.inspector_circles; p public.profiles;
begin
  if me is null then raise exception 'Not signed in'; end if;
  select * into c from public.inspector_circles where invite_code = upper(trim(coalesce(p_code,'')));
  if c.id is null then raise exception 'No circle found with that invite code'; end if;
  select * into p from public.profiles where id = me;
  insert into public.circle_members (circle_id, user_id, display_name, hospital, area, role)
  values (c.id, me, coalesce(p.full_name,''), coalesce(p.hospital,''), coalesce(p.area,''), 'member')
  on conflict (circle_id, user_id) do nothing;
  return c;
end $$;

revoke all on function public.create_circle(text) from public;
revoke all on function public.join_circle(text)   from public;
grant execute on function public.create_circle(text) to authenticated;
grant execute on function public.join_circle(text)   to authenticated;

-- ---------------------------------------------------------------------
-- 6. Follow-up closure fields on your own (private) records.
--    The app stores the closure inside each record's "data"; these columns
--    show it in Supabase's Table Editor for reports / export.
-- ---------------------------------------------------------------------
alter table public.treatments add column if not exists follow_up_status text
  generated always as (case when data->'closure' is not null then 'closed'
                            when public.safe_bool(data->>'done') then 'done'
                            when coalesce(data->>'next','') <> '' then 'pending' else null end) stored;
alter table public.treatments add column if not exists follow_up_closed_at text
  generated always as (data->'closure'->>'at') stored;
alter table public.treatments add column if not exists follow_up_closure_note text
  generated always as (data->'closure'->>'note') stored;

alter table public.ai_records add column if not exists follow_up_status text
  generated always as (case when data->'fuClosure' is not null then 'closed'
                            when public.safe_bool(data->>'nextDone') then 'done'
                            when coalesce(data->>'next','') <> '' then 'pending' else null end) stored;
alter table public.ai_records add column if not exists follow_up_closed_at text
  generated always as (data->'fuClosure'->>'at') stored;
alter table public.ai_records add column if not exists follow_up_closure_note text
  generated always as (data->'fuClosure'->>'note') stored;
alter table public.ai_records add column if not exists repeat_ai_closed_at text
  generated always as (data->'rClosure'->>'at') stored;
alter table public.ai_records add column if not exists repeat_ai_closure_note text
  generated always as (data->'rClosure'->>'note') stored;

-- Done. Private tables are unchanged and still visible only to their owner (auth.uid() = user_id).
