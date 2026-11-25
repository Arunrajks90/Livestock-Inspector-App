-- =====================================================================
-- Livestock Inspector – "Mark as Aborted" for confirmed pregnancies
-- Run AFTER supabase-setup.sql and supabase-circles.sql, in
-- Supabase → SQL Editor → New query → Run. Safe to run again.
-- The app keeps each AI / PD record in ai_records.data (private: auth.uid() = user_id).
-- These columns are filled automatically from that data so the abortion
-- status, date and notes are easy to read, filter and export in Supabase.
-- Nothing here changes who can see a record.
-- =====================================================================

-- pd_status already shows 'aborted' (it is generated from data->>'status').
alter table public.ai_records add column if not exists abortion_date text
  generated always as (data->>'abDate') stored;
alter table public.ai_records add column if not exists abortion_notes text
  generated always as (data->>'abNotes') stored;
alter table public.ai_records add column if not exists post_abortion_follow_up_date text
  generated always as (data->>'hcDate') stored;
alter table public.ai_records add column if not exists post_abortion_follow_up_done boolean
  generated always as (public.safe_bool(data->>'hcDone')) stored;

create index if not exists ai_records_aborted_idx on public.ai_records (user_id, abortion_date)
  where data->>'status' = 'aborted';

-- My Follow-Up Tracker view (private, security_invoker): now also lists
-- post-abortion follow-ups / heat checks. Calving rows only ever come from
-- CONFIRMED pregnancies, so aborted pregnancies never show calving follow-ups.
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

-- Done.
