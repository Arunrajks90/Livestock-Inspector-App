-- =====================================================================
--  Livestock Inspector app — ₹99/month subscription, trial limits and
--  admin approval.  Run ONCE in Supabase → SQL Editor, AFTER:
--     1. supabase-setup.sql   2. supabase-circles.sql
--     3. supabase-messages.sql   4. supabase-abortion.sql
--  Safe to run again (idempotent).  Nothing here deletes any record.
--
--  Plans
--    trial   : free, no time limit. Up to 5 farmers and 5 animals, no
--              Inspector Circle / task allotment / circle chat,
--              short activity log.
--    active  : Pro, ₹99 for 30 days. Everything unlocked.
--    expired : Pro period ended or was revoked. All data stays readable;
--              adding / editing / deleting records is blocked until renewal.
--
--  Security
--    * Inspectors can READ only their own subscription and payments.
--    * Inspectors cannot insert / update / delete subscription rows.
--      The only thing they can do is submit a UPI reference ID
--      (request_subscription), which creates a "pending" request.
--    * Only users listed in public.app_admins (you) can approve, extend
--      or revoke — enforced inside the database, not only in the app.
--    * The plan rules are ALSO enforced by the database (row security
--      and triggers), so they cannot be bypassed by calling the API.
--    * A Razorpay webhook (Edge Function with the service_role key) can
--      call apply_provider_payment() later; it is not callable by users.
--
--  LAST STEP (section 10): put YOUR login email in the admin insert.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. App owners / admins (rows are added only from the SQL Editor)
-- ---------------------------------------------------------------------
create table if not exists public.app_admins (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.app_admins enable row level security;
drop policy if exists "admins: read own flag" on public.app_admins;
create policy "admins: read own flag" on public.app_admins
  for select to authenticated using (user_id = (select auth.uid()));
revoke insert, update, delete on public.app_admins from anon, authenticated;

create or replace function public.is_app_admin(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = '' as $$
  select p_user is not null and exists (select 1 from public.app_admins a where a.user_id = p_user)
$$;


-- ---------------------------------------------------------------------
-- 2. Payment settings shown in the Upgrade screen (single row).
--    Everyone signed in can read it; only admins can change it.
--    You set your UPI ID, payee name and QR image from the app's
--    Admin → Payment settings screen.
-- ---------------------------------------------------------------------
create table if not exists public.app_settings (
  id          integer primary key default 1 check (id = 1),
  upi_id      text not null default '',
  payee_name  text not null default '',
  upi_qr      text not null default '',          -- image as a data: URL (uploaded from the admin screen)
  plan_price  integer not null default 99  check (plan_price between 1 and 100000),
  plan_days   integer not null default 30  check (plan_days between 1 and 366),
  trial_limit integer not null default 5   check (trial_limit between 0 and 1000),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id) on delete set null
);
insert into public.app_settings (id) values (1) on conflict (id) do nothing;
alter table public.app_settings enable row level security;
drop policy if exists "settings: read (signed in)" on public.app_settings;
drop policy if exists "settings: admin update"    on public.app_settings;
create policy "settings: read (signed in)" on public.app_settings
  for select to authenticated using (true);
create policy "settings: admin update" on public.app_settings
  for update to authenticated using ((select public.is_app_admin())) with check ((select public.is_app_admin()));
revoke insert, delete on public.app_settings from anon, authenticated;
alter table public.app_settings drop constraint if exists app_settings_qr_size;
alter table public.app_settings add constraint app_settings_qr_size check (length(upi_qr) <= 400000);

create or replace function public.app_settings_touch() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now(); new.updated_by := auth.uid();
  new.id := 1;
  -- the price, period and trial limit are changed only from the SQL Editor
  if auth.uid() is not null then
    new.plan_price := old.plan_price; new.plan_days := old.plan_days; new.trial_limit := old.trial_limit;
  end if;
  return new;
end $$;
drop trigger if exists app_settings_touch on public.app_settings;
create trigger app_settings_touch before update on public.app_settings
  for each row execute function public.app_settings_touch();


-- ---------------------------------------------------------------------
-- 3. One subscription row per inspector
--    (fields are ready for a Razorpay webhook: last_payment_provider,
--     last_provider_payment_id, subscription_end)
-- ---------------------------------------------------------------------
create table if not exists public.subscriptions (
  user_id                  uuid primary key references auth.users(id) on delete cascade,
  subscription_status      text not null default 'trial'
                           check (subscription_status in ('trial','active','expired')),
  plan_price               integer not null default 99 check (plan_price >= 0),
  currency                 text not null default 'INR',
  subscription_start       timestamptz,
  subscription_end         timestamptz,
  trial_started_at         timestamptz not null default now(),
  upi_ref_id               text,              -- latest UPI transaction / reference ID submitted
  request_status           text not null default 'none'
                           check (request_status in ('none','pending','approved','rejected')),
  requested_at             timestamptz,
  review_note              text,
  last_payment_provider    text,              -- 'upi_manual' | 'razorpay'
  last_provider_payment_id text,
  activated_by             uuid references auth.users(id) on delete set null,
  activated_at             timestamptz,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
create index if not exists subscriptions_status_idx  on public.subscriptions (subscription_status, subscription_end);
create index if not exists subscriptions_request_idx on public.subscriptions (request_status) where request_status = 'pending';

alter table public.subscriptions enable row level security;
drop policy if exists "subscriptions: read own"   on public.subscriptions;
drop policy if exists "subscriptions: admin read" on public.subscriptions;
create policy "subscriptions: read own" on public.subscriptions
  for select to authenticated using (user_id = (select auth.uid()));
create policy "subscriptions: admin read" on public.subscriptions
  for select to authenticated using ((select public.is_app_admin()));
-- no insert / update / delete policies: users can never self-activate.
revoke insert, update, delete on public.subscriptions from anon, authenticated;

drop trigger if exists subscriptions_touch on public.subscriptions;
create trigger subscriptions_touch before update on public.subscriptions
  for each row execute function public.touch_updated_at();


-- ---------------------------------------------------------------------
-- 4. Payment history (manual UPI requests now, Razorpay later)
-- ---------------------------------------------------------------------
create table if not exists public.subscription_payments (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users(id) on delete cascade,
  provider            text not null default 'upi_manual' check (provider in ('upi_manual','razorpay','other')),
  upi_ref_id          text,                 -- UTR / reference entered by the inspector
  provider_payment_id text,                 -- e.g. Razorpay pay_XXXX
  provider_order_id   text,
  amount              integer not null default 99 check (amount >= 0),
  currency            text not null default 'INR',
  days                integer not null default 30 check (days between 1 and 366),
  status              text not null default 'pending' check (status in ('pending','approved','rejected')),
  submitted_at        timestamptz not null default now(),
  reviewed_at         timestamptz,
  reviewed_by         uuid references auth.users(id) on delete set null,
  review_note         text,
  period_start        timestamptz,
  period_end          timestamptz
);
create unique index if not exists subscription_payments_ref_uq
  on public.subscription_payments (upper(upi_ref_id)) where upi_ref_id is not null;
create unique index if not exists subscription_payments_provider_uq
  on public.subscription_payments (provider, provider_payment_id) where provider_payment_id is not null;
create unique index if not exists subscription_payments_one_pending
  on public.subscription_payments (user_id) where status = 'pending';
create index if not exists subscription_payments_user_idx on public.subscription_payments (user_id, submitted_at desc);

alter table public.subscription_payments enable row level security;
drop policy if exists "payments: read own"   on public.subscription_payments;
drop policy if exists "payments: admin read" on public.subscription_payments;
create policy "payments: read own" on public.subscription_payments
  for select to authenticated using (user_id = (select auth.uid()));
create policy "payments: admin read" on public.subscription_payments
  for select to authenticated using ((select public.is_app_admin()));
revoke insert, update, delete on public.subscription_payments from anon, authenticated;


-- ---------------------------------------------------------------------
-- 5. Every inspector gets a trial row (new sign-ups + existing users)
-- ---------------------------------------------------------------------
create or replace function public.handle_new_subscription() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.subscriptions (user_id, plan_price)
  values (new.id, coalesce((select plan_price from public.app_settings where id = 1), 99))
  on conflict (user_id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created_subscription on auth.users;
create trigger on_auth_user_created_subscription after insert on auth.users
  for each row execute function public.handle_new_subscription();

insert into public.subscriptions (user_id)
select id from auth.users on conflict (user_id) do nothing;


-- ---------------------------------------------------------------------
-- 6. Plan checks used by row security and triggers
-- ---------------------------------------------------------------------
-- Pro = admin, or active with an end date in the future
create or replace function public.has_pro(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = '' as $$
  select p_user is not null and (
    public.is_app_admin(p_user)
    or exists (select 1 from public.subscriptions s
               where s.user_id = p_user and s.subscription_status = 'active'
                 and s.subscription_end > now()))
$$;

-- May add / edit / delete records? (trial and active: yes; expired: no)
create or replace function public.can_write_records(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = '' as $$
  select p_user is not null and (
    public.is_app_admin(p_user)
    or not exists (select 1 from public.subscriptions s
                   where s.user_id = p_user
                     and (s.subscription_status = 'expired'
                          or (s.subscription_status = 'active' and coalesce(s.subscription_end, now()) <= now()))))
$$;

-- Trial limit for farmers / animals. Editing an existing row is always fine.
create or replace function public.trial_row_ok(p_table text, p_id text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare me uuid := auth.uid(); lim integer; n integer;
begin
  if me is null then return false; end if;
  if public.has_pro(me) then return true; end if;
  select trial_limit into lim from public.app_settings where id = 1;
  lim := coalesce(lim, 5);
  if p_table = 'farmers' then
    if exists (select 1 from public.farmers where user_id = me and id = p_id) then return true; end if;
    select count(*) into n from public.farmers where user_id = me;
  elsif p_table = 'animals' then
    if exists (select 1 from public.animals where user_id = me and id = p_id) then return true; end if;
    select count(*) into n from public.animals where user_id = me;
  else
    return true;
  end if;
  return n < lim;
end $$;

revoke all on function public.has_pro(uuid)             from public, anon;
revoke all on function public.can_write_records(uuid)   from public, anon;
revoke all on function public.trial_row_ok(text, text)  from public, anon;
revoke all on function public.is_app_admin(uuid)        from public, anon;
grant execute on function public.has_pro(uuid)            to authenticated;
grant execute on function public.can_write_records(uuid)  to authenticated;
grant execute on function public.trial_row_ok(text, text) to authenticated;
grant execute on function public.is_app_admin(uuid)       to authenticated;

-- Restrictive policies are ADDED to the existing "auth.uid() = user_id"
-- policies (both must pass). Reading is never blocked, so an expired
-- inspector still sees every record.
do $$
declare t text;
begin
  foreach t in array array['farmers','animals','treatments','ai_records','feed_supplies'] loop
    execute format('drop policy if exists "plan: insert needs trial or active" on public.%I', t);
    execute format('drop policy if exists "plan: update needs trial or active" on public.%I', t);
    execute format('drop policy if exists "plan: delete needs trial or active" on public.%I', t);
    execute format('create policy "plan: insert needs trial or active" on public.%I as restrictive for insert to authenticated with check ((select public.can_write_records()))', t);
    execute format('create policy "plan: update needs trial or active" on public.%I as restrictive for update to authenticated using ((select public.can_write_records())) with check ((select public.can_write_records()))', t);
    execute format('create policy "plan: delete needs trial or active" on public.%I as restrictive for delete to authenticated using ((select public.can_write_records()))', t);
  end loop;
  foreach t in array array['farmers','animals'] loop
    execute format('drop policy if exists "plan: trial record limit" on public.%I', t);
    execute format('create policy "plan: trial record limit" on public.%I as restrictive for insert to authenticated with check (public.trial_row_ok(%L, id))', t, t);
  end loop;
end $$;

-- Inspector Circle, task allotment and circle chat are Pro features.
-- (Leaving a circle and reading old items are still allowed.)
create or replace function public.require_pro() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then return new; end if;            -- SQL Editor / service role
  if not public.has_pro(auth.uid()) then
    raise exception 'PRO_REQUIRED: Inspector Circle, task allotment and circle chat need an active ₹99/month subscription'
      using errcode = 'P0001';
  end if;
  return new;
end $$;

drop trigger if exists require_pro_circle_create on public.inspector_circles;
create trigger require_pro_circle_create before insert on public.inspector_circles
  for each row execute function public.require_pro();
drop trigger if exists require_pro_circle_join on public.circle_members;
create trigger require_pro_circle_join before insert on public.circle_members
  for each row execute function public.require_pro();
drop trigger if exists require_pro_allot on public.task_allotments;
create trigger require_pro_allot before insert or update on public.task_allotments
  for each row execute function public.require_pro();
drop trigger if exists require_pro_message on public.circle_messages;
create trigger require_pro_message before insert on public.circle_messages
  for each row execute function public.require_pro();


-- ---------------------------------------------------------------------
-- 7. Inspector-side functions
-- ---------------------------------------------------------------------
-- Called by the app on every login / load: creates the trial row if
-- missing, turns an ended Pro period into "expired", returns the state.
create or replace function public.my_subscription() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); s public.subscriptions; cfg public.app_settings; adm boolean;
begin
  if me is null then raise exception 'Not signed in'; end if;
  insert into public.subscriptions (user_id) values (me) on conflict (user_id) do nothing;
  update public.subscriptions
     set subscription_status = 'expired'
   where user_id = me and subscription_status = 'active'
     and coalesce(subscription_end, now()) <= now();
  select * into s   from public.subscriptions where user_id = me;
  select * into cfg from public.app_settings  where id = 1;
  adm := public.is_app_admin(me);
  return jsonb_build_object(
    'status',             s.subscription_status,
    'plan_price',         coalesce(cfg.plan_price, s.plan_price, 99),
    'plan_days',          coalesce(cfg.plan_days, 30),
    'trial_limit',        coalesce(cfg.trial_limit, 5),
    'subscription_start', s.subscription_start,
    'subscription_end',   s.subscription_end,
    'days_left',          case when s.subscription_status = 'active'
                               then greatest(0, ceil(extract(epoch from (s.subscription_end - now())) / 86400))::int
                               else 0 end,
    'upi_ref_id',         s.upi_ref_id,
    'request_status',     s.request_status,
    'requested_at',       s.requested_at,
    'review_note',        s.review_note,
    'is_admin',           adm,
    'upi_id',             coalesce(cfg.upi_id, ''),
    'payee_name',         coalesce(cfg.payee_name, ''),
    'has_qr',             coalesce(length(cfg.upi_qr), 0) > 0,
    'server_time',        now());
end $$;

-- Inspector submits the UPI transaction / reference ID after paying.
-- Creates (or updates) ONE pending request. Does NOT activate anything.
create or replace function public.request_subscription(p_upi_ref text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
        ref text := upper(regexp_replace(coalesce(p_upi_ref, ''), '[\s-]', '', 'g'));
        pid uuid; cfg public.app_settings;
begin
  if me is null then raise exception 'Not signed in'; end if;
  if ref !~ '^[A-Z0-9]{6,35}$' then
    raise exception 'Enter the UPI transaction / reference ID (UTR) shown in your UPI app — 6 to 35 letters or digits';
  end if;
  select * into cfg from public.app_settings where id = 1;
  insert into public.subscriptions (user_id) values (me) on conflict (user_id) do nothing;
  if exists (select 1 from public.subscription_payments p
             where upper(p.upi_ref_id) = ref and not (p.user_id = me and p.status = 'pending')) then
    raise exception 'This UPI reference ID has already been submitted';
  end if;
  begin
    update public.subscription_payments
       set upi_ref_id = ref, submitted_at = now()
     where user_id = me and status = 'pending'
     returning id into pid;
    if pid is null then
      insert into public.subscription_payments (user_id, provider, upi_ref_id, amount, days)
      values (me, 'upi_manual', ref, coalesce(cfg.plan_price, 99), coalesce(cfg.plan_days, 30))
      returning id into pid;
    end if;
  exception when unique_violation then
    raise exception 'This UPI reference ID has already been submitted';
  end;
  update public.subscriptions
     set upi_ref_id = ref, request_status = 'pending', requested_at = now(), review_note = null
   where user_id = me;
  return public.my_subscription();
end $$;

revoke all on function public.my_subscription()           from public, anon;
revoke all on function public.request_subscription(text)  from public, anon;
grant execute on function public.my_subscription()          to authenticated;
grant execute on function public.request_subscription(text) to authenticated;


-- ---------------------------------------------------------------------
-- 8. Admin functions (refuse to run for anyone who is not an admin)
-- ---------------------------------------------------------------------
-- internal: add p_days to a subscription (extends from the current end
-- if still running, otherwise starts now). Not callable by users.
create or replace function public._extend_subscription(
  p_user uuid, p_days integer, p_provider text, p_provider_payment_id text, p_actor uuid,
  out period_start timestamptz, out period_end timestamptz)
language plpgsql security definer set search_path = '' as $$
declare s public.subscriptions; running boolean;
begin
  if p_days is null or p_days < 1 or p_days > 366 then raise exception 'Days must be between 1 and 366'; end if;
  insert into public.subscriptions (user_id) values (p_user) on conflict (user_id) do nothing;
  select * into s from public.subscriptions where user_id = p_user for update;
  running := s.subscription_status = 'active' and s.subscription_end > now();
  period_start := case when running then s.subscription_end else now() end;
  period_end   := period_start + make_interval(days => p_days);
  update public.subscriptions set
    subscription_status      = 'active',
    subscription_start       = case when running then coalesce(s.subscription_start, now()) else now() end,
    subscription_end         = period_end,
    last_payment_provider    = coalesce(p_provider, s.last_payment_provider),
    last_provider_payment_id = coalesce(p_provider_payment_id, s.last_provider_payment_id),
    activated_by             = p_actor,
    activated_at             = now()
  where user_id = p_user;
end $$;
revoke all on function public._extend_subscription(uuid, integer, text, text, uuid) from public, anon, authenticated;

-- Approve a pending UPI request (p_payment_id) or simply extend by p_days.
create or replace function public.admin_activate(p_user uuid, p_days integer default 30, p_payment_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); pay public.subscription_payments; r record;
begin
  if not public.is_app_admin(me) then raise exception 'Admin only'; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'Inspector not found'; end if;
  if p_payment_id is not null then
    select * into pay from public.subscription_payments where id = p_payment_id and user_id = p_user for update;
    if pay.id is null or pay.status <> 'pending' then raise exception 'This payment request was not found or is already reviewed'; end if;
  end if;
  select * into r from public._extend_subscription(p_user, p_days,
            case when p_payment_id is not null then 'upi_manual' else null end, null, me);
  if p_payment_id is not null then
    update public.subscription_payments
       set status = 'approved', reviewed_at = now(), reviewed_by = me, days = p_days,
           period_start = r.period_start, period_end = r.period_end
     where id = p_payment_id;
    update public.subscriptions set request_status = 'approved', review_note = null where user_id = p_user;
  end if;
  return jsonb_build_object('user_id', p_user, 'subscription_end', r.period_end);
end $$;

-- Reject a pending UPI request (wrong / unpaid reference ID)
create or replace function public.admin_reject_payment(p_payment_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); pay public.subscription_payments;
begin
  if not public.is_app_admin(me) then raise exception 'Admin only'; end if;
  select * into pay from public.subscription_payments where id = p_payment_id for update;
  if pay.id is null or pay.status <> 'pending' then raise exception 'This payment request was not found or is already reviewed'; end if;
  update public.subscription_payments
     set status = 'rejected', reviewed_at = now(), reviewed_by = me, review_note = nullif(trim(coalesce(p_note,'')), '')
   where id = p_payment_id;
  update public.subscriptions
     set request_status = 'rejected', review_note = nullif(trim(coalesce(p_note,'')), '')
   where user_id = pay.user_id and request_status = 'pending';
end $$;

-- Revoke Pro now. Records are NOT touched; the inspector becomes "expired".
create or replace function public.admin_revoke(p_user uuid, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid();
begin
  if not public.is_app_admin(me) then raise exception 'Admin only'; end if;
  update public.subscriptions
     set subscription_status = 'expired',
         subscription_end    = least(coalesce(subscription_end, now()), now()),
         review_note         = nullif(trim(coalesce(p_note,'')), ''),
         activated_by        = me
   where user_id = p_user;
  if not found then raise exception 'Inspector not found'; end if;
end $$;

-- Overview list for the admin screen: who is on which plan + pending
-- requests. Shows contact details only — never clinical or payment records.
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
  select u.id, coalesce(p.full_name, ''), coalesce(p.email, u.email::text), p.phone, p.hospital, p.area,
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

revoke all on function public.admin_activate(uuid, integer, uuid) from public, anon;
revoke all on function public.admin_reject_payment(uuid, text)    from public, anon;
revoke all on function public.admin_revoke(uuid, text)            from public, anon;
revoke all on function public.admin_overview()                    from public, anon;
grant execute on function public.admin_activate(uuid, integer, uuid) to authenticated;
grant execute on function public.admin_reject_payment(uuid, text)    to authenticated;
grant execute on function public.admin_revoke(uuid, text)            to authenticated;
grant execute on function public.admin_overview()                    to authenticated;


-- ---------------------------------------------------------------------
-- 9. Ready for automatic checkout later (Razorpay webhook).
--    Call from a Supabase Edge Function that verifies the Razorpay
--    signature and uses the service_role key:
--      select public.apply_provider_payment('<user uuid>', 'razorpay',
--             'pay_XXXX', 'order_XXXX', 99, 30);
--    Idempotent: the same payment id is applied only once.
-- ---------------------------------------------------------------------
create or replace function public.apply_provider_payment(
  p_user uuid, p_provider text, p_payment_id text, p_order_id text default null,
  p_amount integer default 99, p_days integer default 30)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare pid uuid; r record;
begin
  if p_provider not in ('razorpay','other') then raise exception 'Unknown provider'; end if;
  if coalesce(p_payment_id, '') = '' then raise exception 'Payment id is required'; end if;
  insert into public.subscription_payments (user_id, provider, provider_payment_id, provider_order_id, amount, days, status, reviewed_at)
  values (p_user, p_provider, p_payment_id, p_order_id, p_amount, p_days, 'approved', now())
  on conflict do nothing
  returning id into pid;
  if pid is null then return jsonb_build_object('applied', false, 'reason', 'duplicate'); end if;
  select * into r from public._extend_subscription(p_user, p_days, p_provider, p_payment_id, null);
  update public.subscription_payments set period_start = r.period_start, period_end = r.period_end where id = pid;
  update public.subscriptions set request_status = 'approved' where user_id = p_user and request_status = 'pending';
  return jsonb_build_object('applied', true, 'subscription_end', r.period_end);
end $$;
revoke all on function public.apply_provider_payment(uuid, text, text, text, integer, integer) from public, anon, authenticated;
grant execute on function public.apply_provider_payment(uuid, text, text, text, integer, integer) to service_role;


-- ---------------------------------------------------------------------
-- 10. MAKE YOURSELF THE ADMIN
--     Replace owner@example.com with the email you log in with,
--     then run this statement (it does nothing if the email is wrong).
-- ---------------------------------------------------------------------
insert into public.app_admins (user_id)
select id from auth.users where lower(email) = lower('owner@example.com')
on conflict (user_id) do nothing;

-- Check:  select u.email from public.app_admins a join auth.users u on u.id = a.user_id;
