-- =====================================================================================
-- Livestock Inspector · Animal Tag / Identification Photos  (run AFTER all earlier SQL files)
-- Order: setup → circles → messages → abortion → subscriptions → security-hardening
--        → support → vaccination → tag-photos (this file)
--
-- What it does
--  1. Creates the PRIVATE Storage bucket `animal-tag-photos` (max 1 MB per file, images only).
--  2. Storage RLS: an inspector can upload / view / replace / delete files ONLY inside their own
--     folder  <auth.uid()>/<animal id>/<file>.jpg .  Nobody else (other inspectors, circle members,
--     anonymous visitors, the admin) can open another inspector's photos.
--  3. Uploads follow the same plan rules as records (public.can_write_records) and a per-inspector
--     photo cap, so storage cannot be filled up through the API.
--  4. tag_photo_orphans(): lists the caller's files that no animal record points to any more
--     (replaced photos, deleted animals, interrupted uploads). The app deletes them through the
--     Storage API at login. (Supabase does not allow deleting Storage files with plain SQL.)
--  5. tag_photo_usage() for the inspector, admin_tag_photo_usage() (counts only) for the admin.
--
-- The animal row stores only a small reference in its jsonb:  data.photo = {p: path, kb, w, h, at}
-- No image data is ever stored in PostgreSQL tables.
-- Safe to run more than once.
-- =====================================================================================

-- 1) bucket -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('animal-tag-photos', 'animal-tag-photos', false, 1048576,
        array['image/jpeg', 'image/webp', 'image/png'])
on conflict (id) do update
  set public             = false,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- 2) helper: path must be  <own uid>/<animal id>/<file>.jpg  and the per-inspector cap not reached
create or replace function public.tag_photo_path_ok(p_name text)
returns boolean language sql stable security invoker set search_path = '' as $$
  select auth.uid() is not null
     and p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[A-Za-z0-9_-]{1,64}/[A-Za-z0-9_-]{1,40}\.(jpg|jpeg|webp|png)$'
     and split_part(p_name, '/', 1) = auth.uid()::text
$$;

-- counts the caller's own photos (security definer so the policy check does not recurse into RLS)
create or replace function public.tag_photo_quota_ok()
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null
     and (select count(*) from storage.objects o
           where o.bucket_id = 'animal-tag-photos'
             and split_part(o.name, '/', 1) = auth.uid()::text) < 3000
$$;

revoke all on function public.tag_photo_path_ok(text) from public, anon;
revoke all on function public.tag_photo_quota_ok()    from public, anon;
grant execute on function public.tag_photo_path_ok(text) to authenticated;
grant execute on function public.tag_photo_quota_ok()    to authenticated;

-- 3) Storage RLS policies (storage.objects already has RLS enabled in Supabase) ---------------
drop policy if exists "tag photos: view own"   on storage.objects;
drop policy if exists "tag photos: upload own" on storage.objects;
drop policy if exists "tag photos: update own" on storage.objects;
drop policy if exists "tag photos: delete own" on storage.objects;

create policy "tag photos: view own" on storage.objects
  for select to authenticated
  using (bucket_id = 'animal-tag-photos'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "tag photos: upload own" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'animal-tag-photos'
              and (storage.foldername(name))[1] = (select auth.uid())::text
              and public.tag_photo_path_ok(name)
              and public.can_write_records()
              and public.tag_photo_quota_ok());

create policy "tag photos: update own" on storage.objects
  for update to authenticated
  using (bucket_id = 'animal-tag-photos'
         and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'animal-tag-photos'
              and (storage.foldername(name))[1] = (select auth.uid())::text
              and public.tag_photo_path_ok(name)
              and public.can_write_records());

-- deleting own photos is always allowed (also after a plan expires) so clean-up never gets stuck
create policy "tag photos: delete own" on storage.objects
  for delete to authenticated
  using (bucket_id = 'animal-tag-photos'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

-- 4) orphan sweep: own files that no animal record references (older than 2 hours, so a photo
--    that was just uploaded but whose record is still syncing is never touched)
create index if not exists animals_photo_path_idx
  on public.animals (user_id, (data->'photo'->>'p'))
  where data ? 'photo';

create or replace function public.tag_photo_orphans()
returns setof text language sql stable security invoker set search_path = '' as $$
  select o.name
    from storage.objects o
   where o.bucket_id = 'animal-tag-photos'
     and split_part(o.name, '/', 1) = auth.uid()::text
     and o.created_at < now() - interval '2 hours'
     and not exists (select 1 from public.animals a
                      where a.user_id = auth.uid()
                        and a.data->'photo'->>'p' = o.name)
   order by o.created_at
   limit 500
$$;

-- 5) storage awareness ------------------------------------------------------------------------
create or replace function public.tag_photo_usage()
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
           'files', count(*),
           'bytes', coalesce(sum(coalesce((o.metadata->>'size')::bigint, 0)), 0))
    from storage.objects o
   where o.bucket_id = 'animal-tag-photos'
     and split_part(o.name, '/', 1) = auth.uid()::text
$$;

-- admin: totals and the five largest users — numbers only, never file names or images
create or replace function public.admin_tag_photo_usage()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  if not public.is_app_admin(auth.uid()) then
    raise exception 'Only the app owner can see storage usage';
  end if;
  with per as (
    select split_part(o.name, '/', 1) as uid_txt,
           count(*) as files,
           coalesce(sum(coalesce((o.metadata->>'size')::bigint, 0)), 0) as bytes
      from storage.objects o
     where o.bucket_id = 'animal-tag-photos'
     group by 1)
  select jsonb_build_object(
           'files', coalesce(sum(per.files), 0),
           'bytes', coalesce(sum(per.bytes), 0),
           'users', count(*),
           'top', coalesce((select jsonb_agg(t) from (
                     select coalesce(nullif(p.full_name, ''), p.email, 'inspector') as name,
                            per2.files, per2.bytes
                       from per per2
                       left join public.profiles p on p.id::text = per2.uid_txt
                      order by per2.bytes desc
                      limit 5) t), '[]'::jsonb))
    into r
    from per;
  return r;
end $$;

revoke all on function public.tag_photo_orphans()      from public, anon;
revoke all on function public.tag_photo_usage()        from public, anon;
revoke all on function public.admin_tag_photo_usage()  from public, anon;
grant execute on function public.tag_photo_orphans()     to authenticated;
grant execute on function public.tag_photo_usage()       to authenticated;
grant execute on function public.admin_tag_photo_usage() to authenticated;

-- =====================================================================================
-- Notes
-- • Size: the app shrinks each photo to ≤ 1024 px and usually 80–350 KB before upload.
--   Supabase Free plan = 1 GB Storage (≈ 4,000–10,000 tag photos); Pro = 100 GB.
--   Admin → Subscription Manager shows the running total.
-- • Deleting an inspector account (Authentication → Users) does NOT delete Storage files.
--   Before deleting a user, open Storage → animal-tag-photos and delete the folder named with
--   that user's id.
-- • Check:  select * from storage.buckets where id = 'animal-tag-photos';
--           select policyname from pg_policies where tablename = 'objects' and policyname like 'tag photos%';
-- =====================================================================================
