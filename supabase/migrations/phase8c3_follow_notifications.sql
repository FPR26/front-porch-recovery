-- ============================================================
-- Phase 8C-3: follow notifications (database only)
-- ============================================================
-- When a member follows someone, the followed member gets an in-app
-- 'follow' notification identifying the follower. Unfollowing removes
-- that notification; following again later creates a fresh one.
-- Following lists stay private: no public lists, counts or directory.
--
-- Rules this migration enforces:
--   - member_follows is the source of truth. follow_member and
--     unfollow_member are not modified: follow_member inserts with
--     ON CONFLICT DO NOTHING, so the insert trigger fires only for a
--     genuinely new follow.
--   - The 8C-1 partial unique index community_notifications_follow_key
--     (recipient_user_id, actor_user_id) WHERE notification_type =
--     'follow' keeps at most one follow notification per pair.
--   - Unfollow removes only the matching follow notification for that
--     pair, read or unread. Nothing else is touched.
--   - Self-follow is already impossible (member_follows_not_self_check).
--   - The read model (list_my_community_notifications, 8C-1) already
--     returns follow rows: no post/comment ids, no excerpt, actor fields
--     only when the actor is listed, target_available = actor listed.
-- ============================================================


-- ---------- new follow -> notification ----------

create or replace function public.member_follows_notify_insert()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.community_notifications (
    recipient_user_id, actor_user_id, notification_type, post_id, comment_id, reply_comment_id
  ) values (
    new.followed_user_id, new.follower_user_id, 'follow', null, null, null
  )
  on conflict do nothing;
  return null;
end;
$$;

revoke all on function public.member_follows_notify_insert() from public, anon, authenticated;

create trigger member_follows_notify_insert
  after insert on public.member_follows
  for each row execute function public.member_follows_notify_insert();


-- ---------- unfollow -> remove that pair's follow notification ----------

create or replace function public.member_follows_notify_delete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.community_notifications n
  where n.notification_type = 'follow'
    and n.recipient_user_id = old.followed_user_id
    and n.actor_user_id = old.follower_user_id;
  return null;
end;
$$;

revoke all on function public.member_follows_notify_delete() from public, anon, authenticated;

create trigger member_follows_notify_delete
  after delete on public.member_follows
  for each row execute function public.member_follows_notify_delete();
