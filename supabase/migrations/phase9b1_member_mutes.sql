-- ============================================================
-- Phase 9B-1: private member muting (database only)
-- ============================================================
-- Muting is a private, viewer-side visibility preference. Unlike
-- blocking, it changes nothing about how two members can interact:
-- follows, @mentions, replies, reactions and autocomplete are untouched,
-- and nothing is deleted. This migration adds the private mute list and
-- hides notifications from muted members at READ time, so unmuting
-- brings their historical notifications back. Feed/search/comment hiding
-- happens in the frontend (Phase 9B-2) using get_my_muted_members.
--
-- Rules this migration enforces:
--   - member_mutes holds one row per direction; auth ids stay internal.
--     RLS is on and anon/authenticated have no table privileges: every
--     read/write goes through the RPCs below, which use public_id only.
--   - The muted member is never told and can't see who muted them.
--   - Notification storage and creation are unchanged (no insert guard,
--     no schema change); only list_my_community_notifications and
--     count_my_unread_community_notifications skip muted actors.
--   - member_blocks, its guards, get_member_relationship and old
--     migrations are not modified.
-- ============================================================


-- ---------- member_mutes ----------

create table public.member_mutes (
  muter_user_id uuid not null references auth.users(id) on delete cascade,
  muted_user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint member_mutes_pkey primary key (muter_user_id, muted_user_id),
  constraint member_mutes_not_self_check check (muter_user_id <> muted_user_id)
);

create index member_mutes_muted_user_idx on public.member_mutes (muted_user_id);

alter table public.member_mutes enable row level security;

revoke all on table public.member_mutes from public, anon, authenticated;


-- ---------- mute_member ----------
-- Idempotent; a repeat returns the original mute time. No other side
-- effects: follows, blocks, mentions and notifications are untouched.

create or replace function public.mute_member(target_public_id uuid)
returns table (muted boolean, muted_at timestamptz)
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
    raise exception 'Sign in required to mute members.' using errcode = '42501';
  end if;

  select p.id into target_id from public.profiles p where p.public_id = target_public_id;
  if target_id is null then
    raise exception 'Member not found.' using errcode = 'P0002';
  end if;
  if target_id = caller_id then
    raise exception 'You can''t mute yourself.' using errcode = '22023';
  end if;

  insert into public.member_mutes (muter_user_id, muted_user_id)
  values (caller_id, target_id)
  on conflict do nothing;

  return query
    select true, mm.created_at
    from public.member_mutes mm
    where mm.muter_user_id = caller_id and mm.muted_user_id = target_id;
end;
$$;

revoke all on function public.mute_member(uuid) from public, anon;
grant execute on function public.mute_member(uuid) to authenticated;


-- ---------- unmute_member ----------
-- Removes only the caller's own mute. Unknown target returns false
-- (same convention as unfollow_member / unblock_member).

create or replace function public.unmute_member(target_public_id uuid)
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
    raise exception 'Sign in required to unmute members.' using errcode = '42501';
  end if;

  select p.id into target_id from public.profiles p where p.public_id = target_public_id;
  if target_id is null then
    return false;
  end if;

  delete from public.member_mutes mm
  where mm.muter_user_id = caller_id and mm.muted_user_id = target_id;
  return found;
end;
$$;

revoke all on function public.unmute_member(uuid) from public, anon;
grant execute on function public.unmute_member(uuid) to authenticated;


-- ---------- get_my_muted_members ----------

create or replace function public.get_my_muted_members()
returns table (
  public_id uuid,
  display_name text,
  avatar_path text,
  handle text,
  muted_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.public_id, p.display_name, p.avatar_path, p.handle, mm.created_at
  from public.member_mutes mm
  join public.profiles p on p.id = mm.muted_user_id
  where mm.muter_user_id = auth.uid()
  order by mm.created_at desc;
$$;

revoke all on function public.get_my_muted_members() from public, anon;
grant execute on function public.get_my_muted_members() to authenticated;


-- ---------- notification reads: skip muted actors ----------
-- Same signatures, return columns, ordering and limits as Phase 8C-1 /
-- 6C. The only change is the NOT EXISTS on member_mutes. Notifications
-- with no actor (actor deleted) are unaffected.

create or replace function public.list_my_community_notifications(
  p_limit integer default 30,
  p_before timestamptz default null
)
returns table (
  id uuid,
  notification_type text,
  created_at timestamptz,
  read_at timestamptz,
  actor_display_name text,
  target_available boolean,
  post_id uuid,
  comment_id uuid,
  reply_comment_id uuid,
  excerpt text,
  actor_public_id uuid,
  actor_avatar_path text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    n.id,
    n.notification_type,
    n.created_at,
    n.read_at,
    coalesce(nullif(btrim(pr.display_name), ''), 'A member'),
    a.available,
    case when a.available then n.post_id end,
    case when a.available then n.comment_id end,
    case when a.available then n.reply_comment_id end,
    case when a.available then left(
      case n.notification_type
        when 'post_reaction' then pp.body
        when 'comment_reaction' then cc.body
        when 'comment_reply' then rc.body
        when 'mention_post' then pp.body
        when 'mention_comment' then cc.body
        when 'mention_reply' then rc.body
      end, 140) end,
    mp.public_id,
    mp.avatar_path
  from public.community_notifications n
  left join public.profiles pr on pr.id = n.actor_user_id
  left join public.community_member_profiles_public mp on mp.public_id = pr.public_id
  left join public.community_posts_public pp on pp.id = n.post_id
  left join public.community_comments_public cc on cc.id = n.comment_id
  left join public.community_comments_public rc on rc.id = n.reply_comment_id
  cross join lateral (
    select case n.notification_type
      when 'post_reaction' then pp.id is not null
      when 'comment_reaction' then cc.id is not null
      when 'comment_reply' then cc.id is not null and rc.id is not null
      when 'mention_post' then pp.id is not null
      when 'mention_comment' then pp.id is not null and cc.id is not null
      when 'mention_reply' then pp.id is not null and cc.id is not null and rc.id is not null
      when 'follow' then mp.public_id is not null
      else false
    end as available
  ) a
  where n.recipient_user_id = auth.uid()
    and (p_before is null or n.created_at < p_before)
    and not exists (
      select 1 from public.member_mutes mm
      where mm.muter_user_id = n.recipient_user_id
        and mm.muted_user_id = n.actor_user_id
    )
  order by n.created_at desc, n.id desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

revoke all on function public.list_my_community_notifications(integer, timestamptz) from public, anon;
grant execute on function public.list_my_community_notifications(integer, timestamptz) to authenticated;

create or replace function public.count_my_unread_community_notifications()
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select count(*)::integer
  from public.community_notifications n
  where n.recipient_user_id = auth.uid()
    and n.read_at is null
    and not exists (
      select 1 from public.member_mutes mm
      where mm.muter_user_id = n.recipient_user_id
        and mm.muted_user_id = n.actor_user_id
    );
$$;

revoke all on function public.count_my_unread_community_notifications() from public, anon;
grant execute on function public.count_my_unread_community_notifications() to authenticated;
