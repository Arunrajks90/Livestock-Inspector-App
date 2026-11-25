-- =====================================================================
-- Livestock Inspector – Inspector Circles, Task Allotment / Handover,
-- and Follow-up Closure columns.
-- Run this AFTER supabase-setup.sql, in Supabase → SQL Editor → New query → Run.
-- Already ran an earlier version? Just run this whole file again: it adds the new
-- return-to-sender fields and updates the rules without touching existing data.
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
-- Return-to-sender workflow (added in v2; "add column if not exists" makes re-running safe)
alter table public.task_allotments add column if not exists closed_date        date;
alter table public.task_allotments add column if not exists returned_to_sender boolean not null default false;  -- closed by the assignee, back with the sender
alter table public.task_allotments add column if not exists follow_up_owner_id uuid references auth.users(id) on delete set null; -- always the original sender
alter table public.task_allotments add column if not exists follow_up_status   text;   -- null = waiting for the sender · scheduled · not_needed
alter table public.task_allotments add column if not exists follow_up_set_at   timestamptz;
alter table public.task_allotments add column if not exists closure_description text generated always as (closure_note) stored;
-- Decline workflow (added in v3): when the assignee declines, the task goes straight back to the sender's
-- Follow-Up Tracker as an open item on its ORIGINAL due date. The assignee keeps no follow-ups for it.
alter table public.task_allotments add column if not exists declined_at    timestamptz;
alter table public.task_allotments add column if not exists decline_reason text
  generated always as (case when status = 'declined' then response_note else null end) stored;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'task_allotments_follow_up_status_check') then
    alter table public.task_allotments add constraint task_allotments_follow_up_status_check
      check (follow_up_status is null or follow_up_status in ('scheduled','not_needed'));
  end if;
end $$;
-- NOTE: the next follow-up DATE is saved only in the sender's own private record
-- (treatments / ai_records), never in this shared row, so the assignee can never see it.

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
--   recipient (assignee): pending_acceptance → accepted / declined (optional reason);  accepted → closed (a description is REQUIRED)
--                         a declined task returns to the sender's Follow-Up Tracker on its original date.
--                         after the task is closed / declined / cancelled the assignee can change nothing more.
--   sender:    pending_acceptance → cancelled;  pending_acceptance / accepted → closed (handled elsewhere)
--   sender only: follow_up_status / follow_up_set_at, once the task is closed (the next follow-up belongs to the sender).
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
  -- the assignee's involvement ends once the task is finished
  if me is not null and me = old.to_user and old.status in ('declined','closed','cancelled') then
    raise exception 'This task is already % – no further changes by the assignee', old.status;
  end if;
  -- these are set by the system or by the original sender only
  if new.returned_to_sender is distinct from old.returned_to_sender
     or new.follow_up_owner_id is distinct from old.follow_up_owner_id
     or new.declined_at is distinct from old.declined_at then
    raise exception 'Return-to-sender fields are set automatically';
  end if;
  if new.follow_up_status is distinct from old.follow_up_status or new.follow_up_set_at is distinct from old.follow_up_set_at then
    if me is not null and me <> old.from_user then
      raise exception 'Only the original sender can set the next follow-up';
    end if;
    if new.status <> 'closed' then
      raise exception 'The next follow-up can be set only after the task is closed';
    end if;
    new.follow_up_set_at := coalesce(new.follow_up_set_at, now());
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
    if new.status = 'declined' then new.declined_at := now(); new.follow_up_owner_id := old.from_user; end if;
    if new.status = 'closed' then
      new.closed_at  := coalesce(new.closed_at, now());
      new.closed_by  := me;
      new.closed_date := coalesce(new.closed_date, (new.closed_at at time zone 'Asia/Kolkata')::date);
      new.follow_up_owner_id := old.from_user;            -- any further follow-up belongs to the sender
      if me = old.to_user then
        if length(trim(coalesce(new.closure_note, ''))) < 3 then
          raise exception 'A closure description is required to close an allotted task';
        end if;
        new.returned_to_sender := true;                   -- goes back to the sender to set the next follow-up
      end if;
    end if;
  elsif new.closed_date is distinct from old.closed_date or new.closure_note is distinct from old.closure_note then
    if old.status = 'closed' and (me is null or me <> old.from_user) then
      raise exception 'Closure details cannot be changed after closing';
    end if;
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

alter table public.treatments add column if not exists next_follow_up_owner text
  generated always as (case when coalesce(data->>'next','') <> '' then 'self' else null end) stored;
alter table public.treatments add column if not exists performed_by_colleague text
  generated always as (data->>'byOther') stored;
alter table public.ai_records add column if not exists next_follow_up text
  generated always as (data->>'next') stored;
alter table public.ai_records add column if not exists performed_by_colleague text
  generated always as (data->>'byOther') stored;

-- ---------------------------------------------------------------------
-- 7. My Follow-Up Tracker (read-only view, private to each inspector)
--    One row per open follow-up in YOUR records, including follow-ups you set
--    after a colleague closed an allotted task (returned_by / returned_note).
--    security_invoker = the normal row security applies: you only ever see your own rows.
-- ---------------------------------------------------------------------
create or replace view public.my_follow_up_tracker with (security_invoker = true) as
  select t.user_id, 'Treatment follow-up'::text as follow_up_type, t.id as record_id, t.data->>'aid' as animal_id,
         t.data->>'next' as next_follow_up_date, t.data->>'byOther' as performed_by_colleague,
         t.data->'fuFrom'->>'by' as returned_by, t.data->'fuFrom'->>'cd' as returned_closed_date, t.data->'fuFrom'->>'note' as returned_note
    from public.treatments t
   where coalesce(t.data->>'next','') <> '' and not public.safe_bool(t.data->>'done')
  union all
  select a.user_id, 'AI follow-up', a.id, a.data->>'aid', a.data->>'next', a.data->>'byOther',
         a.data->'fuFrom'->>'by', a.data->'fuFrom'->>'cd', a.data->'fuFrom'->>'note'
    from public.ai_records a
   where a.data->>'status' = 'pending' and coalesce(a.data->>'next','') <> '' and not public.safe_bool(a.data->>'nextDone')
  union all
  select a.user_id, 'PD check', a.id, a.data->>'aid', a.data->>'pd', a.data->>'byOther',
         a.data->'fuFrom'->>'by', a.data->'fuFrom'->>'cd', a.data->'fuFrom'->>'note'
    from public.ai_records a
   where a.data->>'status' = 'pending' and coalesce(a.data->>'pd','') <> '' and not public.safe_bool(a.data->>'pdClosed')
  union all
  select a.user_id, 'Repeat AI', a.id, a.data->>'aid', a.data->>'rDate', a.data->>'byOther', null, null, null
    from public.ai_records a
   where a.data->>'status' = 'negative' and coalesce(a.data->>'rDate','') <> '' and not public.safe_bool(a.data->>'rDone')
  union all
  select a.user_id, 'Pregnancy follow-up', a.id, a.data->>'aid', a.data->>'fnext', a.data->>'byOther', null, null, null
    from public.ai_records a
   where a.data->>'status' = 'confirmed' and coalesce(a.data->>'fnext','') <> '' and not public.safe_bool(a.data->>'fDone')
  union all
  select a.user_id, 'Post-abortion follow-up / heat check', a.id, a.data->>'aid', a.data->>'hcDate', a.data->>'byOther',
         a.data->'fuFrom'->>'by', a.data->'fuFrom'->>'cd', a.data->'fuFrom'->>'note'
    from public.ai_records a
   where a.data->>'status' = 'aborted' and coalesce(a.data->>'hcDate','') <> '' and not public.safe_bool(a.data->>'hcDone')
  union all
  select f.user_id, '3-month weight check', f.id, f.data->>'aid', f.data->>'wDate', null, null, null, null
    from public.feed_supplies f
   where coalesce(f.data->>'wDate','') <> '' and not public.safe_bool(f.data->>'wDone');
revoke all on public.my_follow_up_tracker from anon;
grant select on public.my_follow_up_tracker to authenticated;

-- Done. Private tables are unchanged and still visible only to their owner (auth.uid() = user_id).
