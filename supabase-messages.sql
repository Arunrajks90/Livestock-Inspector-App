-- =====================================================================
-- Livestock Inspector – Circle Messaging
--   Mode 1: Private 1-on-1 direct messages (sender + selected recipient ONLY)
--   Mode 2: Circle announcements (all members of that circle)
-- Run AFTER supabase-setup.sql and supabase-circles.sql, in
-- Supabase → SQL Editor → New query → Run. Safe to run again.
-- Private tables (farmers, animals, treatments, ai_records, feed_supplies,
-- profiles) are NOT changed: they stay locked to auth.uid() = user_id.
-- =====================================================================

create table if not exists public.circle_messages (
  id           uuid primary key default gen_random_uuid(),
  circle_id    uuid not null references public.inspector_circles(id) on delete cascade,
  sender_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  recipient_id uuid references auth.users(id) on delete cascade,   -- NULL only for announcements
  message_type text not null check (message_type in ('direct','announcement')),
  message_text text not null check (length(trim(message_text)) between 1 and 2000),
  is_read      boolean not null default false,                     -- used for direct messages (read by the recipient)
  created_at   timestamptz not null default now(),
  constraint circle_messages_mode_check check (
       (message_type = 'direct'       and recipient_id is not null and recipient_id <> sender_id)
    or (message_type = 'announcement' and recipient_id is null)
  )
);
create index if not exists circle_messages_direct_idx on public.circle_messages (recipient_id, sender_id, created_at) where message_type = 'direct';
create index if not exists circle_messages_circle_idx on public.circle_messages (circle_id, message_type, created_at);

alter table public.circle_messages enable row level security;

drop policy if exists "messages: read direct (sender or recipient only)" on public.circle_messages;
drop policy if exists "messages: read announcements (circle members)"     on public.circle_messages;
drop policy if exists "messages: send direct (to a member of the same circle)" on public.circle_messages;
drop policy if exists "messages: send announcement (circle members)"       on public.circle_messages;
drop policy if exists "messages: recipient marks direct message read"      on public.circle_messages;

-- Mode 1 – direct: ONLY the sender and the selected recipient, and both must belong to the circle.
create policy "messages: read direct (sender or recipient only)" on public.circle_messages
  for select to authenticated
  using (message_type = 'direct'
         and ((select auth.uid()) = sender_id or (select auth.uid()) = recipient_id)
         and public.is_circle_member(circle_id, sender_id)
         and public.is_circle_member(circle_id, recipient_id));

create policy "messages: send direct (to a member of the same circle)" on public.circle_messages
  for insert to authenticated
  with check (message_type = 'direct'
              and sender_id = (select auth.uid())
              and recipient_id is not null and recipient_id <> sender_id
              and is_read = false
              and public.is_circle_member(circle_id, sender_id)
              and public.is_circle_member(circle_id, recipient_id));

-- Mode 2 – announcement: every current member of that circle, and nobody else.
create policy "messages: read announcements (circle members)" on public.circle_messages
  for select to authenticated
  using (message_type = 'announcement' and public.is_circle_member(circle_id));

create policy "messages: send announcement (circle members)" on public.circle_messages
  for insert to authenticated
  with check (message_type = 'announcement'
              and sender_id = (select auth.uid())
              and recipient_id is null
              and is_read = false
              and public.is_circle_member(circle_id));

-- Read receipts: only the recipient of a direct message may mark it read.
create policy "messages: recipient marks direct message read" on public.circle_messages
  for update to authenticated
  using (message_type = 'direct' and recipient_id = (select auth.uid()))
  with check (message_type = 'direct' and recipient_id = (select auth.uid()));

-- …and nothing else about a message can ever be changed (no editing, no re-addressing).
create or replace function public.circle_message_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.circle_id is distinct from old.circle_id or new.sender_id is distinct from old.sender_id
     or new.recipient_id is distinct from old.recipient_id or new.message_type is distinct from old.message_type
     or new.message_text is distinct from old.message_text or new.created_at is distinct from old.created_at then
    raise exception 'Messages cannot be edited';
  end if;
  if old.is_read and not new.is_read then
    raise exception 'A read message cannot be marked unread';
  end if;
  return new;
end $$;
drop trigger if exists circle_message_guard on public.circle_messages;
create trigger circle_message_guard before update on public.circle_messages
  for each row execute function public.circle_message_guard();

-- no delete policy: messages are kept (removed automatically if the circle or the account is deleted)
grant select, insert, update on public.circle_messages to authenticated;

-- Live updates: add the table to Supabase Realtime (Realtime applies the same RLS rules,
-- so each inspector only receives messages they are allowed to read).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'circle_messages') then
    alter publication supabase_realtime add table public.circle_messages;
  end if;
end $$;

-- Done.
