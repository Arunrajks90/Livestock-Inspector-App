-- =====================================================================
-- Livestock Inspector – Supabase database setup
-- Run this whole script once in Supabase → SQL Editor → New query → Run.
-- It is safe to run again (it will not delete any data).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Helper functions (safe number / boolean conversion, updated_at)
-- ---------------------------------------------------------------------
create or replace function public.safe_num(t text) returns numeric
language plpgsql immutable as $$
begin
  return nullif(trim(t), '')::numeric;
exception when others then
  return null;
end $$;

create or replace function public.safe_int(t text) returns integer
language plpgsql immutable as $$
begin
  return nullif(trim(t), '')::integer;
exception when others then
  return null;
end $$;

create or replace function public.safe_bool(t text) returns boolean
language plpgsql immutable as $$
begin
  return coalesce(nullif(trim(t), '')::boolean, false);
exception when others then
  return false;
end $$;

create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 2. Inspector profiles (one row per login, created automatically at sign up)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  full_name     text not null default '',
  hospital      text not null default '',
  qualification text not null default '',
  age           integer,
  gender        text,
  phone         text unique,
  email         text,
  area          text not null default '',
  settings      jsonb not null default '{}'::jsonb,   -- AI target, message sign-off, sample-data flag
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. Record tables. Each row belongs to one inspector (user_id → auth.users).
--    "data" holds the full record exactly as the app uses it (payments,
--    reminders, weight checks …). The extra columns are filled automatically
--    from "data" so you can read, filter and export records in Supabase.
-- ---------------------------------------------------------------------
create table if not exists public.farmers (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id         text not null,
  data       jsonb not null,
  name       text generated always as (data->>'name') stored,
  phone      text generated always as (data->>'phone') stored,
  village    text generated always as (data->>'village') stored,
  is_sample  boolean generated always as (public.safe_bool(data->>'demo')) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

create table if not exists public.animals (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id         text not null,
  data       jsonb not null,
  farmer_id  text generated always as (data->>'cid') stored,
  species    text generated always as (data->>'species') stored,
  breed      text generated always as (data->>'breed') stored,
  gender     text generated always as (data->>'gender') stored,
  tag        text generated always as (data->>'tag') stored,
  status     text generated always as (coalesce(nullif(data->>'status', ''), 'active')) stored,
  is_sample  boolean generated always as (public.safe_bool(data->>'demo')) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

create table if not exists public.treatments (
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id             text not null,
  data           jsonb not null,
  animal_id      text generated always as (data->>'aid') stored,
  treated_on     text generated always as (data->>'date') stored,
  diagnosis      text generated always as (data->>'dx') stored,
  next_follow_up text generated always as (data->>'next') stored,
  amount         numeric generated always as (public.safe_num(data->>'amt')) stored,
  payment_status text generated always as (data->>'pst') stored,
  payment_mode   text generated always as (data->>'mode') stored,
  is_sample      boolean generated always as (public.safe_bool(data->>'demo')) stored,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  primary key (user_id, id)
);

-- AI records also hold the PD Check result, repeat-AI and pregnancy dates.
create table if not exists public.ai_records (
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id                text not null,
  data              jsonb not null,
  animal_id         text generated always as (data->>'aid') stored,
  ai_date           text generated always as (data->>'date') stored,
  pd_status         text generated always as (data->>'status') stored,     -- pending / confirmed / negative
  pd_date           text generated always as (data->>'pd') stored,
  repeat_ai_date    text generated always as (data->>'rDate') stored,
  expected_due      text generated always as (data->>'due') stored,
  amount            numeric generated always as (public.safe_num(data->>'amt')) stored,
  payment_status    text generated always as (data->>'pst') stored,
  pd_amount         numeric generated always as (public.safe_num(data->>'pdAmt')) stored,
  pd_payment_status text generated always as (data->>'pdPst') stored,
  is_sample         boolean generated always as (public.safe_bool(data->>'demo')) stored,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  primary key (user_id, id)
);

-- Feed supply is free of cost: no payment columns.
create table if not exists public.feed_supplies (
  user_id           uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id                text not null,
  data              jsonb not null,
  animal_id         text generated always as (data->>'aid') stored,
  supplied_on       text generated always as (data->>'date') stored,
  feed_type         text generated always as (data->>'feed') stored,
  weight_check_due  text generated always as (data->>'wDate') stored,
  weight_check_done boolean generated always as (public.safe_bool(data->>'wDone')) stored,
  is_sample         boolean generated always as (public.safe_bool(data->>'demo')) stored,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  primary key (user_id, id)
);

create index if not exists animals_farmer_idx    on public.animals       (user_id, farmer_id);
create index if not exists treatments_animal_idx on public.treatments    (user_id, animal_id);
create index if not exists ai_records_animal_idx on public.ai_records    (user_id, animal_id);
create index if not exists feed_animal_idx       on public.feed_supplies (user_id, animal_id);

-- ---------------------------------------------------------------------
-- 4. Row Level Security: each inspector can only see and change their own rows
-- ---------------------------------------------------------------------
alter table public.profiles enable row level security;

drop policy if exists "profiles: read own"   on public.profiles;
drop policy if exists "profiles: insert own" on public.profiles;
drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: read own"   on public.profiles for select to authenticated using ((select auth.uid()) = id);
create policy "profiles: insert own" on public.profiles for insert to authenticated with check ((select auth.uid()) = id);
create policy "profiles: update own" on public.profiles for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

grant select, insert, update on public.profiles to authenticated;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

do $$
declare t text;
begin
  foreach t in array array['farmers','animals','treatments','ai_records','feed_supplies'] loop
    execute format('alter table public.%I enable row level security', t);

    execute format('drop policy if exists "own rows: select" on public.%I', t);
    execute format('drop policy if exists "own rows: insert" on public.%I', t);
    execute format('drop policy if exists "own rows: update" on public.%I', t);
    execute format('drop policy if exists "own rows: delete" on public.%I', t);

    execute format('create policy "own rows: select" on public.%I for select to authenticated using ((select auth.uid()) = user_id)', t);
    execute format('create policy "own rows: insert" on public.%I for insert to authenticated with check ((select auth.uid()) = user_id)', t);
    execute format('create policy "own rows: update" on public.%I for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)', t);
    execute format('create policy "own rows: delete" on public.%I for delete to authenticated using ((select auth.uid()) = user_id)', t);

    execute format('grant select, insert, update, delete on public.%I to authenticated', t);

    execute format('drop trigger if exists %I on public.%I', t || '_touch', t);
    execute format('create trigger %I before update on public.%I for each row execute function public.touch_updated_at()', t || '_touch', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 5. Create the profile automatically when an inspector signs up
--    (works even when email confirmation is switched on)
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email, full_name, hospital, qualification, age, gender, phone, area)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    coalesce(new.raw_user_meta_data->>'hospital', ''),
    coalesce(new.raw_user_meta_data->>'qualification', ''),
    public.safe_int(new.raw_user_meta_data->>'age'),
    nullif(new.raw_user_meta_data->>'gender', ''),
    nullif(new.raw_user_meta_data->>'phone', ''),
    coalesce(new.raw_user_meta_data->>'area', '')
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- 6. Login with phone number: find the email for a registered phone,
--    and check whether a phone number is free at sign up.
-- ---------------------------------------------------------------------
create or replace function public.email_for_phone(p_phone text) returns text
language sql stable security definer set search_path = '' as $$
  select email from public.profiles
  where phone = right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10)
  limit 1
$$;

create or replace function public.phone_available(p_phone text) returns boolean
language sql stable security definer set search_path = '' as $$
  select not exists (
    select 1 from public.profiles
    where phone = right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10)
  )
$$;

revoke all on function public.email_for_phone(text) from public;
revoke all on function public.phone_available(text) from public;
grant execute on function public.email_for_phone(text) to anon, authenticated;
grant execute on function public.phone_available(text) to anon, authenticated;

-- Done. Tables: profiles, farmers, animals, treatments, ai_records, feed_supplies.
