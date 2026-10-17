-- ============================================================
-- Phase 8A: private member follows
-- ============================================================
-- A signed-in member can follow / unfollow another Community member
-- and see their own private Following list. No counts, no public
-- followers/following lists, no notifications in this phase.
--
-- Identity: rows store auth user ids internally (like every other
-- Community table), so ownership checks are direct auth.uid()
-- comparisons and deleting either account removes the follow. The
-- frontend and RPCs only ever use profiles.public_id; no function here
-- returns an auth id.
--
-- Access: no table privileges at all for anon or authenticated —
-- members read and write only through the four SECURITY DEFINER
-- functions below. There is no admin write path; admins can review
-- follows from the Supabase SQL editor if ever needed for abuse.
-- ============================================================


-- ---------- member_follows ----------

create table public.member_follows (
  follower_user_id uuid not null references auth.users (id) on delete cascade,
  followed_user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint member_follows_pkey primary key (follower_user_id, followed_user_id),
  constraint member_follows_not_self_check check (follower_user_id <> followed_user_id)
);

create index member_follows_followed_user_id_idx on public.member_follows (followed_user_id);

alter table public.member_follows enable row level security;

revoke all on table public.member_follows from anon, authenticated;


-- ---------- follow_member() ----------
-- Only members currently listed in community_member_profiles_public
-- (i.e. with published Community content) can be newly followed, and
-- an unknown or unlisted public_id gets the same "not found", so this
-- can't be used to discover which accounts exist. Following someone
-- you already follow is a no-op.

create or replace function public.follow_member(target_public_id uuid)
returns table (following boolean, followed_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  target_id uuid;
begin
  if caller_id is null then
    raise exception 'Sign in required to follow members.' using errcode = '42501';
  end if;

  select p.id into target_id from public.profiles p where p.public_id = target_public_id;
  if target_id is null then
    raise exception 'Member not found.' using errcode = 'P0002';
  end if;

  if target_id = caller_id then
    raise exception 'You can''t follow yourself.' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.community_member_profiles_public v where v.public_id = target_public_id
  ) then
    raise exception 'Member not found.' using errcode = 'P0002';
  end if;

  insert into public.member_follows (follower_user_id, followed_user_id)
  values (caller_id, target_id)
  on conflict do nothing;

  return query
    select true, f.created_at
    from public.member_follows f
    where f.follower_user_id = caller_id and f.followed_user_id = target_id;
end;
$$;

revoke execute on function public.follow_member from public;
revoke execute on function public.follow_member from anon;
grant execute on function public.follow_member to authenticated;


-- ---------- unfollow_member() ----------
-- Removes only the caller's own follow. Returns true if a follow was
-- removed, false otherwise (including an unknown public_id), so it is
-- idempotent and reveals nothing about other members.

create or replace function public.unfollow_member(target_public_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  target_id uuid;
begin
  if caller_id is null then
    raise exception 'Sign in required to unfollow members.' using errcode = '42501';
  end if;

  select p.id into target_id from public.profiles p where p.public_id = target_public_id;
  if target_id is null then
    return false;
  end if;

  delete from public.member_follows
    where follower_user_id = caller_id and followed_user_id = target_id;
  return found;
end;
$$;

revoke execute on function public.unfollow_member from public;
revoke execute on function public.unfollow_member from anon;
grant execute on function public.unfollow_member to authenticated;


-- ---------- get_follow_state() ----------
-- The caller's own relationship to one member. An unknown public_id
-- looks the same as "not following", so nothing is enumerable.

create or replace function public.get_follow_state(target_public_id uuid)
returns table (is_self boolean, following boolean, followed_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  target_id uuid;
  since timestamptz;
begin
  if caller_id is null then
    raise exception 'Sign in required.' using errcode = '42501';
  end if;

  select p.id into target_id from public.profiles p where p.public_id = target_public_id;
  if target_id is not null and target_id <> caller_id then
    select f.created_at into since
      from public.member_follows f
      where f.follower_user_id = caller_id and f.followed_user_id = target_id;
  end if;

  return query select (target_id is not null and target_id = caller_id), (since is not null), since;
end;
$$;

revoke execute on function public.get_follow_state from public;
revoke execute on function public.get_follow_state from anon;
grant execute on function public.get_follow_state to authenticated;


-- ---------- get_my_following() ----------
-- The caller's own Following list, newest first. Only public-facing
-- profile fields; never auth ids, email, recovery data or prefs.

create or replace function public.get_my_following()
returns table (public_id uuid, display_name text, avatar_path text, followed_at timestamptz)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.public_id, p.display_name, p.avatar_path, f.created_at
  from public.member_follows f
  join public.profiles p on p.id = f.followed_user_id
  where f.follower_user_id = auth.uid()
  order by f.created_at desc;
$$;

revoke execute on function public.get_my_following from public;
revoke execute on function public.get_my_following from anon;
grant execute on function public.get_my_following to authenticated;
