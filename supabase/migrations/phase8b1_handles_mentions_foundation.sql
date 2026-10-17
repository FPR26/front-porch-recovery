-- ============================================================
-- Phase 8B-1: member handles + @mention foundation (database only)
-- ============================================================
-- Adds unique public handles to profiles, handle RPCs (set, check,
-- autocomplete search), handle on the safe profile view, an admin
-- handle reset, and normalized @mention storage for posts, comments
-- and replies, kept in sync by triggers, with a safe public read view.
-- No UI and no notifications in this phase (8B-2..4 / 8C).
--
-- Rules this migration enforces:
--   - Handles are stored lowercase, 3-24 chars, ^[a-z][a-z0-9_]{2,23}$,
--     no "__", no trailing "_", never a reserved name/prefix. A plain
--     unique index on the stored value makes uniqueness
--     case-insensitive and race-safe.
--   - Handles are set only through set_my_handle() (direct profile
--     UPDATE stays revoked). The first handle can be set any time; a
--     later change needs 30 days since handle_changed_at. Old handles
--     are not reserved: each mention row stores the member it named
--     when written, so old content never re-points to a new owner.
--   - Auth user ids stay internal. Public outputs use profiles.public_id.
--   - community_mentions has no table privileges for anon or
--     authenticated; rows are written only by the sync triggers.
--   - community_mentions_public only shows mentions inside content the
--     existing public post/comment views already show.
-- ============================================================


-- ---------- handle validation helpers ----------

create or replace function public.is_valid_handle(p_handle text)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select p_handle is not null
     and p_handle ~ '^[a-z][a-z0-9_]{2,23}$'
     and position('__' in p_handle) = 0
     and right(p_handle, 1) <> '_';
$$;

create or replace function public.is_reserved_handle(p_handle text)
returns boolean
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select p_handle = any (array[
           'admin', 'administrator', 'mod', 'moderator', 'staff', 'support',
           'help', 'system', 'root', 'owner', 'team', 'official', 'security',
           'everyone', 'here', 'all', 'anonymous', 'null', 'undefined', 'api',
           'settings', 'community', 'member', 'members', 'porch', 'frontporch',
           'frontporchrecovery', 'fpr', 'notifications'])
      or left(p_handle, 5) = 'admin'
      or left(p_handle, 4) = 'mod_'
      or left(p_handle, 10) = 'frontporch'
      or left(p_handle, 4) = 'fpr_';
$$;

-- Pure helpers used by the profiles_handle_check constraint and the
-- handle RPCs. Kept callable by the roles that can write profiles.
revoke execute on function public.is_valid_handle from public, anon;
revoke execute on function public.is_reserved_handle from public, anon;
grant execute on function public.is_valid_handle to authenticated, service_role;
grant execute on function public.is_reserved_handle to authenticated, service_role;


-- ---------- profiles: handle columns ----------

alter table public.profiles
  add column handle text,
  add column handle_changed_at timestamptz;

alter table public.profiles
  add constraint profiles_handle_check
  check (handle is null or (public.is_valid_handle(handle) and not public.is_reserved_handle(handle)));

create unique index profiles_handle_key on public.profiles (handle) where handle is not null;

-- Prefix lookups for autocomplete (LIKE 'abc%').
create index profiles_handle_prefix_idx on public.profiles (handle text_pattern_ops) where handle is not null;


-- ---------- community_member_profiles_public: + handle ----------
-- Same columns, filters and recovery-date rules as Phase 7A, with
-- handle appended at the end.

create or replace view public.community_member_profiles_public as
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
  end as recovery_date,
  p.handle
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


-- ---------- set_my_handle() ----------

create or replace function public.set_my_handle(p_handle text)
returns table (handle text, handle_changed_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  v_handle text := lower(btrim(coalesce(p_handle, '')));
  v_current text;
  v_changed timestamptz;
begin
  if caller_id is null then
    raise exception 'Sign in required to set a handle.' using errcode = '42501';
  end if;

  if not public.is_valid_handle(v_handle) then
    raise exception 'Handles are 3 to 24 characters: letters, numbers and single underscores, starting with a letter.'
      using errcode = '22023';
  end if;
  if public.is_reserved_handle(v_handle) then
    raise exception 'That handle isn''t available.' using errcode = '22023';
  end if;

  select p.handle, p.handle_changed_at into v_current, v_changed
    from public.profiles p where p.id = caller_id for update;
  if not found then
    raise exception 'Profile not found.' using errcode = 'P0002';
  end if;

  if v_current is not distinct from v_handle then
    return query select p.handle, p.handle_changed_at from public.profiles p where p.id = caller_id;
    return;
  end if;

  if v_current is not null and v_changed is not null and v_changed > now() - interval '30 days' then
    raise exception 'You can change your handle again after %.', to_char(v_changed + interval '30 days', 'FMMonth FMDD, YYYY')
      using errcode = '22023';
  end if;

  begin
    update public.profiles
      set handle = v_handle, handle_changed_at = now()
      where id = caller_id;
  exception
    when unique_violation then
      raise exception 'That handle is taken.' using errcode = '23505';
  end;

  return query select p.handle, p.handle_changed_at from public.profiles p where p.id = caller_id;
end;
$$;

revoke execute on function public.set_my_handle from public;
revoke execute on function public.set_my_handle from anon;
grant execute on function public.set_my_handle to authenticated;


-- ---------- check_handle_availability() ----------
-- 'available' | 'taken' | 'invalid' | 'reserved' | 'cooldown'.
-- Your own current handle reports 'available'.

create or replace function public.check_handle_availability(p_handle text)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  v_handle text := lower(btrim(coalesce(p_handle, '')));
  v_current text;
  v_changed timestamptz;
begin
  if caller_id is null then
    raise exception 'Sign in required.' using errcode = '42501';
  end if;

  if not public.is_valid_handle(v_handle) then return 'invalid'; end if;
  if public.is_reserved_handle(v_handle) then return 'reserved'; end if;

  select p.handle, p.handle_changed_at into v_current, v_changed
    from public.profiles p where p.id = caller_id;
  if v_current is not distinct from v_handle then return 'available'; end if;

  if exists (select 1 from public.profiles p where p.handle = v_handle) then return 'taken'; end if;

  if v_current is not null and v_changed is not null and v_changed > now() - interval '30 days' then
    return 'cooldown';
  end if;
  return 'available';
end;
$$;

revoke execute on function public.check_handle_availability from public;
revoke execute on function public.check_handle_availability from anon;
grant execute on function public.check_handle_availability to authenticated;


-- ---------- search_member_handles() ----------
-- Autocomplete only: signed-in, at least 2 characters, at most 8
-- results, handle-prefix match among members listed in
-- community_member_profiles_public (published content, or yourself).

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
  where auth.uid() is not null
    and char_length(q.v) between 2 and 24
    and q.v ~ '^[a-z][a-z0-9_]*$'
  order by (m.handle = q.v) desc, m.handle
  limit 8;
$$;

revoke execute on function public.search_member_handles from public;
revoke execute on function public.search_member_handles from anon;
grant execute on function public.search_member_handles to authenticated;


-- ---------- moderate_member_profile(): + reset_handle ----------
-- Same as Phase 7A, plus 'reset_handle' (handle -> NULL). Admins can
-- clear a handle but never assign one.

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
  elsif p_action = 'reset_handle' then
    update public.profiles set handle = null, handle_changed_at = now() where public_id = p_public_id;
  else
    raise exception 'Unknown profile moderation action: %', p_action using errcode = '22023';
  end if;

  if not found then
    raise exception 'Profile not found.' using errcode = 'P0002';
  end if;
  return true;
end;
$$;


-- ---------- community_mentions ----------

create table public.community_mentions (
  id uuid primary key default gen_random_uuid(),
  post_id uuid references public.community_posts (id) on delete cascade,
  comment_id uuid references public.community_comments (id) on delete cascade,
  mentioned_user_id uuid not null references auth.users (id) on delete cascade,
  handle_at_write text not null,
  created_at timestamptz not null default now(),
  constraint community_mentions_one_source_check check ((post_id is null) <> (comment_id is null))
);

create unique index community_mentions_post_member_key
  on public.community_mentions (post_id, mentioned_user_id) where post_id is not null;
create unique index community_mentions_comment_member_key
  on public.community_mentions (comment_id, mentioned_user_id) where comment_id is not null;
create index community_mentions_mentioned_user_idx on public.community_mentions (mentioned_user_id);

alter table public.community_mentions enable row level security;

revoke all on table public.community_mentions from anon, authenticated;


-- ---------- mention parsing + sync ----------
-- A mention is "@handle" not preceded by a letter, digit, '_', '.' or
-- '@' (so emails like a@b.com never match) and not followed by another
-- handle character. Handles are lowercased, duplicates collapse, and
-- order of first appearance is kept so the 10-per-source cap keeps the
-- earliest mentions.

create or replace function public.extract_mention_handles(p_body text)
returns text[]
language sql
immutable
set search_path = pg_catalog, pg_temp
as $$
  select coalesce(array_agg(h order by first_pos), '{}')
  from (
    select lower(m[1]) as h, min(pos) as first_pos
    from regexp_matches(coalesce(p_body, ''), '(?<![A-Za-z0-9_.@])@([A-Za-z][A-Za-z0-9_]{2,23})(?![A-Za-z0-9_])', 'g')
      with ordinality as t(m, pos)
    group by lower(m[1])
  ) x;
$$;

revoke execute on function public.extract_mention_handles from public, anon, authenticated;

-- Replaces a source's mention rows with the members its body mentions
-- now (current handles only, at most 10). Rows for members still
-- mentioned are kept as they were, so their handle_at_write and
-- created_at stay bound to the original write.
create or replace function public.sync_community_mentions(p_post_id uuid, p_comment_id uuid, p_body text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ids uuid[];
  v_handles text[];
begin
  select coalesce(array_agg(w.user_id order by w.ord), '{}'), coalesce(array_agg(w.handle order by w.ord), '{}')
    into v_ids, v_handles
  from (
    select p.id as user_id, p.handle, x.ord
    from unnest(public.extract_mention_handles(p_body)) with ordinality as x(h, ord)
    join public.profiles p on p.handle = x.h
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

revoke execute on function public.sync_community_mentions from public, anon, authenticated;

create or replace function public.community_posts_sync_mentions()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and new.body is not distinct from old.body then
    return null;
  end if;
  perform public.sync_community_mentions(new.id, null, new.body);
  return null;
end;
$$;

create or replace function public.community_comments_sync_mentions()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and new.body is not distinct from old.body then
    return null;
  end if;
  perform public.sync_community_mentions(null, new.id, new.body);
  return null;
end;
$$;

revoke execute on function public.community_posts_sync_mentions from public, anon, authenticated;
revoke execute on function public.community_comments_sync_mentions from public, anon, authenticated;

create trigger community_posts_sync_mentions
  after insert or update of body on public.community_posts
  for each row execute function public.community_posts_sync_mentions();

create trigger community_comments_sync_mentions
  after insert or update of body on public.community_comments
  for each row execute function public.community_comments_sync_mentions();


-- ---------- community_mentions_public (view) ----------
-- Only mentions inside content the public post/comment views already
-- show. post_id is the post the mention belongs to (for a comment or
-- reply mention, its parent post), so a client can load a post's and
-- all its comments' mentions with one filter on post_id. Never exposes
-- the auth id: the mentioned member is identified by public_id.

create view public.community_mentions_public as
select
  coalesce(m.post_id, cc.post_id) as post_id,
  m.comment_id,
  m.handle_at_write as handle,
  pr.public_id as mentioned_public_id
from public.community_mentions m
join public.profiles pr on pr.id = m.mentioned_user_id
left join public.community_posts_public pp on pp.id = m.post_id
left join public.community_comments_public cc on cc.id = m.comment_id
where (m.post_id is not null and pp.id is not null)
   or (m.comment_id is not null and cc.id is not null);

revoke all on public.community_mentions_public from anon, authenticated;
grant select on public.community_mentions_public to anon, authenticated;
