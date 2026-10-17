-- ============================================================
-- Phase 6C: Community engagement — reactions, in-app
-- notifications, and public reaction counts
-- ============================================================
-- APPLIED to production on 2026-10-16 as migration
-- "phase6c_community_engagement" (version 20261016204446), after a
-- rollback-only validation run. Only this header comment changed after
-- apply; every executable statement below is exactly what was applied.
--
-- Builds on phase6a_community_posts_foundation and
-- phase6b_comments_replies_reports (+ phase6b_reports_open_unique_fix).
-- Same posture as 6A/6B: base tables are admin-only SELECT, nobody
-- (admin included) has INSERT/UPDATE/DELETE on them, and every member
-- action goes through a SECURITY DEFINER function that derives
-- identity from auth.uid() — never from a parameter.
--
-- Adds:
--   community_reactions               one active reaction per member per target
--   community_notifications           private, in-app only
--   community_reaction_counts_public  aggregate counts for visible targets only
--   toggle_community_reaction()
--   list_my_community_reactions()
--   list_my_community_notifications()
--   count_my_unread_community_notifications()
--   mark_community_notification_read()
--   mark_all_community_notifications_read()
--
-- Modifies (same signature, return type, and grants):
--   create_community_reply()  — adds the reply notification
--
-- Unchanged: community_posts_public, community_comments_public, and
-- every other 6A/6B object. Search needs no database object — it reads
-- the existing community_posts_public view (published posts only).
--
-- Privacy boundary unchanged: nothing here reads or writes the
-- Recovery Counter, Check-In, mood, craving, reflection, gratitude, or
-- rough-day data, none of which exists in Supabase.
-- ============================================================


-- ---------- community_reactions ----------
-- Exactly one target (post XOR comment/reply), one row per member per
-- target. Switching reaction updates the row in place; clicking the
-- same reaction again deletes it. No public read of this table — the
-- only public surface is the aggregate view further down.

create table public.community_reactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  post_id uuid references public.community_posts (id) on delete cascade,
  comment_id uuid references public.community_comments (id) on delete cascade,
  reaction text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.community_reactions
  add constraint community_reactions_exactly_one_target_check
  check ((post_id is not null and comment_id is null) or (post_id is null and comment_id is not null));

alter table public.community_reactions
  add constraint community_reactions_reaction_check
  check (reaction in ('support', 'heart', 'celebrate'));

-- The race-safe "one reaction TOTAL per member per target" guarantee.
create unique index community_reactions_one_per_member_post
  on public.community_reactions (user_id, post_id) where post_id is not null;
create unique index community_reactions_one_per_member_comment
  on public.community_reactions (user_id, comment_id) where comment_id is not null;

-- For the aggregate view.
create index community_reactions_post_id_idx
  on public.community_reactions (post_id) where post_id is not null;
create index community_reactions_comment_id_idx
  on public.community_reactions (comment_id) where comment_id is not null;

alter table public.community_reactions enable row level security;

create policy "community_reactions_select"
  on public.community_reactions for select
  using (public.is_admin());

revoke all on table public.community_reactions from anon, authenticated;
grant select on table public.community_reactions to authenticated;


-- ---------- community_notifications ----------
-- In-app only (no push/email/SMS). Three types:
--   comment_reply     someone replied to the recipient's top-level comment
--                     (comment_id = recipient's comment, reply_comment_id = the reply)
--   post_reaction     someone first reacted to the recipient's post
--   comment_reaction  someone first reacted to the recipient's comment/reply
-- post_id is always the post the activity happened under. The
-- reaction kind is deliberately not stored: switching reactions never
-- notifies, so a stored kind would go stale.
-- Self-notifications are impossible at the table level, not just in
-- the functions that insert.
-- actor_user_id is nullable with ON DELETE SET NULL (not CASCADE): if
-- the actor's account is later deleted, the recipient keeps the
-- notification and it renders with the "A member" fallback. The
-- functions always set it; NULL only ever arises from that deletion.

create table public.community_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null references auth.users (id) on delete cascade,
  actor_user_id uuid references auth.users (id) on delete set null,
  notification_type text not null,
  post_id uuid not null references public.community_posts (id) on delete cascade,
  comment_id uuid references public.community_comments (id) on delete cascade,
  reply_comment_id uuid references public.community_comments (id) on delete cascade,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.community_notifications
  add constraint community_notifications_type_check
  check (notification_type in ('comment_reply', 'post_reaction', 'comment_reaction'));

alter table public.community_notifications
  add constraint community_notifications_not_self_check
  check (recipient_user_id <> actor_user_id);

alter table public.community_notifications
  add constraint community_notifications_shape_check
  check (
    (notification_type = 'post_reaction'    and comment_id is null     and reply_comment_id is null)
    or (notification_type = 'comment_reaction' and comment_id is not null and reply_comment_id is null)
    or (notification_type = 'comment_reply'    and comment_id is not null and reply_comment_id is not null)
  );

create index community_notifications_recipient_created_idx
  on public.community_notifications (recipient_user_id, created_at desc);
create index community_notifications_recipient_unread_idx
  on public.community_notifications (recipient_user_id) where read_at is null;

alter table public.community_notifications enable row level security;

create policy "community_notifications_select"
  on public.community_notifications for select
  using (public.is_admin());

revoke all on table public.community_notifications from anon, authenticated;
grant select on table public.community_notifications to authenticated;


-- ---------- community_reaction_counts_public (view) ----------
-- Aggregate counts only — no user_id, no per-member rows. Visibility
-- is inherited by INNER JOIN to the two existing public views, so a
-- target that is hidden/removed (or a comment under a hidden/removed
-- post, or a reply under a hidden/removed comment) simply has no row
-- here; this view can never be looser than what the feed itself shows.
-- For comment rows, post_id is the post the comment belongs to, so a
-- client can fetch a post's counts and all its comments' counts with
-- one filter on post_id.

create view public.community_reaction_counts_public as
select
  'post'::text as target_type,
  r.post_id,
  null::uuid as comment_id,
  count(*) filter (where r.reaction = 'support')::integer as support_count,
  count(*) filter (where r.reaction = 'heart')::integer as heart_count,
  count(*) filter (where r.reaction = 'celebrate')::integer as celebrate_count,
  count(*)::integer as total_count
from public.community_reactions r
join public.community_posts_public pp on pp.id = r.post_id
group by r.post_id
union all
select
  'comment'::text as target_type,
  cc.post_id,
  r.comment_id,
  count(*) filter (where r.reaction = 'support')::integer as support_count,
  count(*) filter (where r.reaction = 'heart')::integer as heart_count,
  count(*) filter (where r.reaction = 'celebrate')::integer as celebrate_count,
  count(*)::integer as total_count
from public.community_reactions r
join public.community_comments_public cc on cc.id = r.comment_id
group by r.comment_id, cc.post_id;

revoke all on public.community_reaction_counts_public from anon, authenticated;
grant select on public.community_reaction_counts_public to anon, authenticated;


-- ---------- toggle_community_reaction() ----------
-- The only way a reaction is ever added, switched, or removed.
--   no existing row         -> insert            (result_action 'added')
--   same reaction again     -> delete            (result_action 'removed')
--   different reaction      -> update in place   (result_action 'switched')
-- Only 'added' can create a notification, and only when the target's
-- author is not the caller. Removing never deletes an old
-- notification; removing and later re-adding is a new 'added' and may
-- notify again. Only content currently visible to the public can be
-- reacted to (or have its reaction changed).

create or replace function public.toggle_community_reaction(
  p_reaction text,
  p_post_id uuid default null,
  p_comment_id uuid default null
)
returns table (result_action text, result_reaction text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  author_id uuid;
  parent_post_id uuid;
  existing_row public.community_reactions;
  v_action text;
  v_reaction text;
begin
  if caller_id is null then
    raise exception 'Sign in required to react.' using errcode = '42501';
  end if;

  if (p_post_id is null) = (p_comment_id is null) then
    raise exception 'Exactly one of a post or a comment must be reacted to.' using errcode = '22023';
  end if;

  if p_reaction is null or p_reaction not in ('support', 'heart', 'celebrate') then
    raise exception 'Invalid reaction: %', p_reaction using errcode = '22023';
  end if;

  if p_post_id is not null then
    select user_id into author_id from public.community_posts where id = p_post_id;
    if author_id is null then
      raise exception 'Post not found.' using errcode = 'P0002';
    end if;
    if not exists (select 1 from public.community_posts_public where id = p_post_id) then
      raise exception 'This post is no longer available.' using errcode = '22023';
    end if;
    parent_post_id := p_post_id;

    select * into existing_row from public.community_reactions
      where user_id = caller_id and post_id = p_post_id
      for update;
  else
    select user_id, post_id into author_id, parent_post_id
      from public.community_comments where id = p_comment_id;
    if author_id is null then
      raise exception 'Comment not found.' using errcode = 'P0002';
    end if;
    if not exists (select 1 from public.community_comments_public where id = p_comment_id) then
      raise exception 'This comment is no longer available.' using errcode = '22023';
    end if;

    select * into existing_row from public.community_reactions
      where user_id = caller_id and comment_id = p_comment_id
      for update;
  end if;

  if existing_row.id is not null then
    if existing_row.reaction = p_reaction then
      delete from public.community_reactions where id = existing_row.id;
      v_action := 'removed';
      v_reaction := null;
    else
      update public.community_reactions
        set reaction = p_reaction, updated_at = now()
        where id = existing_row.id;
      v_action := 'switched';
      v_reaction := p_reaction;
    end if;
  else
    begin
      insert into public.community_reactions (user_id, post_id, comment_id, reaction)
      values (caller_id, p_post_id, p_comment_id, p_reaction);
    exception
      when unique_violation then
        -- A concurrent call from the same member won the insert.
        raise exception 'Your reaction was just updated elsewhere. Please refresh and try again.'
          using errcode = '23505';
    end;
    v_action := 'added';
    v_reaction := p_reaction;

    if author_id <> caller_id then
      insert into public.community_notifications (
        recipient_user_id, actor_user_id, notification_type, post_id, comment_id
      ) values (
        author_id, caller_id,
        case when p_post_id is not null then 'post_reaction' else 'comment_reaction' end,
        parent_post_id, p_comment_id
      );
    end if;
  end if;

  return query select v_action, v_reaction;
end;
$$;

revoke execute on function public.toggle_community_reaction from public;
revoke execute on function public.toggle_community_reaction from anon;
grant execute on function public.toggle_community_reaction to authenticated;


-- ---------- list_my_community_reactions() ----------
-- The caller's own active reactions on the given posts and on the
-- comments/replies under them, so the UI can highlight "your"
-- reaction. Never returns another member's row. Targets that are no
-- longer publicly visible are left out, same as the counts view.

create or replace function public.list_my_community_reactions(
  p_post_ids uuid[]
)
returns table (post_id uuid, comment_id uuid, reaction text)
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select r.post_id, null::uuid, r.reaction
  from public.community_reactions r
  join public.community_posts_public pp on pp.id = r.post_id
  where r.user_id = auth.uid()
    and r.post_id = any (p_post_ids)
  union all
  select cc.post_id, r.comment_id, r.reaction
  from public.community_reactions r
  join public.community_comments_public cc on cc.id = r.comment_id
  where r.user_id = auth.uid()
    and cc.post_id = any (p_post_ids);
$$;

revoke execute on function public.list_my_community_reactions from public;
revoke execute on function public.list_my_community_reactions from anon;
grant execute on function public.list_my_community_reactions to authenticated;


-- ---------- list_my_community_notifications() ----------
-- The caller's own notifications, newest first, paged by created_at.
-- Never returns a user_id. actor_display_name is the actor's CURRENT
-- profile display name (read at list time, not stored), falling back
-- to 'A member' when the account/profile is gone or the name is blank.
-- When the target has since been hidden or
-- removed (or its post/parent has), target_available is false and
-- every id and the excerpt come back null, so the UI renders a safe
-- "no longer available" fallback without ever learning anything about
-- moderated content.

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
  excerpt text
)
language sql
security definer
set search_path = public, pg_temp
stable
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
      end, 140) end
  from public.community_notifications n
  left join public.profiles pr on pr.id = n.actor_user_id
  left join public.community_posts_public pp on pp.id = n.post_id
  left join public.community_comments_public cc on cc.id = n.comment_id
  left join public.community_comments_public rc on rc.id = n.reply_comment_id
  cross join lateral (
    select case n.notification_type
      when 'post_reaction' then pp.id is not null
      when 'comment_reaction' then cc.id is not null
      when 'comment_reply' then cc.id is not null and rc.id is not null
      else false
    end as available
  ) a
  where n.recipient_user_id = auth.uid()
    and (p_before is null or n.created_at < p_before)
  order by n.created_at desc, n.id desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

revoke execute on function public.list_my_community_notifications from public;
revoke execute on function public.list_my_community_notifications from anon;
grant execute on function public.list_my_community_notifications to authenticated;


-- ---------- count_my_unread_community_notifications() ----------

create or replace function public.count_my_unread_community_notifications()
returns integer
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select count(*)::integer
  from public.community_notifications
  where recipient_user_id = auth.uid()
    and read_at is null;
$$;

revoke execute on function public.count_my_unread_community_notifications from public;
revoke execute on function public.count_my_unread_community_notifications from anon;
grant execute on function public.count_my_unread_community_notifications to authenticated;


-- ---------- mark_community_notification_read() ----------
-- Only ever touches the caller's own row. Another member's
-- notification id gets the same "not found" as a nonexistent one, so
-- this can't be used to probe which ids exist. Already-read is a
-- no-op, not an error.

create or replace function public.mark_community_notification_read(
  p_notification_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'Sign in required.' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.community_notifications
    where id = p_notification_id and recipient_user_id = caller_id
  ) then
    raise exception 'Notification not found.' using errcode = 'P0002';
  end if;

  update public.community_notifications
    set read_at = now()
    where id = p_notification_id
      and recipient_user_id = caller_id
      and read_at is null;

  return true;
end;
$$;

revoke execute on function public.mark_community_notification_read from public;
revoke execute on function public.mark_community_notification_read from anon;
grant execute on function public.mark_community_notification_read to authenticated;


-- ---------- mark_all_community_notifications_read() ----------
-- Returns how many were newly marked read.

create or replace function public.mark_all_community_notifications_read()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  updated_count integer;
begin
  if caller_id is null then
    raise exception 'Sign in required.' using errcode = '42501';
  end if;

  update public.community_notifications
    set read_at = now()
    where recipient_user_id = caller_id
      and read_at is null;
  get diagnostics updated_count = row_count;

  return updated_count;
end;
$$;

revoke execute on function public.mark_all_community_notifications_read from public;
revoke execute on function public.mark_all_community_notifications_read from anon;
grant execute on function public.mark_all_community_notifications_read to authenticated;


-- ---------- create_community_reply() (modified) ----------
-- Identical to the Phase 6B definition except for the single
-- notification insert after the reply is stored. Same signature and
-- return type, so CREATE OR REPLACE keeps its existing grants and the
-- existing index.html call is unaffected. The grant statements below
-- just restate them. No notification when replying to your own
-- comment.

create or replace function public.create_community_reply(
  p_post_id uuid,
  p_parent_comment_id uuid,
  p_body text
)
returns public.community_comments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  post_row public.community_posts;
  parent_row public.community_comments;
  result_row public.community_comments;
begin
  if caller_id is null then
    raise exception 'Sign in required to reply.' using errcode = '42501';
  end if;

  if p_body is null or char_length(btrim(p_body)) = 0 then
    raise exception 'Reply text is required.' using errcode = '22023';
  end if;
  if char_length(p_body) > 1000 then
    raise exception 'Reply text must be 1,000 characters or fewer.' using errcode = '22023';
  end if;

  select * into post_row from public.community_posts where id = p_post_id;
  if post_row.id is null then
    raise exception 'Post not found.' using errcode = 'P0002';
  end if;
  if post_row.status <> 'published' then
    raise exception 'This post is no longer available for replies.' using errcode = '22023';
  end if;

  select * into parent_row from public.community_comments where id = p_parent_comment_id for update;
  if parent_row.id is null then
    raise exception 'Comment not found.' using errcode = 'P0002';
  end if;
  if parent_row.post_id <> p_post_id then
    raise exception 'That comment does not belong to this post.' using errcode = '22023';
  end if;
  if parent_row.parent_comment_id is not null then
    raise exception 'Replies can only be made to a top-level comment.' using errcode = '22023';
  end if;
  if parent_row.status <> 'published' then
    raise exception 'This comment is no longer available for replies.' using errcode = '22023';
  end if;

  insert into public.community_comments (post_id, user_id, parent_comment_id, body, status)
  values (p_post_id, caller_id, p_parent_comment_id, btrim(p_body), 'published')
  returning * into result_row;

  -- Phase 6C: notify the parent comment's author (never yourself).
  if parent_row.user_id <> caller_id then
    insert into public.community_notifications (
      recipient_user_id, actor_user_id, notification_type, post_id, comment_id, reply_comment_id
    ) values (
      parent_row.user_id, caller_id, 'comment_reply', p_post_id, parent_row.id, result_row.id
    );
  end if;

  return result_row;
end;
$$;

revoke execute on function public.create_community_reply from public;
revoke execute on function public.create_community_reply from anon;
grant execute on function public.create_community_reply to authenticated;
