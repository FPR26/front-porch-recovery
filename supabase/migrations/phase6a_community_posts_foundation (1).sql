-- ============================================================
-- Phase 6A: Community posts foundation
-- ============================================================
-- Adds the member community feature's database layer: a single
-- plain-text post type with three states (published/hidden/removed),
-- a public read view, and three SECURITY DEFINER RPCs that are the
-- only way any row is ever created, edited, or moderated. No raw
-- INSERT/UPDATE/DELETE grant exists on community_posts for anyone,
-- admin included — every write funnels through a function that
-- derives identity from auth.uid() and enforces its own state
-- machine, the same posture Phase 4 moved porch_stories to.
--
-- Hard privacy boundary: this table only ever stores user_id + the
-- post body + status/timestamps. It has no column, trigger, or
-- function that reads or writes Recovery Counter, Check-In, mood,
-- craving, reflection, gratitude, or rough-day data — none of that
-- local/private recovery data has any code path into Supabase at
-- all from this migration.
--
-- Applied live via mcp__Supabase__apply_migration on 2026-10-14.
-- ============================================================


-- ---------- community_posts ----------

create table public.community_posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  body text not null,
  status text not null default 'published',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  edited_at timestamptz,
  moderated_at timestamptz,
  moderated_by uuid references public.admin_users (user_id)
);

alter table public.community_posts
  add constraint community_posts_status_check
  check (status in ('published', 'hidden', 'removed'));

-- Plain-text content limit, enforced here (not just in the UI):
-- trimmed-non-empty, max 2,000 characters. No HTML is ever accepted
-- or rendered for this field anywhere in the app.
alter table public.community_posts
  add constraint community_posts_body_check
  check (char_length(btrim(body)) > 0 and char_length(body) <= 2000);

alter table public.community_posts enable row level security;

-- One select policy covers both a member reading the published feed
-- and an admin reading everything (including hidden/removed, for
-- moderation). There is deliberately no insert/update/delete policy
-- for anyone, admin included: every write goes through a function
-- below instead, so there's no write-side RLS policy to misconfigure.
create policy "community_posts_select"
  on public.community_posts for select
  using (status = 'published' or public.is_admin());

-- anon gets no grant on this table at all (public reads only ever
-- happen through community_posts_public below). authenticated gets
-- SELECT only — never insert/update/delete — because every write,
-- member or admin, happens inside a SECURITY DEFINER function that
-- runs as the function owner and bypasses grants entirely.
revoke all on table public.community_posts from anon, authenticated;
grant select on table public.community_posts to authenticated;


-- ---------- community_posts_public (view) ----------
-- The only way anonymous visitors, or a signed-in non-admin member,
-- ever read the community feed. Only these five columns exist on it
-- — user_id, moderated_by, and every other private/moderation column
-- simply isn't selectable through it. display_name is resolved from
-- profiles with a neutral fallback so a member who never set one
-- doesn't show up as their email or UUID (neither of which is ever
-- selected into this view in the first place).

create view public.community_posts_public as
select
  cp.id,
  cp.body,
  cp.created_at,
  cp.updated_at,
  cp.edited_at,
  coalesce(p.display_name, 'Community member') as display_name
from public.community_posts cp
left join public.profiles p on p.id = cp.user_id
where cp.status = 'published';

-- Same explicit revoke-then-grant as porch_stories_public: Supabase's
-- default per-schema grants would otherwise leave anon/authenticated
-- with INSERT/UPDATE/DELETE on this automatically-updatable view,
-- which would let a write bypass the RPCs and RLS entirely.
revoke all on public.community_posts_public from anon, authenticated;
grant select on public.community_posts_public to anon, authenticated;


-- ---------- create_community_post() ----------
-- The only way a post is ever inserted. user_id is never a
-- parameter — it is always auth.uid(), so there is no code path for
-- a client to post as someone else. status is hard-coded
-- 'published'; timestamps are server-generated.

create or replace function public.create_community_post(
  p_body text
)
returns public.community_posts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  result_row public.community_posts;
begin
  if caller_id is null then
    raise exception 'Sign in required to post to the community.'
      using errcode = '42501';
  end if;

  if p_body is null or char_length(btrim(p_body)) = 0 then
    raise exception 'Post text is required.' using errcode = '22023';
  end if;
  if char_length(p_body) > 2000 then
    raise exception 'Post text must be 2,000 characters or fewer.' using errcode = '22023';
  end if;

  insert into public.community_posts (user_id, body, status)
  values (caller_id, btrim(p_body), 'published')
  returning * into result_row;

  return result_row;
end;
$$;

revoke execute on function public.create_community_post from public;
revoke execute on function public.create_community_post from anon;
grant execute on function public.create_community_post to authenticated;


-- ---------- edit_community_post() ----------
-- A member may change only the body of their own, currently
-- published, post. status/user_id/moderation fields are not
-- parameters and so can never be set here; ownership and current
-- status are both checked server-side against the stored row, never
-- trusted from the client.

create or replace function public.edit_community_post(
  p_post_id uuid,
  p_body text
)
returns public.community_posts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  current_row public.community_posts;
  result_row public.community_posts;
begin
  if caller_id is null then
    raise exception 'Sign in required to edit a post.' using errcode = '42501';
  end if;

  select * into current_row from public.community_posts where id = p_post_id for update;
  if current_row.id is null then
    raise exception 'Post not found.' using errcode = 'P0002';
  end if;

  if current_row.user_id <> caller_id then
    raise exception 'You may only edit your own post.' using errcode = '42501';
  end if;

  if current_row.status <> 'published' then
    raise exception 'A % post cannot be edited.', current_row.status
      using errcode = '22023';
  end if;

  if p_body is null or char_length(btrim(p_body)) = 0 then
    raise exception 'Post text is required.' using errcode = '22023';
  end if;
  if char_length(p_body) > 2000 then
    raise exception 'Post text must be 2,000 characters or fewer.' using errcode = '22023';
  end if;

  update public.community_posts
    set body = btrim(p_body), updated_at = now(), edited_at = now()
    where id = p_post_id
    returning * into result_row;

  return result_row;
end;
$$;

revoke execute on function public.edit_community_post from public;
revoke execute on function public.edit_community_post from anon;
grant execute on function public.edit_community_post to authenticated;


-- ---------- moderate_community_post() ----------
-- Admin only (checked with is_admin(), the same single source of
-- truth every other admin-only path in this schema uses).
-- moderated_by is always auth.uid(), moderated_at is always now() —
-- neither is ever client-supplied. Status transitions are restricted
-- to exactly:
--   published -> hidden, published -> removed,
--   hidden -> published (restore), hidden -> removed.
-- Nothing reachable out of 'removed' (no removed -> published, no
-- removed -> hidden) and no hard delete anywhere in this function.

create or replace function public.moderate_community_post(
  p_post_id uuid,
  p_action text
)
returns public.community_posts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  admin_id uuid := auth.uid();
  current_row public.community_posts;
  result_row public.community_posts;
begin
  if admin_id is null or not public.is_admin() then
    raise exception 'Only an authenticated admin may moderate community posts.'
      using errcode = '42501';
  end if;

  select * into current_row from public.community_posts where id = p_post_id for update;
  if current_row.id is null then
    raise exception 'Post not found.' using errcode = 'P0002';
  end if;

  if p_action = 'hide' then
    if current_row.status <> 'published' then
      raise exception 'Only a published post can be hidden (current status: %).', current_row.status
        using errcode = '22023';
    end if;
    update public.community_posts
      set status = 'hidden', moderated_at = now(), moderated_by = admin_id
      where id = p_post_id
      returning * into result_row;

  elsif p_action = 'restore' then
    if current_row.status <> 'hidden' then
      raise exception 'Only a hidden post can be restored (current status: %).', current_row.status
        using errcode = '22023';
    end if;
    update public.community_posts
      set status = 'published', moderated_at = now(), moderated_by = admin_id
      where id = p_post_id
      returning * into result_row;

  elsif p_action = 'remove' then
    if current_row.status not in ('published', 'hidden') then
      raise exception 'A % post cannot be removed.', current_row.status
        using errcode = '22023';
    end if;
    update public.community_posts
      set status = 'removed', moderated_at = now(), moderated_by = admin_id
      where id = p_post_id
      returning * into result_row;

  else
    raise exception 'Unknown moderation action: %', p_action using errcode = '22023';
  end if;

  return result_row;
end;
$$;

revoke execute on function public.moderate_community_post from public;
revoke execute on function public.moderate_community_post from anon;
revoke execute on function public.moderate_community_post from authenticated;
grant execute on function public.moderate_community_post to authenticated;
