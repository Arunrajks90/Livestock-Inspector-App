-- =====================================================================
--  Livestock Inspector app — VACCINATION module (replaces Treatment)
--  Run ONCE in Supabase → SQL Editor, AFTER the other seven files:
--    setup → circles → messages → abortion → subscriptions
--    → security-hardening → support → THIS FILE
--  Safe to run again. No record is deleted or changed.
--
--  How vaccinations are stored
--    Vaccination entries are saved in the existing private `treatments`
--    table (each row = one vaccination, in the `data` column). Keeping the
--    same table means every existing protection keeps working unchanged:
--    row security (auth.uid() = user_id), the ₹99 plan rules (expired =
--    read-only), sync, follow-ups and circle task links. Earlier treatment
--    records stay as they were and are shown as "earlier record".
--
--  This file adds:
--    1. readable vaccine columns on `treatments`
--       (record_type, vaccine_name, vaccine_batch, vaccine_expiry, ...)
--    2. a `vaccinations` view — your vaccination register, private per
--       inspector (it uses the caller's own row security)
--    3. "vaccination" / "vaccination_followup" circle task types
--    4. Follow-Up Tracker rows labelled "Vaccination follow-up"
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Vaccine columns (filled automatically from each record)
-- ---------------------------------------------------------------------
alter table public.treatments add column if not exists record_type text
  generated always as (case when coalesce(data->>'vac', '') <> '' or data ? 'visit' or data ? 'byOther'
                            then 'vaccination' else 'treatment' end) stored;
alter table public.treatments add column if not exists vaccine_name   text generated always as (data->>'vac')   stored;
alter table public.treatments add column if not exists vaccine_batch  text generated always as (data->>'batch') stored;
alter table public.treatments add column if not exists vaccine_expiry text generated always as (data->>'exp')   stored;
alter table public.treatments add column if not exists vaccine_notes  text generated always as (data->>'notes') stored;

create index if not exists treatments_vaccine_idx on public.treatments (user_id, vaccine_name, treated_on)
  where record_type = 'vaccination';
create index if not exists treatments_batch_idx on public.treatments (user_id, vaccine_batch)
  where coalesce(vaccine_batch, '') <> '';


-- ---------------------------------------------------------------------
-- 2. Vaccination register (private: security_invoker = the table's own
--    row security, so every inspector sees only their own entries)
-- ---------------------------------------------------------------------
create or replace view public.vaccinations with (security_invoker = true) as
select t.user_id,
       t.id,
       t.animal_id,
       t.treated_on                                        as vaccination_date,
       t.vaccine_name,
       t.vaccine_batch                                     as batch_number,
       t.vaccine_expiry                                    as expiry_date,
       (coalesce(t.vaccine_expiry, '') <> '' and t.vaccine_expiry < t.treated_on) as expired_when_used,
       t.vaccine_notes                                     as notes,
       t.next_follow_up                                    as follow_up_date,
       public.safe_bool(t.data->>'done')                   as follow_up_done,
       t.data->>'byOther'                                  as done_by_colleague,
       t.amount,
       t.payment_status,
       t.payment_mode,
       t.created_at,
       t.updated_at
from public.treatments t
where t.record_type = 'vaccination' and coalesce(t.vaccine_name, '') <> '';
revoke all on public.vaccinations from anon, public;
grant select on public.vaccinations to authenticated;


-- ---------------------------------------------------------------------
-- 3. Circle task types: vaccination + vaccination follow-up
--    (the earlier treatment types stay valid for existing tasks)
-- ---------------------------------------------------------------------
alter table public.task_allotments drop constraint if exists task_allotments_task_type_check;
alter table public.task_allotments add constraint task_allotments_task_type_check
  check (task_type in ('vaccination','vaccination_followup','ai','ai_followup','treatment','treatment_followup'));


-- ---------------------------------------------------------------------
-- 4. My Follow-Up Tracker: vaccination rows labelled as such
--    (same columns as before; all other rows unchanged)
-- ---------------------------------------------------------------------
create or replace view public.my_follow_up_tracker with (security_invoker = true) as
  select t.user_id,
         (case when t.record_type = 'vaccination' then 'Vaccination follow-up' else 'Treatment follow-up' end)::text as follow_up_type,
         t.id as record_id, t.data->>'aid' as animal_id,
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
revoke all on public.my_follow_up_tracker from anon, public;
grant select on public.my_follow_up_tracker to authenticated;

-- Checks:
--   select * from public.vaccinations order by vaccination_date desc;   -- your own register
--   select vaccine_name, count(*) from public.vaccinations group by 1;
