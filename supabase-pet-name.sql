-- =====================================================================================
-- Livestock Inspector · Optional Pet Name + Registration date (run after supabase-tag-photos.sql)
--
-- The app keeps each animal in the private jsonb column animals.data, so the new optional values
-- (data.pet = pet name, data.reg = registration date) are saved WITHOUT any schema change and
-- are already protected by the existing RLS (auth.uid() = user_id).
--
-- This script only adds read-only generated columns so you can search / report on them in the
-- Supabase Table Editor. Running it is optional; the app works the same either way.
-- No new policies are needed: generated columns live in the same row and follow the same RLS.
-- The Registration Card image is created on the phone and is NOT uploaded or stored anywhere.
-- Safe to run more than once.
-- =====================================================================================

alter table public.animals
  add column if not exists pet_name text
  generated always as (nullif(btrim(data->>'pet'), '')) stored;

alter table public.animals
  add column if not exists registered_on text
  generated always as (nullif(data->>'reg', '')) stored;

create index if not exists animals_pet_name_idx
  on public.animals (user_id, lower(pet_name))
  where pet_name is not null;

-- keep pet names short and clean (the app limits them to 40 characters as well)
alter table public.animals drop constraint if exists animals_pet_name_len;
alter table public.animals
  add constraint animals_pet_name_len check (pet_name is null or char_length(pet_name) <= 60);

-- Reminder (nothing to change): RLS on public.animals and the Storage policies of the private
-- bucket `animal-tag-photos` (own folder only) from earlier scripts stay exactly as they are.
-- Check:  select pet_name, tag, registered_on from public.animals limit 5;
