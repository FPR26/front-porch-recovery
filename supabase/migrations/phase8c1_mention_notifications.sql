-- ============================================================
-- Phase 8C-1: mention notifications (database only)
-- ============================================================
-- Extends the Phase 6C in-app notifications with @mention events:
-- mention_post, mention_comment and mention_reply. The type/shape
-- constraints also accept 'follow' so they only change once, but no
-- follow notifications are created here (that's 8C-3).
--
-- Rules this migration enforces:
--   - A mention notification is created by an AFTER INSERT trigger on
--     community_mentions. The 8B-1 sync inserts with ON CONFLICT DO
--     NOTHING, so the trigger fires only for genuinely new mention
--     rows: mentions that survive an edit, removed mentions and handle
--     renames never notify.
--   - Skipped: self-mentions, unpublished sources (or an unpublished
--     parent post/comment), and a reply that mentions the parent
--     comment's author (create_community_reply already sends them a
--     comment_reply for that reply).
--   - At most one mention notification per recipient per source,
--     enforced by partial unique indexes (remove + re-add in a later
--     edit does not notify twice).
--   - list_my_community_notifications keeps its name, arguments and
--     existing columns, and adds actor_public_id / actor_avatar_path,
--     filled only when the actor is listed in
--     community_member_profiles_public. Auth ids and emails are never
--     returned.
--   - sync_community_mentions, the 8B-1 migration, and the existing
--     post/comment/reply/reaction RPCs are not modified.
-- ============================================================


-- ---------- community_notifications: columns and constraints ----------

alter table public.community_notifications
  alter column post_id drop not null;

alter table public.community_notifications
  drop constraint community_notifications_type_check;

alter table public.community_notifications
  add constraint community_notifications_type_check check (
    notification_type in (
      'comment_reply', 'post_reaction', 'comment_reaction',
      'mention_post', 'mention_comment', 'mention_reply',
      'follow'
    )
  );

alter table public.community_notifications
  drop constraint community_notifications_shape_check;

-- actor_user_id is deliberately not required here: deleting the actor's
-- account sets it to NULL. community_notifications_not_self_check is
-- unchanged.
alter table public.community_notifications
  add constraint community_notifications_shape_check check (
       (notification_type = 'comment_reply'
         and post_id is not null and comment_id is not null and reply_comment_id is not null)
    or (notification_type = 'post_reaction'
         and post_id is not null and comment_id is null and reply_comment_id is null)
    or (notification_type = 'comment_reaction'
         and post_id is not null and comment_id is not null and reply_comment_id is null)
    or (notification_type = 'mention_post'
         and post_id is not null and comment_id is null and reply_comment_id is null)
    or (notification_type = 'mention_comment'
         and post_id is not null and comment_id is not null and reply_comment_id is null)
    or (notification_type = 'mention_reply'
         and post_id is not null and comment_id is not null and reply_comment_id is not null)
    or (notification_type = 'follow'
         and post_id is null and comment_id is null and reply_comment_id is null)
  );


-- ---------- dedupe indexes ----------
-- Reaction/reply notifications keep their Phase 6C behaviour (no dedupe).

create unique index community_notifications_mention_post_key
  on public.community_notifications (recipient_user_id, post_id)
  where notification_type = 'mention_post';

create unique index community_notifications_mention_comment_key
  on public.community_notifications (recipient_user_id, comment_id)
  where notification_type = 'mention_comment';

create unique index community_notifications_mention_reply_key
  on public.community_notifications (recipient_user_id, reply_comment_id)
  where notification_type = 'mention_reply';

-- For 8C-3: at most one follow notification per follower/followed pair.
create unique index community_notifications_follow_key
  on public.community_notifications (recipient_user_id, actor_user_id)
  where notification_type = 'follow';


-- ---------- mention notification trigger ----------

create or replace function public.community_mentions_notify()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_author uuid;
  v_status text;
  v_post_id uuid;
  v_parent_id uuid;
  v_post_status text;
  v_parent_author uuid;
  v_parent_status text;
begin
  if new.post_id is not null then
    select p.user_id, p.status into v_author, v_status
      from public.community_posts p where p.id = new.post_id;
    if v_author is null or v_status is distinct from 'published'
       or v_author = new.mentioned_user_id then
      return null;
    end if;

    insert into public.community_notifications (
      recipient_user_id, actor_user_id, notification_type, post_id, comment_id, reply_comment_id
    ) values (
      new.mentioned_user_id, v_author, 'mention_post', new.post_id, null, null
    )
    on conflict do nothing;
    return null;
  end if;

  select c.user_id, c.status, c.post_id, c.parent_comment_id
    into v_author, v_status, v_post_id, v_parent_id
    from public.community_comments c where c.id = new.comment_id;
  if v_author is null or v_status is distinct from 'published'
     or v_author = new.mentioned_user_id then
    return null;
  end if;

  select p.status into v_post_status from public.community_posts p where p.id = v_post_id;
  if v_post_status is distinct from 'published' then
    return null;
  end if;

  if v_parent_id is null then
    insert into public.community_notifications (
      recipient_user_id, actor_user_id, notification_type, post_id, comment_id, reply_comment_id
    ) values (
      new.mentioned_user_id, v_author, 'mention_comment', v_post_id, new.comment_id, null
    )
    on conflict do nothing;
    return null;
  end if;

  select c.user_id, c.status into v_parent_author, v_parent_status
    from public.community_comments c where c.id = v_parent_id;
  if v_parent_status is distinct from 'published' then
    return null;
  end if;
  -- The parent comment's author already gets a comment_reply for this reply.
  if v_parent_author = new.mentioned_user_id then
    return null;
  end if;

  insert into public.community_notifications (
    recipient_user_id, actor_user_id, notification_type, post_id, comment_id, reply_comment_id
  ) values (
    new.mentioned_user_id, v_author, 'mention_reply', v_post_id, v_parent_id, new.comment_id
  )
  on conflict do nothing;
  return null;
end;
$$;

revoke all on function public.community_mentions_notify() from public, anon, authenticated;

create trigger community_mentions_notify
  after insert on public.community_mentions
  for each row execute function public.community_mentions_notify();


-- ---------- read model ----------
-- The return columns change, so the function is dropped and recreated
-- (same name and arguments). The existing three types behave exactly
-- as before.

drop function public.list_my_community_notifications(integer, timestamptz);

create function public.list_my_community_notifications(
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
  order by n.created_at desc, n.id desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

revoke all on function public.list_my_community_notifications(integer, timestamptz) from public, anon;
grant execute on function public.list_my_community_notifications(integer, timestamptz) to authenticated;
