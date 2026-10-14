-- ============================================================
-- Front Porch Recovery — Phase 0 schema
-- ============================================================
-- Backend foundation only: optional member accounts, admin
-- authorization, and moderated Porch Story submissions.
--
-- This does NOT touch the live site. index.html, sw.js, and all
-- existing public functionality are untouched by this file.
--
-- Run this once, top to bottom, in the Supabase SQL editor. It
-- creates things in dependency order: tables → is_admin() → the
-- policies that reference it → porch_stories → its public view →
-- submit_porch_story().
--
-- See the architecture doc for full rationale. In short:
--   - RLS is enabled and default-deny on every table: no policy
--     means no access, so a forgotten policy fails closed.
--   - profiles grants are column-level, not just row-level: a member
--     can SELECT their own row and UPDATE only display_name and
--     notification_prefs on it. membership_tier, id, and created_at
--     have no UPDATE grant at all for authenticated, so a client
--     that includes membership_tier in a PATCH gets a flat
--     "permission denied for column" — not a silently ignored field.
--   - porch_stories carries both public story content and private
--     submission/moderation data. Rather than relying on RLS alone
--     (which is row-level, not column-level) to keep the private
--     columns out of public hands, the anon key gets NO grant on
--     that table at all. Public reads go through a narrow view
--     (porch_stories_public) that simply does not include the
--     private columns. There is no policy to misconfigure.
--   - Submissions never use a raw INSERT. They go through
--     submit_porch_story(), whose parameter list has no moderation
--     fields (status, reviewed_at, reviewed_by, published_at) and
--     no client-supplied user_id — there is nothing for a client to
--     override. publishing_permission is enforced twice: a CHECK
--     constraint on the table, and an explicit guard raised inside
--     the function before it ever inserts anything.
--   - Function EXECUTE privileges are explicit, not left to
--     Supabase's defaults: submit_porch_story() revokes EXECUTE from
--     PUBLIC, anon, and authenticated by name, and grants it only to
--     service_role — which in practice means only the future
--     submission Edge Function. is_admin() is granted only to the
--     one role that ever actually needs to evaluate it
--     (authenticated — see its comment below for why not anon too).
--   - Admin status lives only in admin_users, never in profiles, so
--     a membership tier (billing) can never be mistaken for an
--     authorization grant (security). A Plus member cannot become
--     an admin through a billing change or a profiles edit.
--   - Free-text columns (display_name, title, story_body,
--     contact_email) carry trimmed-non-empty and max-length CHECK
--     constraints matching the live site's own form limits, so
--     obviously invalid content can't land in the database even if
--     frontend validation is bypassed entirely.
-- ============================================================


-- ---------- profiles ----------
-- One row per signed-up member. Optional: a visitor who never
-- creates an account has no row here, and every existing feature
-- (Recovery Counter, Daily Check-In, etc.) keeps working without one.

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  membership_tier text not null default 'free',
  notification_prefs jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.profiles
  add constraint profiles_membership_tier_check
  check (membership_tier in ('free', 'plus'));

alter table public.profiles enable row level security;

create policy "profiles_select_own"
  on public.profiles for select
  using (auth.uid() = id);

create policy "profiles_update_own"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- An admin-can-read-all policy is added further down, once
-- is_admin() exists for it to reference.

-- RLS alone only restricts which ROW a member can touch; membership_tier,
-- id, and created_at are still columns on that same row, so RLS by
-- itself cannot stop a member from including membership_tier in their
-- own update. Column-level grants close that gap: start from nothing,
-- then grant exactly what a signed-in member needs.
revoke all on table public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, notification_prefs) on public.profiles to authenticated;
-- No update grant on membership_tier, id, or created_at for authenticated
-- at all — not "restricted to the same value", genuinely absent. A
-- PATCH that includes membership_tier fails outright with "permission
-- denied for column membership_tier", the same way it would for any
-- other table a key has no business touching. Future billing/admin
-- code changes membership_tier through the service role, which bypasses
-- grants and RLS entirely, same as every other admin-only write path
-- in this schema.

-- Auto-create a profile row when someone signs up, so the app never
-- has to handle "signed in but no profile row yet" as a case.
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
    coalesce(new.raw_user_meta_data ->> 'display_name', 'New member')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ---------- admin_users ----------
-- Who can access the admin area. Kept separate from profiles so
-- admin status is never set by a billing or profile-edit flow —
-- only ever inserted manually from the Supabase dashboard.

create table public.admin_users (
  user_id uuid primary key references auth.users (id) on delete cascade,
  granted_at timestamptz not null default now(),
  granted_by text
);

alter table public.admin_users enable row level security;

-- A signed-in member can check only their own row (so the client can
-- show or hide the Admin nav link). No insert/update/delete policy
-- exists for anon or authenticated at all: writes only ever happen
-- from the Supabase dashboard using its own elevated access.
create policy "admin_users_select_own"
  on public.admin_users for select
  using (auth.uid() = user_id);

revoke all on table public.admin_users from anon, authenticated;
grant select on public.admin_users to authenticated;


-- ---------- is_admin() ----------
-- Single source of truth for "is this session an admin?", referenced
-- from every admin-only policy so admin access is defined once and
-- can't drift between tables.
--
--   - search_path is pinned (public, pg_temp) so the function can't
--     be tricked by a schema planted earlier in a caller's search
--     path; every table it touches is schema-qualified regardless.
--   - Owned by the migration/service role, not by anon or
--     authenticated, so an ordinary member can't redefine it.
--   - EXECUTE is granted only to authenticated, not anon and not
--     PUBLIC. anon has no grant anywhere that ever evaluates an
--     is_admin()-based policy — profiles and porch_stories both
--     withhold every anon grant outright — so anon genuinely never
--     needs to call this. Granting it anyway would just be an unused
--     privilege.
--   - Calling it only ever returns true or false; it never hands
--     back row data. It reads admin_users alone — membership tier
--     never enters the calculation.

create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select exists (
    select 1 from public.admin_users where user_id = auth.uid()
  );
$$;

revoke execute on function public.is_admin() from public;
revoke execute on function public.is_admin() from anon;
grant execute on function public.is_admin() to authenticated;

-- Now that is_admin() exists, let an admin session read every
-- profile (support/moderation use, not exposed in Phase 0 UI yet).
create policy "profiles_select_admin"
  on public.profiles for select
  using (public.is_admin());


-- ---------- porch_stories ----------
-- Every submission, public or not — including private fields
-- (contact_email, reviewed_by) that must never reach the anon key.

create table public.porch_stories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete set null,
  display_name text not null,
  title text not null,
  category text not null,
  story_body text not null,
  contact_email text,
  publishing_permission boolean not null default false,
  status text not null default 'pending',
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  published_at timestamptz,
  reviewed_by uuid references public.admin_users (user_id)
);

alter table public.porch_stories
  add constraint porch_stories_status_check
  check (status in ('pending', 'approved', 'published', 'rejected'));

alter table public.porch_stories
  add constraint porch_stories_category_check
  check (
    category in (
      'Recovery', 'Mental health', 'Rebuilding life', 'Relationships',
      'Grief / loss', 'Trauma / healing', 'Milestones', 'Hope',
      'Humor', 'Other'
    )
  );

-- No stored story without explicit publishing permission — enforced
-- here at the table level (defense-in-depth alongside the explicit
-- guard inside submit_porch_story() below). A row can never exist
-- with publishing_permission = false, not even transiently.
alter table public.porch_stories
  add constraint porch_stories_publishing_permission_check
  check (publishing_permission = true);

-- Content validation: trimmed-non-empty with a max length, matching
-- the live site's own form limits (index.html: #ps-name, #ps-title,
-- #ps-story, #ps-email) so an API call that bypasses the frontend
-- can't store something the form itself would have rejected.
alter table public.porch_stories
  add constraint porch_stories_display_name_check
  check (char_length(btrim(display_name)) > 0 and char_length(display_name) <= 80);

alter table public.porch_stories
  add constraint porch_stories_title_check
  check (char_length(btrim(title)) > 0 and char_length(title) <= 120);

alter table public.porch_stories
  add constraint porch_stories_story_body_check
  check (char_length(btrim(story_body)) > 0 and char_length(story_body) <= 8000);

alter table public.porch_stories
  add constraint porch_stories_contact_email_check
  check (
    contact_email is null
    or (char_length(btrim(contact_email)) > 0 and char_length(contact_email) <= 254)
  );

alter table public.porch_stories enable row level security;

-- Admins can see and update every row, any status.
create policy "porch_stories_admin_all"
  on public.porch_stories for all
  using (public.is_admin())
  with check (public.is_admin());

-- The anon key gets NO grant on this table at all — not even a
-- restrictive one. A non-admin authenticated user gets a table
-- grant (needed so the admin policy above has something to attach
-- to, since "authenticated" is one shared Postgres role for every
-- signed-in member, admin or not) but no row ever matches for them,
-- because porch_stories_admin_all is the only policy and it
-- requires is_admin(). Net effect: nobody except an admin session,
-- or the service role inside submit_porch_story(), can read or
-- write a row here, directly, under any circumstance.
revoke all on table public.porch_stories from anon, authenticated;
grant select, update on public.porch_stories to authenticated;


-- ---------- porch_stories_public (view) ----------
-- The only way the public — or a signed-in, non-admin member — ever
-- reads a story. Only these six columns exist on it; contact_email,
-- user_id, reviewed_by, and every other private or moderation column
-- simply isn't selectable through it, so there's no RLS policy here
-- to get wrong.

create view public.porch_stories_public as
select id, display_name, title, category, story_body, published_at
from public.porch_stories
where status = 'published';

-- Explicit, not left to Supabase's per-schema default grants: without the
-- revoke below, anon/authenticated end up with INSERT/UPDATE/DELETE on
-- this view too (Supabase grants those by default to every new relation
-- in the public schema so PostgREST works out of the box). Because this
-- is a plain, single-table view with no aggregates/joins, Postgres treats
-- it as automatically updatable — so without this revoke, anon could
-- write straight through the view into porch_stories, bypassing
-- submit_porch_story() and the admin-only RLS policy entirely. (INSERT
-- happens to be blocked anyway by the publishing_permission CHECK
-- constraint, since the view doesn't expose that column so it always
-- defaults to false — but UPDATE and DELETE are not, and were confirmed
-- exploitable before this revoke was added.) Same pattern as the base
-- table above: start from nothing, then grant back only select.
revoke all on public.porch_stories_public from anon, authenticated;
grant select on public.porch_stories_public to anon, authenticated;


-- ---------- submit_porch_story() ----------
-- The only way a story gets inserted. Its parameter list has no
-- moderation fields — status, reviewed_at, reviewed_by, and
-- published_at simply aren't parameters, so there's nothing for a
-- submitter to override. status is hard-coded 'pending'.
--
-- p_user_id is a plain parameter, NOT auth.uid() — this function is
-- only ever called by the submission Edge Function's service-role
-- client, and a service-role client has no caller JWT context, so
-- auth.uid() would just be null regardless of who actually
-- submitted the story. The Edge Function validates the caller's JWT
-- itself (or determines there isn't one) before calling this, and
-- passes the verified user id — or null for an anonymous submission
-- — as p_user_id. See supabase/README.md for the full contract this
-- function expects the Edge Function to follow.
--
-- p_publishing_permission has no default — it's a required, explicit
-- choice, not something that can be silently omitted. The function
-- also raises on anything but true, so a caller gets an immediate,
-- specific error rather than a silent insert that the table's CHECK
-- constraint would have blocked anyway: two layers, two different
-- failure modes, same rule.

create or replace function public.submit_porch_story(
  p_display_name text,
  p_title text,
  p_category text,
  p_story_body text,
  p_publishing_permission boolean,
  p_user_id uuid default null,
  p_contact_email text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_id uuid;
begin
  if p_publishing_permission is not true then
    raise exception 'Publishing permission is required to submit a Porch Story.'
      using errcode = '23514'; -- check_violation, same class the table's own CHECK would raise
  end if;

  insert into public.porch_stories (
    user_id, display_name, title, category, story_body,
    contact_email, publishing_permission, status
  ) values (
    p_user_id, p_display_name, p_title, p_category, p_story_body,
    p_contact_email, p_publishing_permission, 'pending'
  )
  returning id into new_id;

  return new_id;
end;
$$;

-- Explicit, not left to Supabase's defaults: name every role this
-- revokes from, then grant to exactly the one role that should ever
-- call it. The future submission Edge Function uses a service-role
-- client specifically so this grant is the only path in.
revoke execute on function public.submit_porch_story from public;
revoke execute on function public.submit_porch_story from anon;
revoke execute on function public.submit_porch_story from authenticated;
grant execute on function public.submit_porch_story to service_role;


-- ============================================================
-- NOT created in Phase 0
-- ============================================================
-- community_posts, post_comments, post_reactions, post_reports, and
-- any Stripe/payment tables are intentionally left out of this
-- migration — see the architecture doc, section 2, for their
-- documented shape. Creating them is a later phase's migration, not
-- a redesign of anything above. When that phase begins, each new
-- table should follow the same pattern used here: RLS enabled and
-- default-deny, column-level grants wherever a member-editable table
-- has admin-only or system-only columns, CHECK constraints on every
-- controlled value (e.g. post_type) and on free-text content length,
-- and writes funneled through a function or Edge Function with
-- explicit, named EXECUTE grants rather than a raw anon INSERT.
-- ============================================================
