-- ============================================================
-- Phase 7A: Member profile database foundation
-- ============================================================
-- Backend only — no profile UI in this phase.
--
-- Extends public.profiles with an opaque public_id, bio, avatar_path,
-- an optional member-entered recovery_date and its visibility, and
-- profile_updated_at; adds a safe profile read model, author_public_id
-- on the two Community public views, member profile RPCs, an
-- admin-only profile moderation RPC, and the avatars storage bucket.
--
-- Privacy rules this migration enforces:
--   - The auth.users id and email never appear in any public view.
--     Members are identified publicly only by profiles.public_id, a
--     separate random UUID with no relationship to the auth id.
--   - recovery_date is entered by the member only. Nothing here reads
--     or copies the on-device Recovery Counter, which still never
--     reaches Supabase.
--   - recovery_date defaults to 'private' visibility: shown only to the
--     owner (get_my_profile) and to admins (base-table read). 'members'
--     shows it to signed-in viewers only; 'public' to everyone.
--   - community_member_profiles_public lists only members who have
--     published Community content (plus the viewer's own row), so it
--     can't be used as a directory of every account.
--
-- Transition rule: the existing direct UPDATE privilege on
-- profiles(display_name, notification_prefs) is deliberately KEPT in
-- 7A. 7B moves profile editing to update_my_profile(); the direct
-- privilege is revoked only after that path is live and verified.
-- ============================================================


-- ---------- profiles: new columns ----------

alter table public.profiles
  add column public_id uuid not null default gen_random_uuid(),
  add column bio text,
  add column avatar_path text,
  add column recovery_date date,
  add column recovery_visibility text not null default 'private',
  add column profile_updated_at timestamptz not null default now();

alter table public.profiles
  add constraint profiles_public_id_key unique (public_id);

-- Trimmed 1–80 characters, never null. Every existing profile already
-- satisfies this (all are "New member").
alter table public.profiles
  add constraint profiles_display_name_check
  check (display_name is not null
         and char_length(display_name) <= 80
         and char_length(btrim(display_name)) between 1 and 80);

alter table public.profiles
  add constraint profiles_bio_check
  check (bio is null or (char_length(bio) <= 300 and char_length(btrim(bio)) > 0));

alter table public.profiles
  add constraint profiles_recovery_visibility_check
  check (recovery_visibility in ('private', 'members', 'public'));

alter table public.profiles
  add constraint profiles_recovery_date_check
  check (recovery_date is null or recovery_date >= date '1900-01-01');

-- An avatar always lives in the member's own public_id folder.
alter table public.profiles
  add constraint profiles_avatar_path_check
  check (avatar_path is null
         or avatar_path ~ ('^' || public_id::text || '/[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png|webp)$'));


-- ---------- profiles: keep public_id fixed, track profile edits ----------
-- public_id never changes once issued. profile_updated_at moves only
-- when a member-visible profile field changes, whichever path changed
-- it (the new RPCs, the legacy direct UPDATE, or admin moderation).

create or replace function public.profiles_before_update()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.public_id := old.public_id;
  if (new.display_name, new.bio, new.avatar_path, new.recovery_date, new.recovery_visibility)
     is distinct from
     (old.display_name, old.bio, old.avatar_path, old.recovery_date, old.recovery_visibility) then
    new.profile_updated_at := now();
  end if;
  return new;
end;
$$;

revoke execute on function public.profiles_before_update from public, anon, authenticated;

create trigger profiles_before_update
  before update on public.profiles
  for each row execute function public.profiles_before_update();


-- ---------- handle_new_user(): sanitize the sign-up display name ----------
-- Same behavior as before, but the metadata name is trimmed and capped
-- at 80 characters (falling back to 'New member'), so the new
-- display_name rule can never make account creation fail.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(nullif(btrim(left(coalesce(new.raw_user_meta_data ->> 'display_name', ''), 80)), ''), 'New member')
  );
  return new;
end;
$$;


-- ---------- my_profile_public_id() ----------
-- The signed-in member's own public_id; used by the avatar storage
-- policies so ownership is checked against public_id, never auth id.

create or replace function public.my_profile_public_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public_id from public.profiles where id = auth.uid();
$$;

revoke execute on function public.my_profile_public_id from public;
revoke execute on function public.my_profile_public_id from anon;
grant execute on function public.my_profile_public_id to authenticated;


-- ---------- community_member_profiles_public (view) ----------
-- Safe profile read model. Never exposes the auth id, email,
-- membership tier, notification prefs, or recovery_visibility itself.
-- recovery_date is returned only when the viewer may see it.

create view public.community_member_profiles_public as
select
  p.public_id,
  p.display_name,
  p.bio,
  p.avatar_path,
  p.created_at as joined_at,
  case
    when p.recovery_date is null then null
    when p.id = auth.uid() then p.recovery_date
    when p.recovery_visibility = 'public' then p.recovery_date
    when p.recovery_visibility = 'members' and auth.uid() is not null then p.recovery_date
    else null
  end as recovery_date
from public.profiles p
where p.id = auth.uid()
   or exists (
     select 1 from public.community_posts cp
     where cp.user_id = p.id and cp.status = 'published'
   )
   or exists (
     select 1 from public.community_comments c
     join public.community_comments_public ccp on ccp.id = c.id
     where c.user_id = p.id
   );

revoke all on public.community_member_profiles_public from anon, authenticated;
grant select on public.community_member_profiles_public to anon, authenticated;


-- ---------- author_public_id on the Community public views ----------
-- Same columns, order and filters as before, with author_public_id
-- appended at the end. CREATE OR REPLACE keeps existing grants and the
-- dependent community_reaction_counts_public view.

create or replace view public.community_posts_public as
select
  cp.id,
  cp.body,
  cp.created_at,
  cp.updated_at,
  cp.edited_at,
  coalesce(p.display_name, 'Community member') as display_name,
  p.public_id as author_public_id
from public.community_posts cp
left join public.profiles p on p.id = cp.user_id
where cp.status = 'published';

create or replace view public.community_comments_public as
select
  cc.id,
  cc.post_id,
  cc.parent_comment_id,
  cc.body,
  cc.created_at,
  cc.updated_at,
  cc.edited_at,
  coalesce(pr.display_name, 'Community member') as display_name,
  pr.public_id as author_public_id
from public.community_comments cc
join public.community_posts cp on cp.id = cc.post_id and cp.status = 'published'
left join public.community_comments parent on parent.id = cc.parent_comment_id
left join public.profiles pr on pr.id = cc.user_id
where cc.status = 'published'
  and (
    cc.parent_comment_id is null
    or (parent.status = 'published' and parent.parent_comment_id is null)
  );


-- ---------- get_my_profile() ----------
-- The caller's own full profile, including a private recovery_date.
-- Never returns the auth id, email, membership tier or prefs.

create or replace function public.get_my_profile()
returns table (
  public_id uuid,
  display_name text,
  bio text,
  avatar_path text,
  recovery_date date,
  recovery_visibility text,
  joined_at timestamptz,
  profile_updated_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.public_id, p.display_name, p.bio, p.avatar_path,
         p.recovery_date, p.recovery_visibility, p.created_at, p.profile_updated_at
  from public.profiles p
  where p.id = auth.uid();
$$;

revoke execute on function public.get_my_profile from public;
revoke execute on function public.get_my_profile from anon;
grant execute on function public.get_my_profile to authenticated;


-- ---------- update_my_profile() ----------
-- Replaces the caller's display name, bio, recovery date and its
-- visibility in one call (all four are required, so nothing is
-- cleared by omission). Returns the updated profile.

create or replace function public.update_my_profile(
  p_display_name text,
  p_bio text,
  p_recovery_date date,
  p_recovery_visibility text
)
returns table (
  public_id uuid,
  display_name text,
  bio text,
  avatar_path text,
  recovery_date date,
  recovery_visibility text,
  joined_at timestamptz,
  profile_updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  v_name text := btrim(coalesce(p_display_name, ''));
  v_bio text := nullif(btrim(coalesce(p_bio, '')), '');
begin
  if caller_id is null then
    raise exception 'Sign in required to edit your profile.' using errcode = '42501';
  end if;

  if char_length(v_name) < 1 or char_length(v_name) > 80 then
    raise exception 'Display name must be 1 to 80 characters.' using errcode = '22023';
  end if;
  if v_name ~ '[[:cntrl:]]' then
    raise exception 'Display name cannot contain line breaks or control characters.' using errcode = '22023';
  end if;

  if v_bio is not null and char_length(v_bio) > 300 then
    raise exception 'Bio must be 300 characters or fewer.' using errcode = '22023';
  end if;

  if p_recovery_visibility is null or p_recovery_visibility not in ('private', 'members', 'public') then
    raise exception 'Recovery date visibility must be private, members, or public.' using errcode = '22023';
  end if;

  if p_recovery_date is not null and (p_recovery_date > current_date or p_recovery_date < date '1900-01-01') then
    raise exception 'Recovery date must be a real date that is not in the future.' using errcode = '22023';
  end if;

  update public.profiles
    set display_name = v_name,
        bio = v_bio,
        recovery_date = p_recovery_date,
        recovery_visibility = p_recovery_visibility
    where id = caller_id;
  if not found then
    raise exception 'Profile not found.' using errcode = 'P0002';
  end if;

  return query select g.* from public.get_my_profile() g;
end;
$$;

revoke execute on function public.update_my_profile from public;
revoke execute on function public.update_my_profile from anon;
grant execute on function public.update_my_profile to authenticated;


-- ---------- set_my_avatar() / clear_my_avatar() ----------
-- The image is uploaded first (storage policies below only allow the
-- member's own public_id folder); set_my_avatar() then records it,
-- after checking the path is in that folder and the object exists.
-- clear_my_avatar() only unsets the column; the client deletes the old
-- object through the storage API (allowed by the delete policy).

create or replace function public.set_my_avatar(p_path text)
returns table (
  public_id uuid,
  display_name text,
  bio text,
  avatar_path text,
  recovery_date date,
  recovery_visibility text,
  joined_at timestamptz,
  profile_updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  v_public_id uuid;
begin
  if caller_id is null then
    raise exception 'Sign in required to change your photo.' using errcode = '42501';
  end if;

  select p.public_id into v_public_id from public.profiles p where p.id = caller_id;
  if v_public_id is null then
    raise exception 'Profile not found.' using errcode = 'P0002';
  end if;

  if p_path is null or p_path !~ ('^' || v_public_id::text || '/[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png|webp)$') then
    raise exception 'That photo path is not valid for your profile.' using errcode = '22023';
  end if;

  if not exists (select 1 from storage.objects o where o.bucket_id = 'avatars' and o.name = p_path) then
    raise exception 'Upload the photo before saving it to your profile.' using errcode = '22023';
  end if;

  update public.profiles set avatar_path = p_path where id = caller_id;

  return query select g.* from public.get_my_profile() g;
end;
$$;

revoke execute on function public.set_my_avatar from public;
revoke execute on function public.set_my_avatar from anon;
grant execute on function public.set_my_avatar to authenticated;

create or replace function public.clear_my_avatar()
returns table (
  public_id uuid,
  display_name text,
  bio text,
  avatar_path text,
  recovery_date date,
  recovery_visibility text,
  joined_at timestamptz,
  profile_updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'Sign in required to change your photo.' using errcode = '42501';
  end if;

  update public.profiles set avatar_path = null where id = caller_id;
  if not found then
    raise exception 'Profile not found.' using errcode = 'P0002';
  end if;

  return query select g.* from public.get_my_profile() g;
end;
$$;

revoke execute on function public.clear_my_avatar from public;
revoke execute on function public.clear_my_avatar from anon;
grant execute on function public.clear_my_avatar to authenticated;


-- ---------- moderate_member_profile() (admin only, for 7D) ----------
-- Actions: reset_display_name (to 'Community member'), clear_bio,
-- clear_avatar, hide_recovery (sets visibility to private; the
-- member's date itself is kept). No UI yet.

create or replace function public.moderate_member_profile(
  p_public_id uuid,
  p_action text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Only an authenticated admin may moderate member profiles.' using errcode = '42501';
  end if;

  if p_action = 'reset_display_name' then
    update public.profiles set display_name = 'Community member' where public_id = p_public_id;
  elsif p_action = 'clear_bio' then
    update public.profiles set bio = null where public_id = p_public_id;
  elsif p_action = 'clear_avatar' then
    update public.profiles set avatar_path = null where public_id = p_public_id;
  elsif p_action = 'hide_recovery' then
    update public.profiles set recovery_visibility = 'private' where public_id = p_public_id;
  else
    raise exception 'Unknown profile moderation action: %', p_action using errcode = '22023';
  end if;

  if not found then
    raise exception 'Profile not found.' using errcode = 'P0002';
  end if;
  return true;
end;
$$;

revoke execute on function public.moderate_member_profile from public;
revoke execute on function public.moderate_member_profile from anon;
grant execute on function public.moderate_member_profile to authenticated;


-- ---------- avatars storage bucket ----------
-- Public read (avatar images only), 1 MB maximum, JPEG/PNG/WebP only.
-- Objects live at '<public_id>/<file>.<ext>'; members may write,
-- replace, list and delete only inside their own public_id folder.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "avatars_select_own"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.my_profile_public_id()::text);

create policy "avatars_insert_own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = public.my_profile_public_id()::text
    and name ~ '^[0-9a-f-]{36}/[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png|webp)$'
  );

create policy "avatars_update_own"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.my_profile_public_id()::text)
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = public.my_profile_public_id()::text
    and name ~ '^[0-9a-f-]{36}/[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png|webp)$'
  );

create policy "avatars_delete_own"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.my_profile_public_id()::text);
