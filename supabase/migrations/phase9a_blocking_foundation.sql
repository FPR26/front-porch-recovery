-- ============================================================
-- Phase 9A: member blocking foundation (database only)
-- ============================================================
-- Blocking is an interaction-safety tool. When either member of a pair
-- has blocked the other:
--   - follows between them are removed, and neither can follow the other;
--   - neither appears in the other's @handle autocomplete, and new
--     @mentions between them aren't stored (the text stays plain);
--   - no notification of any type is created between them;
--   - neither can reply directly to the other's comment.
-- Public posts/comments stay visible to everyone, reactions and
-- top-level comments stay allowed, and historical mentions and non-follow
-- notifications are kept. Content hiding is Phase 9B (mute).
--
-- Rules this migration enforces:
--   - member_blocks holds one row per direction; auth ids stay internal.
--     RLS is on and anon/authenticated have no table privileges: every
--     read/write goes through the RPCs below, which use public_id only.
--   - The blocked member is never told: get_member_relationship never
--     reports "blocked by them" (only can_follow = false), and the
--     guards use generic messages that don't say who blocked whom.
--   - block_member and the member_follows guard take the same ordered
--     pair advisory lock, so a block and a follow can't race past each
--     other. Mentions are covered in depth by the autocomplete filter,
--     the mention-sync filter and the notification guard.
--   - follow_member, unfollow_member, get_follow_state, the reply and
--     reaction RPCs and old migrations are not modified.
-- ============================================================


-- ---------- member_blocks ----------

create table public.member_blocks (
  blocker_user_id uuid not null references auth.users(id) on delete cascade,
  blocked_user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint member_blocks_pkey primary key (blocker_user_id, blocked_user_id),
  constraint member_blocks_not_self_check check (blocker_user_id <> blocked_user_id)
);

create index member_blocks_blocked_user_idx on public.member_blocks (blocked_user_id);

alter table public.member_blocks enable row level security;

revoke all on table public.member_blocks from public, anon, authenticated;


-- ---------- internal helpers ----------

-- True when either member has blocked the other.
create or replace function public.is_block_between(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.member_blocks mb
    where (mb.blocker_user_id = a and mb.blocked_user_id = b)
       or (mb.blocker_user_id = b and mb.blocked_user_id = a)
  );
$$;

revoke all on function public.is_block_between(uuid, uuid) from public, anon, authenticated;

-- Transaction-scoped lock on an unordered member pair (same key for a,b
-- and b,a). Taken by block_member and the member_follows guard.
create or replace function public.lock_member_pair(a uuid, b uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform pg_advisory_xact_lock(
    hashtextextended('fpr_member_pair:' || least(a, b)::text || ':' || greatest(a, b)::text, 0)
  );
end;
$$;

revoke all on function public.lock_member_pair(uuid, uuid) from public, anon, authenticated;


-- ---------- block_member ----------

create or replace function public.block_member(target_public_id uuid)
returns table (blocked boolean, blocked_at timestamptz)
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
    raise exception 'Sign in required to block members.' using errcode = '42501';
  end if;

  select p.id into target_id from public.profiles p where p.public_id = target_public_id;
  if target_id is null then
    raise exception 'Member not found.' using errcode = 'P0002';
  end if;
  if target_id = caller_id then
    raise exception 'You can''t block yourself.' using errcode = '22023';
  end if;

  perform public.lock_member_pair(caller_id, target_id);

  insert into public.member_blocks (blocker_user_id, blocked_user_id)
  values (caller_id, target_id)
  on conflict do nothing;

  -- Remove follows in both directions. The Phase 8C-3 member_follows
  -- delete trigger removes the matching follow notifications.
  delete from public.member_follows f
  where (f.follower_user_id = caller_id and f.followed_user_id = target_id)
     or (f.follower_user_id = target_id and f.followed_user_id = caller_id);

  return query
    select true, mb.created_at
    from public.member_blocks mb
    where mb.blocker_user_id = caller_id and mb.blocked_user_id = target_id;
end;
$$;

revoke all on function public.block_member(uuid) from public, anon;
grant execute on function public.block_member(uuid) to authenticated;


-- ---------- unblock_member ----------
-- Removes only the caller's own block. Old follows are not restored.

create or replace function public.unblock_member(target_public_id uuid)
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
    raise exception 'Sign in required to unblock members.' using errcode = '42501';
  end if;

  select p.id into target_id from public.profiles p where p.public_id = target_public_id;
  if target_id is null then
    return false;
  end if;

  delete from public.member_blocks mb
  where mb.blocker_user_id = caller_id and mb.blocked_user_id = target_id;
  return found;
end;
$$;

revoke all on function public.unblock_member(uuid) from public, anon;
grant execute on function public.unblock_member(uuid) to authenticated;


-- ---------- get_member_relationship ----------
-- The caller's view of one member. Never reports "blocked by them":
-- a block in either direction only shows up as can_follow = false.
-- can_follow also requires the target to be a listed member (the same
-- rule follow_member applies).

create or replace function public.get_member_relationship(target_public_id uuid)
returns table (
  is_self boolean,
  following boolean,
  followed_at timestamptz,
  blocked_by_me boolean,
  blocked_at timestamptz,
  can_follow boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  target_id uuid;
  v_followed_at timestamptz;
  v_blocked_at timestamptz;
  v_any_block boolean := false;
  v_listed boolean := false;
begin
  if caller_id is null then
    raise exception 'Sign in required.' using errcode = '42501';
  end if;

  select p.id into target_id from public.profiles p where p.public_id = target_public_id;

  if target_id is not null and target_id <> caller_id then
    select f.created_at into v_followed_at
      from public.member_follows f
      where f.follower_user_id = caller_id and f.followed_user_id = target_id;
    select mb.created_at into v_blocked_at
      from public.member_blocks mb
      where mb.blocker_user_id = caller_id and mb.blocked_user_id = target_id;
    v_any_block := public.is_block_between(caller_id, target_id);
    v_listed := exists (
      select 1 from public.community_member_profiles_public v where v.public_id = target_public_id
    );
  end if;

  return query select
    (target_id is not null and target_id = caller_id),
    (v_followed_at is not null),
    v_followed_at,
    (v_blocked_at is not null),
    v_blocked_at,
    (target_id is not null and target_id <> caller_id and not v_any_block and v_listed);
end;
$$;

revoke all on function public.get_member_relationship(uuid) from public, anon;
grant execute on function public.get_member_relationship(uuid) to authenticated;


-- ---------- get_my_blocked_members ----------

create or replace function public.get_my_blocked_members()
returns table (
  public_id uuid,
  display_name text,
  avatar_path text,
  handle text,
  blocked_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.public_id, p.display_name, p.avatar_path, p.handle, mb.created_at
  from public.member_blocks mb
  join public.profiles p on p.id = mb.blocked_user_id
  where mb.blocker_user_id = auth.uid()
  order by mb.created_at desc;
$$;

revoke all on function public.get_my_blocked_members() from public, anon;
grant execute on function public.get_my_blocked_members() to authenticated;


-- ---------- follow guard ----------
-- Covers every member_follows write path (follow_member is unchanged).

create or replace function public.member_follows_block_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.lock_member_pair(new.follower_user_id, new.followed_user_id);
  if public.is_block_between(new.follower_user_id, new.followed_user_id) then
    raise exception 'This member can''t be followed right now.' using errcode = 'P0002';
  end if;
  return new;
end;
$$;

revoke all on function public.member_follows_block_guard() from public, anon, authenticated;

create trigger member_follows_block_guard
  before insert on public.member_follows
  for each row execute function public.member_follows_block_guard();


-- ---------- direct reply guard ----------
-- Only a reply to the other member's comment is blocked. Top-level
-- comments and reactions stay allowed in 9A.

create or replace function public.community_comments_reply_block_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_parent_author uuid;
begin
  if new.parent_comment_id is null then
    return new;
  end if;
  select c.user_id into v_parent_author from public.community_comments c where c.id = new.parent_comment_id;
  if v_parent_author is not null and public.is_block_between(new.user_id, v_parent_author) then
    raise exception 'This reply can''t be posted right now.' using errcode = 'P0002';
  end if;
  return new;
end;
$$;

revoke all on function public.community_comments_reply_block_guard() from public, anon, authenticated;

create trigger community_comments_reply_block_guard
  before insert on public.community_comments
  for each row execute function public.community_comments_reply_block_guard();


-- ---------- central notification guard ----------
-- Silently skips any notification between a blocked pair: comment_reply,
-- reactions, mentions, follow, and any future type.

create or replace function public.community_notifications_block_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.recipient_user_id is not null and new.actor_user_id is not null
     and public.is_block_between(new.recipient_user_id, new.actor_user_id) then
    return null;
  end if;
  return new;
end;
$$;

revoke all on function public.community_notifications_block_guard() from public, anon, authenticated;

create trigger community_notifications_block_guard
  before insert on public.community_notifications
  for each row execute function public.community_notifications_block_guard();


-- ---------- autocomplete: exclude blocked pairs ----------
-- Same signature and behaviour as Phase 8B-1, plus the block filter
-- (applied before the 8-row limit).

create or replace function public.search_member_handles(p_prefix text)
returns table (public_id uuid, handle text, display_name text, avatar_path text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with q as (
    select lower(btrim(regexp_replace(coalesce(p_prefix, ''), '^\s*@', ''))) as v
  )
  select m.public_id, m.handle, m.display_name, m.avatar_path
  from q
  join public.community_member_profiles_public m
    on m.handle like replace(q.v, '_', '\_') || '%'
  join public.profiles pr on pr.public_id = m.public_id
  where auth.uid() is not null
    and char_length(q.v) between 2 and 24
    and q.v ~ '^[a-z][a-z0-9_]*$'
    and not public.is_block_between(auth.uid(), pr.id)
  order by (m.handle = q.v) desc, m.handle
  limit 8;
$$;

revoke all on function public.search_member_handles(text) from public, anon;
grant execute on function public.search_member_handles(text) to authenticated;


-- ---------- mention sync: skip blocked pairs ----------
-- Same parsing, 10-mention cap and edit-sync behaviour as Phase 8B-1.
-- A handle whose owner has a block with the content's author is not
-- resolved, so no new mention row (or link, or notification) is created.
-- Existing rows are untouched unless that content is edited, in which
-- case a mention across a block is dropped like any other removed one.

create or replace function public.sync_community_mentions(p_post_id uuid, p_comment_id uuid, p_body text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ids uuid[];
  v_handles text[];
  v_author uuid;
begin
  if p_post_id is not null then
    select cp.user_id into v_author from public.community_posts cp where cp.id = p_post_id;
  else
    select cc.user_id into v_author from public.community_comments cc where cc.id = p_comment_id;
  end if;

  select coalesce(array_agg(w.user_id order by w.ord), '{}'), coalesce(array_agg(w.handle order by w.ord), '{}')
    into v_ids, v_handles
  from (
    select p.id as user_id, p.handle, x.ord
    from unnest(public.extract_mention_handles(p_body)) with ordinality as x(h, ord)
    join public.profiles p on p.handle = x.h
    where v_author is null or not public.is_block_between(v_author, p.id)
    order by x.ord
    limit 10
  ) w;

  if p_post_id is not null then
    delete from public.community_mentions m
      where m.post_id = p_post_id and not (m.mentioned_user_id = any (v_ids));
  else
    delete from public.community_mentions m
      where m.comment_id = p_comment_id and not (m.mentioned_user_id = any (v_ids));
  end if;

  insert into public.community_mentions (post_id, comment_id, mentioned_user_id, handle_at_write)
  select p_post_id, p_comment_id, u.user_id, u.handle
  from unnest(v_ids, v_handles) as u(user_id, handle)
  on conflict do nothing;
end;
$$;

revoke all on function public.sync_community_mentions(uuid, uuid, text) from public, anon, authenticated;
