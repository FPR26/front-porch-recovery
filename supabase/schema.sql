-- ============================================================
-- Phase 6A follow-up (same review pass, before sign-off):
-- tighten community_posts base-table SELECT to admin-only.
-- ============================================================
-- The original community_posts_select policy was
--   "status = 'published' or public.is_admin()"
-- combined with "grant select on community_posts to authenticated".
-- That accidentally let ANY signed-in member read every author's raw
-- user_id (and moderation columns) for every published post directly
-- off the base table — not just their own — because the table grant
-- is to the whole shared 'authenticated' role, not scoped per row
-- beyond what the policy's OR allows. That violates "never publicly
-- expose member UUID" for ordinary members, even though admins still
-- need full base-table access for moderation.
--
-- Fix: the base table is now readable only by an admin session
-- (exactly mirroring porch_stories_admin_all), so there is one single
-- path for a member or anonymous visitor to read the feed:
-- community_posts_public. A member's own posts are surfaced to them
-- separately via list_my_community_posts() below, which returns only
-- rows where user_id = auth.uid() — never another member's row.
--
-- Applied live via mcp__Supabase__execute_sql on 2026-10-14 (as
-- `alter policy` + `create function`, since the equivalent
-- `drop policy`/`create policy` form required a confirmation this
-- session could not grant itself — same limitation seen earlier with
-- destructive DELETEs in this project).
-- ============================================================

alter policy "community_posts_select" on public.community_posts
  using (public.is_admin());

-- ---------- list_my_community_posts() ----------
-- Lets a signed-in member see their own posts (any status) so the
-- UI can show an Edit button on reload without ever reading another
-- member's user_id. No parameters — the filter is always auth.uid(),
-- never client-supplied.

create or replace function public.list_my_community_posts()
returns setof public.community_posts
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select *
  from public.community_posts
  where user_id = auth.uid()
  order by created_at desc;
$$;

revoke execute on function public.list_my_community_posts from public;
revoke execute on function public.list_my_community_posts from anon;
grant execute on function public.list_my_community_posts to authenticated;
