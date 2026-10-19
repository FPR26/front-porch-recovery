# Front Porch Recovery — Supabase backend

The Supabase backend for the live site (https://fpr26.github.io/front-porch-recovery/). Phases 0 through 7 are complete and deployed: Porch Story submission and moderation, optional magic-link member accounts, the member Community (posts, comments and one-level replies, reactions, in-app notifications, post search, member reporting, and admin moderation), and member profiles. See "What's next" at the end for the per-phase status.

See the architecture doc for the full plan, the phased migration, and the reasoning behind each design choice. This file covers how each phase's database layer works and how it was verified, starting with Phase 0.

## What `schema.sql` creates

- `profiles`, `admin_users`, `porch_stories` tables
- `porch_stories_public` view — the *only* way anyone reads a story publicly or as a non-admin member
- `is_admin()` and `submit_porch_story()` functions
- RLS policies, column-level and function-level grants/revokes, and `CHECK` constraints for all of the above
- An `on_auth_user_created` trigger that creates a `profiles` row automatically on sign-up

That list is the Phase 0 base schema, recorded in the live project's migration history as `phase0_fpr_schema`. Later phases added the Community: posts (Phase 6A), comments, replies and reports (Phase 6B), and reactions and notifications (Phase 6C) — see those sections below and the files in `migrations/`. Note that the repository's `schema.sql` currently contains only the Phase 6A member-read fix (identical to `migrations/phase6a_community_posts_member_read_fix.sql`), not the Phase 0 base schema. DMs, follows, anonymous posting, uploads, and groups are still **not** created.

## Running the migration

1. Create a new Supabase project (or use an existing one dedicated to FPR).
2. In the SQL editor, run `schema.sql` once, top to bottom. It's written in dependency order, so a single run should succeed without manual reordering.
3. Spot-check: `select * from public.porch_stories_public;` should return an empty result with no error (RLS and the view are both in place, there's just no data yet).

## Where the anon key goes

Project Settings → API → the `anon` `public` key. This is the **only** Supabase key ever meant to ship in client-side code (added to `index.html` in Phase 1, not this one). It's safe to embed precisely because every table it can touch is locked down by the grants and RLS policies in `schema.sql`.

**Never** put the `service_role` key in any file served to a browser. It belongs only in Supabase Edge Function secrets (Project Settings → Edge Functions → Secrets), starting when the submission Edge Function is built (Phase 3 of the migration plan).

## Granting the first admin

There's no self-service way to become an admin, by design — `admin_users` has no insert policy for any key. To grant yourself (Justin) admin access once you have a `auth.users` row (after signing up through the site in Phase 1, or by creating a user manually in the dashboard):

```sql
insert into public.admin_users (user_id, granted_by)
values ('<your auth.users id>', 'manual, initial setup');
```

Find your `auth.users` id under Authentication → Users in the Supabase dashboard.

## Members can't change their own membership_tier

RLS restricts which **row** a member can update (their own); it says nothing about which **columns** on that row. `membership_tier`, `id`, and `created_at` are on the same row as `display_name` and `notification_prefs`, so RLS alone can't stop a member from including `membership_tier` in their own update.

`schema.sql` closes that with column-level grants instead of relying on RLS for this:

```sql
revoke all on table public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, notification_prefs) on public.profiles to authenticated;
```

`authenticated` has no `UPDATE` privilege on `membership_tier`, `id`, or `created_at` at all — not "allowed only to set it to the same value," genuinely no privilege. A PATCH request that includes `membership_tier` fails outright with `permission denied for column membership_tier`, the same way it would for a table the key has no business touching, rather than silently dropping just that field. Future billing or admin code changes `membership_tier` through the service role, which bypasses grants and RLS entirely, the same as every other admin-only write path in this schema.

## Porch Stories: `publishing_permission` is required, in two layers

The architecture is explicit that a story can't be stored without permission to publish it. That's enforced twice, not once:

1. **Table-level `CHECK` constraint** — `porch_stories_publishing_permission_check` requires `publishing_permission = true` on every row, permanently. A row can never exist with it `false`, not even transiently.
2. **Explicit guard inside `submit_porch_story()`** — the function raises immediately if `p_publishing_permission is not true`, before it attempts any insert:

```sql
if p_publishing_permission is not true then
  raise exception 'Publishing permission is required to submit a Porch Story.'
    using errcode = '23514';
end if;
```

The parameter also has **no default** (it's `p_publishing_permission boolean`, not `... default false`), so omitting it is a clear error rather than a silent false. Belt and suspenders: the function gives a specific, readable error for the Edge Function to surface to the submitter; the `CHECK` constraint is the backstop if anything ever calls the insert path some other way.

## Story submissions: how `user_id` gets set safely

`submit_porch_story()` takes `p_user_id` as a plain parameter — it deliberately does **not** use `auth.uid()`. The function is only ever called by the future submission Edge Function using its **service-role** client, and a service-role client has no caller identity of its own: `auth.uid()` would just evaluate to `null` no matter who actually submitted the story, which would silently turn every authenticated submission into an anonymous one.

Identity has to come from the Edge Function instead, which validates it itself, server-side, before calling the database:

1. Read the `Authorization` header off the incoming request, if the client sent one.
2. If present, validate it server-side — e.g. `supabase.auth.getUser(token)` against the project's own Auth server — rather than trusting it blindly.
3. A valid token → `p_user_id` = that verified user's id. No token, or an invalid one → `p_user_id` = `null` (anonymous submission).
4. Call `submit_porch_story()` with the service-role client, passing that verified id.

A submitter can never set their own `user_id`: the Edge Function never reads a `user_id` field out of the client's request body at all, trusted or not — the only id it ever uses is the one it just verified itself.

```ts
// submission Edge Function, pseudocode — built in Phase 3 alongside
// wiring the Porch Story form to Supabase. schema.sql is the
// contract it must follow; this isn't deployed by Phase 0.
const authHeader = req.headers.get('Authorization');
let userId: string | null = null;

if (authHeader) {
  const token = authHeader.replace('Bearer ', '');
  const { data, error } = await supabaseAnon.auth.getUser(token);
  if (!error && data.user) userId = data.user.id;
  // an invalid/expired token leaves userId as null — never guessed,
  // never taken from the request body
}

const allowed = await checkRateLimit({ ip: requestIp, userId });
if (!allowed) return new Response('Too many requests', { status: 429 });

const { data: storyId, error } = await supabaseServiceRole.rpc('submit_porch_story', {
  p_display_name: body.displayName,
  p_title: body.title,
  p_category: body.category,
  p_story_body: body.story,
  p_publishing_permission: body.publishingPermission === true, // required — no default
  p_user_id: userId,               // verified above — never body.userId
  p_contact_email: body.contactEmail ?? null,
});

if (error) {
  // body.publishingPermission false/missing surfaces here as a
  // 23514 check_violation from the explicit guard above — map it
  // to a clear 400 for the submitter rather than a generic 500.
  return new Response('Could not save your story.', { status: 400 });
}
```

## Function privileges are explicit, not left to defaults

`submit_porch_story()` doesn't rely on whatever Supabase grants by default — `schema.sql` names every role:

```sql
revoke execute on function public.submit_porch_story from public;
revoke execute on function public.submit_porch_story from anon;
revoke execute on function public.submit_porch_story from authenticated;
grant execute on function public.submit_porch_story to service_role;
```

Only `service_role` can call it — which in practice means only the submission Edge Function, since that's the only place the service-role key is ever used (Edge Function secrets, never a browser).

`is_admin()` is granted narrowly too, but to `authenticated` rather than `service_role`: it's evaluated as part of the `profiles_select_admin` and `porch_stories_admin_all` RLS policies, both of which only ever run for signed-in sessions (no table anywhere grants `anon` a privilege that would reach an `is_admin()`-gated policy, so `anon` doesn't get an `EXECUTE` grant on it at all — there's nothing for it to use it for).

## `porch_stories_public` grants are explicit too — a real gap was found and closed here

Supabase grants every new table or view in the `public` schema some default privileges to `anon`/`authenticated`/`service_role` so PostgREST works out of the box. `schema.sql` always overrides that for the base `porch_stories` table (`revoke all ... grant select, update`), but the first version of this file never did the same for the `porch_stories_public` view — it only added `grant select`, without first revoking the defaults.

That mattered more than it looks like it should, because `porch_stories_public` is a plain, single-table view with no joins/aggregates, which Postgres treats as **automatically updatable**. An `INSERT`, `UPDATE`, or `DELETE` sent to the view translates directly into the same operation on `porch_stories` underneath. With the default grants still in place:

- `INSERT` through the view happened to be blocked anyway — the view doesn't expose `publishing_permission`, so an insert through it always defaults that column to `false`, and the table's own `CHECK` constraint rejects it. Lucky, not designed.
- `UPDATE` and `DELETE` through the view were **not** blocked by anything — confirmed exploitable: an anonymous key could rewrite or delete any already-published story's content with no error, bypassing `submit_porch_story()` and the admin-only `porch_stories_admin_all` RLS policy entirely, since the automatic-updatability of a simple view sidesteps RLS on the policy's own terms (there's no row to filter — the write targets `porch_stories` directly).

The fix, applied as its own correction (no view or RLS change):

```sql
revoke all on public.porch_stories_public from anon, authenticated;
grant select on public.porch_stories_public to anon, authenticated;
```

Verified afterward with `has_table_privilege()` for both roles: `SELECT` is `true`; `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `REFERENCES`, and `TRIGGER` are all `false`. A live `UPDATE`/`INSERT` attempt as `anon` now fails with `permission denied for view porch_stories_public`, and the admin path (`porch_stories_admin_all` on the base table) was re-verified unchanged afterward.

## Content validation at the database level

`porch_stories` carries `CHECK` constraints matching the live site's own form limits (`index.html`: `#ps-name` `maxlength="80"`, `#ps-title` `maxlength="120"`, `#ps-story` `maxlength="8000"`, `#ps-email` `maxlength="254"`), so the same limits hold even if something bypasses the frontend entirely and calls the API directly:

| Column | Rule |
| --- | --- |
| `display_name` | trimmed non-empty, ≤ 80 characters |
| `title` | trimmed non-empty, ≤ 120 characters |
| `story_body` | trimmed non-empty, ≤ 8,000 characters |
| `contact_email` | if supplied: trimmed non-empty, ≤ 254 characters (no format check — Postgres `CHECK` regexes for email are more trouble than they're worth; malformed addresses just won't be reachable, which is a support problem, not a security one) |

These are deliberately generous, matching what the form already allows — nothing here makes normal story sharing harder than the form itself already does.

## Rate limiting and abuse protection

**Not automatically provided by Supabase.** The submission Edge Function needs its own check before it ever calls `submit_porch_story()`. For Phase 0 this is a documented hook only — nothing is enforced yet, and nothing here is deployed until Phase 3:

```ts
async function checkRateLimit(identity: { ip: string; userId: string | null }): Promise<boolean> {
  // Phase 0 / initial rollout: no-op, always allow.
  // Later: a per-IP and/or per-account check against a real
  // server-side store (Upstash Redis is a common fit for Supabase
  // Edge Functions), and/or a Cloudflare Turnstile token verified
  // here before this function returns true.
  return true;
}
```

Two independent options to turn on later, either or both:

- **Cloudflare Turnstile** (or hCaptcha) — the form gets a widget; the Edge Function verifies the token server-side before calling `submit_porch_story()`.
- **Per-IP / per-account throttling** — a real server-side store (Upstash Redis or similar) keyed by IP and/or the verified `user_id`, checked inside `checkRateLimit()`.

A browser-side counter (`localStorage` or similar) is never a valid rate limit on its own — it's trivial to clear or bypass — so it isn't an option here at all.

## Verifying before anything goes live

Before this is wired to the live site in any phase, check at minimum, using the Supabase SQL editor or a quick script with each key:

- An **anon**-key client can `select` from `porch_stories_public` and gets back only published stories, with exactly the six public columns.
- An **anon**-key client gets `permission denied` selecting directly from `porch_stories`.
- An **authenticated, non-admin** client *can* issue a `select` against `porch_stories`, because `authenticated` has table-level `SELECT` privilege — but RLS filters every row, since the only policy requires `is_admin()`. The result must come back with zero rows and no private data, not a `permission denied`.
- A signed-in member's `update` on their own `profiles` row succeeds when it only touches `display_name`/`notification_prefs`, and fails with `permission denied for column membership_tier` the moment `membership_tier` is included.
- Calling `submit_porch_story()` directly with the anon or authenticated key — not through the Edge Function — fails with `permission denied for function submit_porch_story`, confirming the explicit per-role revokes actually took.
- Calling `submit_porch_story()` (as `service_role`, e.g. from the SQL editor) with `p_publishing_permission` set to `false` fails with the `23514` exception from the explicit guard; attempting to force a row to `publishing_permission = false` directly (as admin) fails on the table's `CHECK` constraint instead.
- After granting yourself admin, an **admin** session *can* select and update every row and status on `porch_stories`.
- An **anon**-key client gets `permission denied for view porch_stories_public` attempting an `insert`, `update`, or `delete` against `porch_stories_public` — not just a `select`.
- An **authenticated, non-admin** client gets the same `permission denied for view porch_stories_public` on `insert`/`update`/`delete` against the view.
- `has_table_privilege('anon', 'public.porch_stories_public', '<priv>')` and the same for `authenticated` come back `true` only for `SELECT` — `false` for `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `REFERENCES`, `TRIGGER`.

## Phase 3: the `submit-porch-story` Edge Function (deployed)

The pseudocode in the "how `user_id` gets set safely" section above is now a real, deployed Edge Function — `supabase/functions/submit-porch-story/index.ts` (also kept in that path in this repo; deployed to the project under the function name `submit-porch-story`). It implements that same contract exactly, plus the request-level handling the pseudocode left out:

- **CORS**: `Access-Control-Allow-Origin` is locked to `https://fpr26.github.io` (the site's real production origin — scheme+host only, no path), not `*`. `OPTIONS` preflight is handled explicitly.
- **`verify_jwt: true`** at the platform/gateway level — the gateway rejects any request whose `Authorization` header isn't a validly-signed Supabase JWT before the function code ever runs. Because this project uses the newer `sb_publishable_...` key format for most client code (which is *not* a JWT and can't satisfy this gate), `index.html`'s Porch Story handler sends a different, still-public value as the `Authorization` bearer specifically for this one call: the project's legacy anon key, which *is* JWT-formatted (`CONFIG.services.supabaseAnonJwt`), used only when no signed-in session exists. A signed-in visitor's real session access token is sent instead whenever one exists. Both are exactly as safe to ship client-side as the publishable key — same `anon`/authenticated role, same RLS, no elevated access — it's a format requirement for this one header, not a privilege change.
- **Request validation**: every field is trimmed and length/type-checked server-side (`display_name` ≤80, `title` ≤120, `story_body` ≤8000, `contact_email` ≤254 and a real email shape, `category` against the exact same allow-list as the table's `CHECK` constraint), independent of whatever the browser form already enforces — an API call that skips the form can't store anything the form itself would have rejected.
- **`publishing_permission`** must be the literal boolean `true`; anything else (missing, `false`, a string) is rejected with a `400` before the database is even called, matching `submit_porch_story()`'s own guard as a second, independent layer.
- **Oversized/malformed payloads**: a `Content-Length` over 50KB is rejected before parsing; non-JSON bodies are rejected with a `400` rather than a crash.
- **Rate limiting**: a real, working per-IP sliding-window limiter (5 submissions / 10 minutes / IP, keyed off `x-forwarded-for`) is implemented in the function — not a no-op. Its one honest limitation, documented in the function's own comments: the counter lives in that isolate's memory, so it can reset on a cold isolate rather than holding a hard global guarantee. The "Rate limiting and abuse protection" section above (Turnstile / a Postgres or Redis-backed counter) is the upgrade path if FPR ever needs it to be durable across isolates — the call site (`checkRateLimit(ip)`) doesn't need to change for that swap.
- **Service-role key**: read only from `Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')` (with a fallback to the newer `SUPABASE_SECRET_KEYS` map if that legacy key is ever deactivated) — both are environment variables Supabase injects into every Edge Function automatically. It is never passed in, logged, or reachable from any browser-shipped file.

### Request flow: browser → Edge Function → Supabase

1. Visitor submits the Porch Story form in `index.html`. Client-side validation runs first (unchanged from before this phase).
2. The handler checks for a signed-in session via the existing Phase 1 Supabase client (`window.__fprSupabaseClient`, a plain reference to that same client — no new client instance, no elevated privilege). If signed in, it reads that session's access token; otherwise it falls back to the public anon JWT.
3. One `fetch` `POST`s the form fields (`display_name`, `title`, `category`, `story_body`, `contact_email`, `publishing_permission`) as JSON to `{supabaseUrl}/functions/v1/submit-porch-story`, with that token as the `Authorization: Bearer` header. This is the only network call that can ever result in a stored story.
4. Supabase's gateway checks the JWT (`verify_jwt: true`) before the function runs at all.
5. Inside the function: rate-limit check → body-size check → JSON parse → field validation → **independently** verify the `Authorization` bearer by calling `auth.getUser(token)` against Supabase Auth (the anon JWT resolves to no user → `null`; a real session token resolves to that user's id) → call `submit_porch_story()` with a **service-role** client, passing the verified id (or `null`) as `p_user_id` and never anything from the request body.
6. `submit_porch_story()` (unchanged from Phase 0) hard-codes `status = 'pending'`, has no parameters for `reviewed_at`/`published_at`/`reviewed_by`, and raises `23514` if `p_publishing_permission` isn't `true`.
7. On success, the function returns `{ ok: true, id }`; the browser shows the existing success message and — only then, and only as a best-effort courtesy — fires the existing Formspree notification in the background. Formspree never touches `porch_stories`, so it can't create a duplicate or conflicting row either way; its own success or failure has no effect on what was already stored or on what the visitor sees.
8. The row shows up in the Phase 2 admin dashboard exactly like any other `pending` row — nothing about that dashboard's own query or RLS changed.

## Phase 4: moderation (`moderate_porch_story()`)

Phase 0's `authenticated` grant on `porch_stories` was `select, update` with no column restriction — fine when nothing but the submitter's own insert path and an admin's eyeballs touched the table, but too broad once admins can actually write to it. Phase 4 found that gap (same shape as the `porch_stories_public` grant gap above) and closed it the same way: by removing the broad grant rather than trying to defend it with a trigger on top.

- **`revoke update on public.porch_stories from authenticated;`** — direct client `UPDATE`s on this table are now impossible for anyone except `service_role`/`postgres`. Verified live: `set role authenticated; update public.porch_stories set user_id = null ...;` fails with `permission denied for table porch_stories`.
- **`moderate_porch_story(p_story_id, p_action, p_display_name, p_title, p_category, p_story_body)`** (`security definer`) is now the *only* way any existing row changes. `p_action` is `'approve' | 'reject' | 'publish' | 'edit'`.
  - `id`, `user_id`, `contact_email`, `publishing_permission`, `submitted_at` are not parameters — there is no field for a client to put a value into, the same "can't happen" defense `submit_porch_story()` uses on insert.
  - `reviewed_by` is always `auth.uid()`; `reviewed_at`/`published_at` are always `now()`. Never client-supplied, in any action.
  - Status transitions are hard-coded to exactly: `pending→approved` (approve), `pending→approved→rejected` i.e. `pending→rejected` and `approved→rejected` (reject), `approved→published` (publish). Every other transition — `pending→published`, `rejected→published`, anything out of `published`, anything back to `pending` — is structurally unreachable because each action's guard clause requires one specific starting status and no action ever sets status to `pending`.
  - `edit` only touches `display_name`/`title`/`category`/`story_body`, only while status is `pending` or `approved`, and only when all four are provided (no silent partial overwrite). The table's own `CHECK` constraints (category allow-list, length limits) still apply on top.
  - The function re-checks `is_admin()` itself rather than relying solely on RLS — a non-admin `authenticated` caller gets `42501` from inside the function body, and an anonymous caller (`auth.uid()` null) gets the same.
  - `grant execute ... to authenticated` only; `anon` has no `EXECUTE` at all.

`admin.html` calls this one function for every moderation action (`client.rpc('moderate_porch_story', {...})`) and never calls `.update()`/`.insert()`/`.delete()` directly — it decides which buttons to show per status and reacts to what the function actually returns, but the function is what makes the rule true, not the UI.

### Verification results (Phase 4)

Run directly against the live database, simulating the admin session via `set_config('request.jwt.claim.sub', '<id>', false)` so `auth.uid()` resolves inside `moderate_porch_story()`:

| # | Test | Result |
|---|---|---|
| 1 | `pending → approved` (admin) | ✅ succeeded; `reviewed_at`/`reviewed_by` set |
| 2 | `pending → rejected` (admin) | ✅ succeeded |
| 3 | `approved → published` (admin) | ✅ succeeded; `published_at` set, `reviewed_at`/`reviewed_by` preserved |
| 4 | `pending → published` | ✅ rejected, `22023` |
| 5 | `rejected → published` | ✅ rejected, `22023` |
| 6 | `published → approved` (i.e. back out of published) | ✅ rejected, `22023` |
| 7 | Content edit on permitted columns | ✅ succeeded |
| 8–10 | Change `user_id`/`contact_email`/`publishing_permission` | ✅ impossible — not parameters, and a raw `UPDATE` as `authenticated` fails with `permission denied for table porch_stories` |
| 11 | `reviewed_by` reflects real admin, not a client value | ✅ confirmed (no such parameter exists) |
| 12 | `reviewed_at` server-side | ✅ confirmed (`now()`, no parameter) |
| 13 | `published_at` server-side | ✅ confirmed (`now()`, no parameter) |
| 14 | Non-admin authenticated cannot moderate | ✅ `42501` |
| 15 | Anonymous cannot moderate | ✅ `42501` |
| 16 | `porch_stories_public` still only exposes published rows | ✅ confirmed |
| 17 | No `service_role` key in `admin.html` | ✅ confirmed (comments only) |
| 18 | Phase 3 submission flow unaffected | ✅ `submit_porch_story()`/its grants untouched by this migration |

All test rows created for this verification were clearly labeled (`"Mod Test User"`, etc.) and are flagged for cleanup.

## Phase 6A: Community Posts foundation

A single, plain-text, member-created post type — `community_posts` — with three states (`published`/`hidden`/`removed`), a public read view, and three `security definer` RPCs that are the only way any row is ever created, edited, or moderated. No table grant for `insert`/`update`/`delete` exists for anyone, admin included; every write goes through a function that derives identity from `auth.uid()` and enforces its own transition rules, the same posture Phase 4 moved `porch_stories` to.

**Hard privacy boundary.** `community_posts` stores only `user_id`, `body`, `status`, and timestamps. Nothing in this migration, in `index.html`'s Community page, or in `admin.html`'s Community moderation section reads or writes the Recovery Counter, Daily Check-In, moods, cravings, reflections, gratitude entries, or rough-day responses — none of that on-device data has any code path into Supabase.

### RLS: a caught-and-fixed gap

The first draft of `community_posts`'s select policy was `status = 'published' or is_admin()`, combined with `grant select on community_posts to authenticated`. That let **any signed-in member read every other author's raw `user_id`** (and moderation columns) directly off the base table, not just their own — a real privacy gap, caught during this same build/verify pass before anything was reported done. It's fixed (`supabase/migrations/phase6a_community_posts_member_read_fix.sql`):

```sql
alter policy "community_posts_select" on public.community_posts
  using (public.is_admin());
```

Now the base table's only policy is admin-only, exactly mirroring `porch_stories_admin_all`. A member or anonymous visitor never reads `community_posts` directly — both read the feed through `community_posts_public`, and a member sees their own posts (any status) through a new `list_my_community_posts()` function, which filters strictly on `user_id = auth.uid()` and never returns another member's row.

### The three RPCs

- **`create_community_post(p_body)`** — `user_id` is always `auth.uid()`, never a parameter, so there's no code path for a client to post as someone else. `status` is hard-coded `'published'`; timestamps are server-generated. Validates trimmed-non-empty, ≤2,000 characters (also enforced by a table `CHECK`, same defense-in-depth as Porch Stories).
- **`edit_community_post(p_post_id, p_body)`** — verifies `current_row.user_id = auth.uid()` and `current_row.status = 'published'` before allowing a body-only update; sets `updated_at`/`edited_at` itself. `status`, `user_id`, and moderation fields aren't parameters, so they can never be touched here, and a hidden/removed post can't be edited by its owner.
- **`moderate_community_post(p_post_id, p_action)`** — admin-only (`is_admin()`, re-checked inside the function, not just via RLS). `moderated_by` is always `auth.uid()`; `moderated_at` is always `now()`. Transitions are hard-coded to exactly `published→hidden`, `published→removed`, `hidden→published` (restore), `hidden→removed`. Nothing is reachable out of `removed` (no `removed→published`, no `removed→hidden`), and there is no hard-delete anywhere in this function or in `admin.html` — "remove" only ever sets `status = 'removed'`, retained for audit.

### `community_posts_public` (view)

Exposes only `id, body, created_at, updated_at, edited_at, display_name` — `user_id` and `moderated_by` are never selected into it, and `display_name` is resolved from `profiles` with a `'Community member'` fallback so a member who never set one doesn't show up as their email or UUID (neither of which this view ever touches). Same explicit `revoke all ... ; grant select ...` pattern as `porch_stories_public`, closing the same automatically-updatable-view gap: without it, Supabase's default per-relation grants would leave `anon`/`authenticated` with `insert`/`update`/`delete` on the view, bypassing the RPCs and RLS entirely.

### Frontend

- **`index.html`** — a new "Community" nav destination (desktop + mobile) and `#page-community`: a read-only feed (newest first, built entirely with `createElement`/`textContent` — never `innerHTML` — so a post body or display name that looks like a `<script>` tag renders as plain, inert text), a sign-in prompt where posting controls go for signed-out visitors, and a post/edit form for signed-in members (2,000-character limit, client-side validation mirrored by the server). No pasted URL is ever auto-linkified. The feed read uses its own session-less Supabase client (same `loadDbStories()` pattern as the Porch Stories page in Phase 5) so it's decoupled from the sign-in client's own init timing; posting/editing call the RPCs through the shared signed-in client so the member's real session JWT is what the server checks. A failed feed load shows a subtle inline message and never breaks the rest of the site; a failed post/edit shows the actual error and never optimistically updates the UI before the database confirms it.
- **`admin.html`** — a new, clearly separate "Community Posts" tab alongside "Porch Stories" (its own list, filters, status message, and moderation functions — no shared state with the Porch Stories code), showing display name, post text, status, created/edited/moderated dates, and Hide/Restore/Remove buttons gated strictly by `post.status`. No hard-delete button anywhere. Every post body is rendered with `textContent`, same as the public page.

### Verification results (Phase 6A)

Run directly against the live database — `create`/`edit` identity tests via `set_config('request.jwt.claim.sub', '<id>', false)` so `auth.uid()` resolves inside the functions; grant-level claims (anon/authenticated privileges) cross-checked against `information_schema.role_table_grants`/`role_routine_grants` for the reason given in the Verifying-before-anything-goes-live section above (this sandbox can't make a real HTTP call through PostgREST as `anon`/`authenticated`, so the function's own internal identity guard and the catalog grants are verified independently as two layers, same methodology as Phases 3–4).

| # | Test | Result |
|---|---|---|
| 1 | Anonymous `SELECT` published posts (via `community_posts_public`) | ✅ succeeded |
| 2 | Anonymous create fails | ✅ `42501` ("Sign in required...") |
| 3 | Anonymous edit fails | ✅ `42501` |
| 4 | Anonymous moderation fails | ✅ `42501` |
| 5 | Authenticated member creates own post | ✅ succeeded |
| 6 | Stored `user_id` equals `auth.uid()` | ✅ confirmed |
| 7 | Client cannot submit another user's `user_id` | ✅ impossible — no such parameter exists (confirmed via `pg_get_function_arguments`) |
| 8 | Member edits own published post | ✅ succeeded; `edited_at`/`updated_at` set |
| 9 | Member cannot edit someone else's post | ✅ `42501` |
| 10–12 | Member cannot change `status`/`user_id`/`moderated_by` | ✅ impossible — none are parameters |
| 13 | Member cannot edit a hidden/removed post | ✅ `22023` ("A hidden post cannot be edited.") |
| 14 | Admin hides a published post | ✅ succeeded |
| 15 | Admin restores a hidden post | ✅ succeeded, back to `published` |
| 16 | Admin removes a published post | ✅ succeeded |
| 17 | Admin removes a hidden post | ✅ succeeded |
| 18 | `removed → published` fails | ✅ `22023` ("Only a hidden post can be restored (current status: removed).") |
| 19 | Non-admin authenticated cannot moderate | ✅ `42501`; row unchanged |
| 20 | `community_posts_public` exposes no `user_id`/email/moderation fields | ✅ confirmed — exactly `id, body, created_at, updated_at, edited_at, display_name` |
| 21 | `anon`/`authenticated` have `select`-only on the view and the base table | ✅ confirmed via `information_schema.role_table_grants` |
| 22 | `insert`/`update`/`delete` through the public view fail | ✅ no such grant exists for anyone |
| 23 | Script/HTML-looking post body renders as plain text | ✅ confirmed at the SQL layer (plain `text` column, no HTML stored/interpreted) and at the frontend layer (14 automated DOM tests against the real extracted `index.html` Community code, including this exact case — body stored only via `textContent`, never `innerHTML`) |
| 24 | Existing Porch Stories submission/moderation/public display still works | ✅ confirmed — `submit_porch_story`, `moderate_porch_story`, `is_admin`, and `porch_stories_public` are all untouched by this migration |
| 25 | Existing local Recovery Counter/Check-In data untouched, on-device | ✅ confirmed — no column, trigger, or code path in this phase reads or writes any of it |

A tooling note on this verification pass: this sandbox's SQL-execution tool was observed to occasionally return a stale/incorrect error for a `moderate_community_post(...)` call that, per a direct follow-up `SELECT`, had not actually changed the row — reproducible for the `'hide'`/`'remove'` action keywords specifically, across multiple different, never-before-touched rows, while a structurally different call form (`select * from fn(named_args)` instead of `select (fn(...)).*`) executed correctly every time. Every moderation test above was re-run with the reliable call form and its result cross-checked against a plain `SELECT` of the row before being recorded.

### Test data created (Phase 6A)

Two test `auth.users` (needed because `community_posts.user_id` has a foreign key to `auth.users`, so simulating a member requires a real row): `community-test-member-a@example.invalid` (`807a0d5e-92ab-4dca-94ef-b4a445876237`) and `community-test-member-b@example.invalid` (`fa316087-85de-4a1a-8e11-b22deeff8f86`). Both have a profile created automatically (via the existing `handle_new_user` trigger) with display names `"Community Test Member A"` / `"Community Test Member B"`.

Nine `community_posts` rows, all body-prefixed `"Community Test: ..."` and owned by Member A (a tool-level call-duplication issue during the first `create_community_post` test — see below — produced more duplicates than intended; they were repurposed as separate test fixtures rather than discarded, since discarding them hit the same stuck-`DELETE`-confirmation issue described in the Phase 3/4 sections):

| id | final status |
|---|---|
| `015985f0-6e3a-4ce9-b699-4a9633fd16bb` | published |
| `0f6ad4f7-281e-4b40-a1fd-4bca97c40ce3` | published (was hidden, then restored) |
| `15c34512-9d7c-43de-8b5f-e811ef37f7a9` | removed (was hidden, then removed) |
| `39541e4b-5941-4381-9d6e-f82375dfe40e` | hidden |
| `53544caf-03d4-4098-9f89-fb8e6e1d21b7` | removed |
| `793c6055-d952-44c9-8452-2f74153335c4` | published |
| `c2ca17c1-26c1-48e8-bbbd-60fa74d566f6` | published |
| `cd439136-5339-4ee7-8a3f-0b7df8215b25` | published |
| `d2185186-6a33-4b4a-b479-253051626f55` | published (edited) |

**A tool-level duplication issue, for the record.** The very first `create_community_post` call (test 5) was executed 9 times by the SQL-execution tool/transport for a single logical tool call (all 9 rows share the identical microsecond-precision `created_at`), producing 9 rows instead of 1. This is the same class of issue noted in Phase 3/4 (`DELETE` statements there repeatedly returned `{"status":"cancelled"}` rather than running) — some mutating calls in this sandbox don't execute exactly once, and the only reliable way to know what actually happened is a follow-up `SELECT`, never the call's own reported result. None of this reflects a flaw in `create_community_post()` itself (it has no idempotency key because two genuine posts in a row are supposed to both be stored; the bug is the tool sending the request more than once) — but it's recorded here plainly rather than quietly working around it, same as the `DELETE` issue before it.

**Since cleaned up.** The `DELETE` statements against these 9 `community_posts` rows and the 2 test `auth.users` rows originally returned `{"status":"cancelled"}` (this sandbox needs an interactive confirmation for destructive statements that it cannot grant itself). They have since been removed: as of 2026-10-16, neither test user nor any of the 9 posts exists.

## Phase 6B: comments, one-level replies, and member reporting

Recorded in `migrations/phase6b_comments_replies_reports.sql` (live migration `phase6b_comments_replies_reports`) plus `migrations/phase6b_reports_open_unique_fix.sql`, a follow-up that was applied directly and is kept in the repo as a record only. Same posture as 6A: base tables are admin-only `SELECT`, and every write goes through a `security definer` RPC that takes identity from `auth.uid()`.

- **`community_comments`** — plain text, ≤1,000 characters, `published`/`hidden`/`removed`. `parent_comment_id` allows exactly one level of replies (a reply to a reply is rejected).
- **`community_comments_public`** (view) — only published comments whose post is published, and only replies whose parent comment is also published. No `user_id`; `display_name` falls back to `'Community member'`.
- **RPCs** — `create_community_comment`, `create_community_reply`, `edit_community_comment` (own, published comments only), `list_my_community_comments`, and admin-only `moderate_community_comment` (same transitions as posts: hide, restore, remove; nothing out of `removed`).
- **`community_reports`** + **`report_community_content()`** — a member reports exactly one post or comment with a reason (`harassment`, `hate_or_abuse`, `dangerous_content`, `spam`, `privacy`, `other`) and optional details (≤500). Two unique partial indexes allow only one open report per reporter per target, race-safe. Admin-only **`moderate_community_report()`** resolves or dismisses open reports.
- **`admin.html`** — separate tabs for Community Posts moderation, Community Comments moderation, and Reports (resolve/dismiss).

## Phase 6C: reactions, in-app notifications, and post search

Applied to production on 2026-10-16 as migration `phase6c_community_engagement` (version `20261016204446`); see `migrations/phase6c_community_engagement.sql`. It was first validated in a rollback-only transaction against the live database, then applied once and structurally verified, with every pre-existing object unchanged except `create_community_reply()`.

- **`community_reactions`** — `support`, `heart`, or `celebrate` on exactly one post or comment/reply. Two unique partial indexes enforce one active reaction per member per target. **`toggle_community_reaction()`** adds a reaction, switches it in place (different reaction), or removes it (same reaction again). Only content that is publicly visible can be reacted to.
- **`community_reaction_counts_public`** (view) — aggregate counts only, readable by `anon` and `authenticated`. It inner-joins the two public views, so hidden or removed content (or anything under it) never shows counts. **`list_my_community_reactions()`** returns only the caller's own reactions, so the UI can highlight them.
- **`community_notifications`** — in-app only, never push, email, or SMS. Created for a reply to your comment (inside `create_community_reply()`, the one modified 6B function) and for the first reaction to your post or comment; switching a reaction never notifies, and removing then re-adding one may notify again. Self-notifications are blocked by a table constraint. `actor_user_id` is `ON DELETE SET NULL`, so the notification survives the actor's account deletion and shows "A member".
- **Notification RPCs** — `list_my_community_notifications()` (newest first, no user IDs; content that has since been hidden or removed comes back with `target_available = false` and no IDs or excerpt), `count_my_unread_community_notifications()`, `mark_community_notification_read()` (own rows only; anyone else's ID gets the same "not found"), and `mark_all_community_notifications_read()`.
- **Post search** needs no database object: `index.html` searches `community_posts_public` (published posts only, never comments) with a case-insensitive substring match.
- **Verification** — signed-out browser checks plus member actions run as two temporary test users: add/switch/remove, comment/reply reactions, reply and first-reaction notifications, self-action suppression, unread count, mark one/all read, privacy between members and `anon`, moderation fallbacks, search, and comment/edit/report regressions. All passed, and every test row and both test users were removed by exact ID afterwards.

## Phase 7: member profiles

### 7A — profile backend foundation

Migration `phase7a_member_profiles_foundation`. `profiles` gained:
- **`public_id`**: an opaque random UUID used everywhere a member is identified publicly. It has no relationship to the auth user id, never changes, and the auth id and email never appear in any public view.
- **`bio`**: optional, at most 300 characters.
- **`avatar_path`**: optional.
- **`recovery_date`**: optional and entered only by the member. Nothing reads or copies the on-device Recovery Counter.
- **`recovery_visibility`**: `private` (the default), `members`, or `public`.
- **`profile_updated_at`**.

`display_name` is now required to be 1–80 characters after trimming, and `handle_new_user()` trims and caps the sign-up name to match.

- **`community_member_profiles_public`** (view) — `public_id`, `display_name`, `bio`, `avatar_path`, `joined_at`, and `recovery_date` only when the viewer may see it: the owner always; `members` only for signed-in viewers; `public` for everyone. It lists only members with published Community content (plus the viewer's own row), so it is not a directory of every account.
- **`author_public_id`** was appended to `community_posts_public` and `community_comments_public` so posts and comments can link to profiles without exposing `user_id`.
- **RPCs** (all `security definer`, members only): `get_my_profile`, `update_my_profile`, `set_my_avatar`, `clear_my_avatar`, plus admin-only `moderate_member_profile` (`reset_display_name`, `clear_bio`, `clear_avatar`, `hide_recovery`).
- **`avatars` storage bucket** — public read; 1 MB maximum; JPEG/PNG/WebP only. Members can write, list and delete only inside their own `public_id/` folder, and `set_my_avatar` accepts only a path in that folder that has actually been uploaded.

### 7B — own-profile editor + avatar upload

The signed-in account modal in `index.html` edits display name, bio, recovery date and its visibility, and the profile photo — all through the RPCs above, never by writing the table. Photos are cropped to a square, resized to at most 512×512, and re-encoded in the browser before upload (which strips EXIF/GPS metadata), then kept under 1 MB.

Once that path was live and verified, migration `phase7b_revoke_direct_profile_update` revoked the old direct `UPDATE` privilege on `profiles(display_name, notification_prefs)`. Members can no longer write their profile row directly at all; `notification_prefs` had no writer.

### 7C — member profile panel

Clicking a post, comment or reply author in the Community opens an in-page profile panel (no new route) that reads `community_member_profiles_public` by `author_public_id`: photo or initial, display name, bio, joined date, and the recovery date only when the view returns one for that viewer.

### 7D — recent posts, author avatars, admin moderation

- **Recent posts:** the profile panel lists the member's five most recent published posts, from `community_posts_public` filtered by `author_public_id`.
- **Author avatars:** small avatars appear beside Community authors. They are resolved in one batched query per feed render or per opened comment section, never one query per card.
- **Admin moderation:** `admin.html` has a Member Profiles tab for the four fixed `moderate_member_profile` actions, each with a confirmation.
- **Avatar file removal:** migration `phase7d_admin_avatar_removal` adds admin-only `SELECT`/`DELETE` policies on the `avatars` bucket. After clearing a photo from a profile, the admin page deletes the image file through the Storage API, so a moderated photo is not left reachable at its public URL.

## Phase 8A: private member follows

Migration `phase8a_member_follows`, applied directly in the Supabase SQL Editor (not in the migration history).

- **`member_follows` table:**
  - `follower_user_id`, `followed_user_id` (both reference `auth.users`, `ON DELETE CASCADE`), and `created_at`;
  - primary key `(follower_user_id, followed_user_id)`, so a pair can only appear once;
  - a `CHECK` that you can't follow yourself, and an index on `followed_user_id`.

  Auth user ids stay internal to the table. The frontend and RPCs use only `profiles.public_id`.
- **Access:** RLS is on and `anon`/`authenticated` have no table privileges at all, so every read and write goes through the RPCs. There is no admin write path; admins can review follows from the SQL editor if ever needed.
- **RPCs** (`security definer`, `search_path = public, pg_temp`, `authenticated` only):
  - **`follow_member(target_public_id)`**: idempotent. It only follows members currently listed in `community_member_profiles_public`. Unknown and unlisted ids both get `P0002`, and following yourself gets `22023`.
  - **`unfollow_member(target_public_id)`**: idempotent. It removes only the caller's own follow.
  - **`get_follow_state(target_public_id)`**: returns `is_self`, `following` and `followed_at` for the caller only. An unknown id looks the same as "not following".
  - **`get_my_following()`**: the caller's list, newest first, with `public_id`, `display_name`, `avatar_path` and `followed_at` — never auth ids, email or recovery data.
- **Privacy:** follows are private to the follower. There are no counts, no public followers/following lists, and no notifications in 8A. Deleting either account removes the follow.

## Phase 8B: handles and @mentions

Migration `phase8b1_handles_mentions_foundation`, applied directly in the Supabase SQL Editor (not in the migration history). 8B-2 to 8B-4 are frontend only; no other migration was needed.

### Handles

- **Columns:** `profiles.handle` (nullable, unique via `profiles_handle_key`) and `profiles.handle_changed_at`. A `CHECK` constraint enforces the format: `^[a-z][a-z0-9_]{2,23}$`, no `__`, no trailing `_`. `is_reserved_handle()` blocks reserved names (admin, support and similar).
- **`set_my_handle(p_handle)`** (`authenticated` only) is the only write path. It lowercases the value and allows one change every 30 days. Saving the same value again is a no-op, and a taken handle gets `23505`. Handles are optional and can't be cleared by the member.
- **`check_handle_availability(p_handle)`** returns `available`, `taken`, `invalid`, `reserved` or `cooldown` for the caller.
- **`search_member_handles(p_prefix)`** (`authenticated` only) does a prefix search over listed Community members. It needs at least 2 characters and returns at most 8 rows of `public_id`, `handle`, `display_name` and `avatar_path`.
- **Public view:** `community_member_profiles_public` includes `handle`.
- **Admin:** `moderate_member_profile(public_id, 'reset_handle')` clears a handle (the member can pick a new one). Admins can't assign handles.
- Direct `UPDATE` on `profiles` stays revoked for `anon`/`authenticated` (Phase 7B). Every profile and handle change goes through these RPCs.

### Mentions

- **`community_mentions`** stores `post_id` or `comment_id` (exactly one), `mentioned_user_id` and `handle_at_write`. There's one row per member per source and at most 10 per source. RLS is on and `anon`/`authenticated` have no table privileges.
- **Parsing:** insert/update triggers on posts and comments call `sync_community_mentions`. It extracts tokens with `(?<![A-Za-z0-9_.@])@([A-Za-z][A-Za-z0-9_]{2,23})(?![A-Za-z0-9_])`, so `me@site.com`, `x@name` and `.@name` are not mentions. It then binds each token to the member who holds that handle at write time. Unknown handles create nothing.
- **`community_mentions_public`** (view, `select` for `anon`/`authenticated`) exposes only `post_id` (the parent post for comment/reply mentions), `comment_id`, `handle` (the handle at write time) and `mentioned_public_id`. It never exposes auth ids, and it only shows mentions inside content the public post/comment views already show.
- **Frontend:**
  - Bodies render as plain text first. One batched view query per feed render or search (posts containing "@") and one per opened comment section then turn only the stored, boundary-matched tokens into buttons that open the profile panel. Everything is built with text nodes and `createElement`.
  - Composer autocomplete calls `search_member_handles` after a 300 ms pause, and only for signed-in members typing `@` plus 2 or more characters at a valid boundary. It only inserts text; the trigger decides the stored mentions.
- **Old text keeps its binding:** a mention stays bound to the member's identity (`mentioned_public_id`). If they later change handle, unedited text still shows `@oldname` and still opens their profile.
- **Known behaviour:** if a post or comment that says `@oldname` is *edited* after that member changed handle, the re-sync resolves only current handles, so that old mention is dropped and `@oldname` becomes plain text. This is accepted for Phase 8B; handle aliases/history are out of scope.
- **Notifications:** mention notifications were added in Phase 8C (below).

## Phase 8C: mention and follow notifications

Migrations `phase8c1_mention_notifications` and `phase8c3_follow_notifications`, both applied directly in the Supabase SQL Editor. 8C-2 and 8C-4 are frontend and docs only.

### Schema (8C-1)

- `community_notifications.notification_type` allows 7 types:
  - existing: `comment_reply`, `post_reaction`, `comment_reaction` (unchanged behaviour);
  - new: `mention_post`, `mention_comment`, `mention_reply`, `follow`.
- `post_id` is now nullable. `community_notifications_shape_check` fixes which ids each type carries:
  - `mention_post`: `post_id` only;
  - `mention_comment`: `post_id` + `comment_id`;
  - `mention_reply`: `post_id` + `comment_id` (the parent comment) + `reply_comment_id` (the reply), the same shape as `comment_reply`;
  - `follow`: no post or comment ids.
- `actor_user_id` is not required by the shape check, because deleting the actor's account sets it to `NULL`. `community_notifications_not_self_check` still blocks self-notifications.
- **Dedupe:** partial unique indexes allow one notification per recipient per source:
  - `mention_post` on `(recipient, post_id)`;
  - `mention_comment` on `(recipient, comment_id)`;
  - `mention_reply` on `(recipient, reply_comment_id)`;
  - `follow` on `(recipient, actor)`.
  Reply and reaction notifications keep their Phase 6C behaviour.

### Mention notifications (8C-1)

- An `AFTER INSERT` trigger on `community_mentions` (`community_mentions_notify`) creates them. The 8B-1 sync only inserts genuinely new mention rows, so:
  - mentions that survive an edit unchanged, removed mentions and handle renames never notify;
  - a mention added in an edit notifies once;
  - removing and re-adding the same member doesn't notify twice (dedupe index).
- **Skipped:** self-mentions; unpublished posts or comments (or an unpublished parent); and a reply that mentions the parent comment's author, who already gets a `comment_reply` for it.
- The actor is the content's author. Volume stays bounded by the 8B-1 cap of 10 mentions per source.

### Follow notifications (8C-3)

- An `AFTER INSERT` trigger on `member_follows` (`member_follows_notify_insert`) creates one `follow` notification for the followed member. `follow_member` inserts with `ON CONFLICT DO NOTHING`, so a repeat follow never notifies again.
- An `AFTER DELETE` trigger (`member_follows_notify_delete`) removes only that pair's follow notification, read or unread. Unfollowing removes it, and following again later creates a fresh one. A follower never has more than one follow notification with the same member at a time.
- `follow_member` / `unfollow_member` are unchanged. Following lists stay private; the followed member is told who followed them (privacy page updated).

### Read model and security

- `list_my_community_notifications(p_limit, p_before)` was dropped and recreated in 8C-1. It has the same name and arguments and the same columns, plus `actor_public_id` and `actor_avatar_path`.
  - Those two are filled only when the actor is listed in `community_member_profiles_public`.
  - No auth ids, recipient ids or emails are ever returned.
- **`target_available`:**
  - mentions: the source (and its post/parent) must be visible in the public views;
  - follow: the actor is listed.
  - When unavailable, ids and the excerpt come back `NULL`.
- **Excerpts:** the post body for `mention_post`, the comment for `mention_comment`, the reply for `mention_reply`, and none for `follow`.
- **Access:**
  - Reads stay recipient-private (`auth.uid()`). `list`, `count`, `mark one` and `mark all` are executable by `authenticated` only.
  - All three trigger functions are `security definer` with `search_path = public, pg_temp`, and EXECUTE is revoked from `public`, `anon` and `authenticated`, so they can't be called directly.
  - The frontend never writes notifications; only the triggers and the existing 6C RPCs do.

### Frontend (8C-2, 8C-4)

- Rows show the actor's photo when listed, otherwise their initial, or "?" when the actor is gone.
- Mention **View** marks the item read, focuses the post, opens its comments, then scrolls to and highlights the exact `data-comment-id` (falling back to the post). Reply and comment-reaction notifications use the same targeting.
- Follow **View profile** marks the item read and opens the member profile panel.
- Opening the panel marks nothing read.
- The unread count refreshes on Community visits, after read actions, and once on `visibilitychange` when the tab becomes visible on the Community page while signed in. There's no polling or realtime.

### Known current behaviour

- **Unlisted followers:** a follower who hasn't published any Community content isn't in `community_member_profiles_public`. Their follow notification shows their display name but no photo, no public id and no **View profile** button ("Their profile isn't available right now."). This is expected.
- **Deleted follower account:** not live-tested, because destructive `DELETE` tests are blocked in the tooling. The read model degrades safely to "A member" with no profile button.
- **Edit after rename (8B):** editing text that still says `@oldname` after that member changed handle drops the mention, so no new notification is created for it.

### Migration history

`phase8a_member_follows`, `phase8b1_handles_mentions_foundation`, `phase8c1_mention_notifications` and `phase8c3_follow_notifications` were applied manually in the Supabase SQL Editor. They are **not** recorded in `supabase_migrations.schema_migrations`, which still lists only the earlier migrations. The files in `supabase/migrations/` are the record of what was applied.

## Phase 9A: member blocking

Migration `phase9a_blocking_foundation`, applied manually in the Supabase SQL Editor. 9A-3 and 9A-4 are frontend and docs only.

Blocking is an **interaction-safety** feature. It does no content filtering: public posts, comments and profiles look the same to everyone, including a blocked pair.

### `member_blocks`

- `blocker_user_id` and `blocked_user_id` both reference `auth.users` with `ON DELETE CASCADE`, plus `created_at`.
- Primary key `(blocker_user_id, blocked_user_id)`, so there's one row per direction. `member_blocks_not_self_check` stops self-blocks, and there's an index on `blocked_user_id`.
- RLS is on with no policies, and `anon`/`authenticated` have no table privileges at all. Every read and write goes through the RPCs. Auth ids stay internal; the RPCs use `profiles.public_id`.
- Admins get no block-list access in the app. Member review belongs to a later reporting phase.

### RPCs

All are `security definer` with `search_path = public, pg_temp`, executable by `authenticated` only.

- **`block_member(target_public_id)`:**
  - Self gets `22023` and an unknown id gets `P0002`. The target only needs a profile, not published content.
  - It takes the pair lock, inserts the block (repeat calls are harmless) and deletes follows **in both directions**. The 8C-3 follow delete trigger removes the matching follow notifications.
  - Returns `(blocked, blocked_at)`.
- **`unblock_member(target_public_id)`:** removes only the caller's own block and returns whether a row was removed. Repeat calls are harmless. **Follows are not restored.**
- **`get_member_relationship(target_public_id)`:** returns `is_self`, `following`, `followed_at`, `blocked_by_me`, `blocked_at` and `can_follow`.
  - It **never exposes "blocked by them"**. A block by the other member only shows up as `can_follow = false`, which is also false for unlisted members.
  - The profile panel uses this. `get_follow_state` is unchanged and kept for compatibility.
- **`get_my_blocked_members()`:** the caller's own list only, with `public_id`, `display_name`, `avatar_path`, `handle` and `blocked_at`, newest first. No email, auth ids or recovery data.

### Internal helpers and guards

The helpers and guards have EXECUTE revoked from `public`, `anon` and `authenticated`, so none of them can be called directly.

- **`is_block_between(a, b)`:** true if either member blocked the other. Every check uses it.
- **`lock_member_pair(a, b)`:** a transaction advisory lock on the unordered pair. Both `block_member` and the follow guard take it, so a block and a follow can't race past each other.
- **Follow guard (`member_follows_block_guard`):** BEFORE INSERT on `member_follows`. It takes the pair lock and rejects any follow across a block with a generic `P0002` ("This member can't be followed right now."). It covers every follow write path; `follow_member` is unchanged.
- **Reply guard (`community_comments_reply_block_guard`):** BEFORE INSERT on `community_comments`, **replies only**. A reply to the other member's comment gets a generic `P0002` ("This reply can't be posted right now."). Top-level comments and reactions stay allowed in 9A.
- **Notification guard (`community_notifications_block_guard`):** BEFORE INSERT on `community_notifications`. It silently skips any notification whose recipient and actor are a blocked pair: replies, reactions, mentions, follows, and any future type. Historical non-follow notifications are kept.

### Recreated functions (same signatures)

- **`search_member_handles`:** excludes members who have a block with the caller in either direction, applied before the 8-result limit.
- **`sync_community_mentions`:** doesn't resolve a handle whose owner has a block with the content's author. No new mention row is created, so there's no link and no notification, and the typed text stays plain.

### Known current behaviour

- **Historical mentions:** mention rows created before a block stay, and still link, **unless that post or comment is edited**. The re-sync then drops the mention across the block, just like edit-after-rename (8B).
- **Mentions across a block:** these are covered in depth by three checks: the autocomplete filter, the mention-sync filter and the notification guard. A mention written at the exact moment a block is created may slip past the first two, and the notification guard is the backstop.
- **Inferring a block:** a blocked member may be able to infer the block (they can't follow, find or reply to the blocker), but no RPC or UI says who blocked whom.
- **Account deletion:** blocks are removed by the FK cascade. This wasn't live-tested because destructive `DELETE` tests are blocked in the tooling; the FK structure was verified.

### Migration history

`phase9a_blocking_foundation` was applied manually in the Supabase SQL Editor and is **not** recorded in `supabase_migrations.schema_migrations`. Together with 8A, 8B-1, 8C-1 and 8C-3, five migrations have now been applied this way. The history table still has only the earlier 9 rows. No history rows have been added by hand.

## Phase 9B — Member muting

Migration: migrations/phase9b1_member_mutes.sql. Applied manually in the SQL Editor during Phase 9B-1; do not blindly re-run it. The original migration MD5 was verified as 2128129f9f375ba963b28710c9823e9e.

- member_mutes is private, with cascading auth-user foreign keys, a pair primary key, a no-self constraint, an index for the muted user, and RLS with no member policies or direct member table access.
- mute_member, unmute_member, and get_my_muted_members use SECURITY DEFINER and search_path = public, pg_temp. Execute is limited to authenticated members. Public/anon execution is revoked.
- get_my_muted_members returns public profile fields and muted_at; it does not expose auth IDs or email.
- Notification list/count skip muted actors when read. Stored notifications are retained and reappear after unmuting if otherwise eligible.
- Frontend filtering uses a per-identity cache of public IDs. Initial signed-in feed/comment rendering waits for auth restoration and cache loading. fpr:mutechange reloads it; sign-out clears it. Cache errors fail open.
- Community feed/search omit muted authors’ posts. Comments/replies remain in place, collapsed behind Show; revealing uses the original card builder and controls. Follows, blocks, reactions, and interaction permissions are unaffected.

Further details (Phase 9B-4 closeout):

- **Table:** `member_mutes(muter_user_id, muted_user_id, created_at)`. Both FKs reference `auth.users` with `ON DELETE CASCADE`. The primary key is the pair, `member_mutes_not_self_check` stops self-mutes, and `member_mutes_muted_user_idx` indexes the muted member. RLS is on with no policies, and `anon`/`authenticated` have no table privileges at all.
- **RPCs:**
  - **`mute_member(target_public_id)`:** self gets `22023`, an unknown id gets `P0002`. A repeat call is harmless and returns the original `muted_at`. It has no other side effects: follows, blocks, mentions, replies, reactions and notifications are untouched.
  - **`unmute_member(target_public_id)`:** removes only the caller's own mute and returns whether a row was removed (false on repeat or for an unknown id).
  - **`get_my_muted_members()`:** the caller's own list only, newest first (`public_id`, `display_name`, `avatar_path`, `handle`, `muted_at`).
- **Notifications:** `list_my_community_notifications` and `count_my_unread_community_notifications` were recreated with the same signatures and columns, plus a `NOT EXISTS` check on `member_mutes`, so muted actors are filtered at read time. Notification rows are never deleted, and creation is unchanged. The 9A block guard (which skips creation across a block) is separate and unchanged. Unmuting makes historical notifications visible again.
- **Frontend:**
  - Mute state comes only from the shared cache, a Set of muted `public_id`s. There's no `get_mute_state` RPC and no change to `get_member_relationship`.
  - `fpr:mutechange` fires exactly once per mute or unmute. Its listeners never re-dispatch it.
  - The account Muted members list reloads on that event only while the account modal is open (opening the modal reloads it).
  - A muted member's profile, including Recent Posts, stays visible when it's opened on purpose.
  - All-muted feeds and searches show a mute-aware empty state. The search backend limit (50) is unchanged, so muted rows can make a search show fewer than 50 results.
- **Independence from blocking:** blocking doesn't mute and muting doesn't block. Unblocking keeps a mute, unmuting keeps a block, and both can exist at once.
- **Migration history:** `phase9b1_member_mutes` was applied manually in the SQL Editor and is **not** in `supabase_migrations.schema_migrations`. See the Phase 9C section for the full list of manually applied migrations. Re-checked live on 2026-10-19, the table still has 9 rows, ending at `phase7d_admin_avatar_removal`. No rows have been added by hand.

Verification: backend rollback tests were reported complete in the Phase 9B-1 handoff. During this session, live tests with JUSTIN and MAXOM confirmed feed/search filtering, comment/reply collapse and Show, persistence after refresh, account-list unmuting, restored search results, and notification hiding/restoration. Cache/identity races and failure fallback were covered by focused local tests, not by the live walkthrough.

## Phase 9C — Member reports

Migration: migrations/phase9c1_member_reports.sql. Applied manually in the SQL Editor on 2026-10-19. The rollback verification passed before the frontend/admin deployment at 96ffc05.

- community_reports adds member_public_id referencing profiles(public_id), cascading on profile deletion. Its target constraint now requires exactly one post, comment, or member target. Existing report reasons and admin-only RLS remain unchanged.
- The partial unique index community_reports_one_open_member_per_reporter enforces one open report for each reporter/member pair, including concurrent inserts. The RPC translates uniqueness violations into a friendly duplicate message.
- report_member(p_target_public_id uuid, p_reason text, p_details text default null) returns only a receipt UUID. It validates sign-in, target existence, no self-report, allowed reason, and details length (500 characters maximum), trims details, and creates an open report.
- report_member uses SECURITY DEFINER with search_path = public, pg_temp; only authenticated execution is granted. The existing table grants still prevent member writes, and ordinary members cannot read reports.
- moderate_community_report already operates on the reports row type; no new moderation permissions or actions were added. Admins can Resolve or Dismiss, with reviewed_at/reviewed_by recorded. This does not apply an account penalty.
- The profile form is hidden for self/signed-out viewers. Changing accounts closes the profile and discards any report draft. Existing post/comment reports retain their RPC path.
- The admin Reports tab selects the member public ID and batches profile-name lookup. Member-supplied names/details are rendered as text. No new auth ID or email lookup was introduced for the reported member.

Verification: signed-out/self/unknown-target/null-or-invalid-reason/overlong-details rejection, authenticated submission, duplicate-open-report protection, private report reads, non-admin moderation rejection, and stored receipt fields passed rollback SQL checks. Frontend tests covered validation, double submission, error recovery, existing content-report RPCs, and safe admin rendering. Live tests covered member submission, duplicate rejection, new submission after dismissal, admin target/details, Dismiss, Resolve, and dismissal persistence after refresh. Success-state Close labeling and a concurrent database race were not separately exercised live.

Closeout notes (Phase 9C, verified live 2026-10-19):

- **Table:** `community_reports` holds post, comment and member reports. The `community_reports_exactly_one_target_check` constraint requires exactly one of `post_id`, `comment_id` or `member_public_id`.
  - **Reasons** (CHECK): `harassment`, `hate_or_abuse`, `dangerous_content`, `spam`, `privacy`, `other`.
  - **Details:** optional, at most 500 characters, and trimmed (blank is stored as NULL).
  - **Status:** `open`, `resolved` or `dismissed`, plus `reviewed_at`/`reviewed_by`.
  - **Foreign keys:** `reporter_user_id` references `auth.users` and `member_public_id` references `profiles(public_id)`, both `ON DELETE CASCADE`.
- **Access:** RLS is on with one policy, `community_reports_select`, which is SELECT `using is_admin()`. `authenticated` holds only a SELECT grant, so non-admins see no rows; there are no INSERT/UPDATE/DELETE grants. Members write only through `report_member` or `report_community_content`. Both are `security definer` with `search_path = public, pg_temp`, executable by authenticated users only (not anon), and return just a receipt id.
- **Duplicates:** there's one *open* report per reporter per target. Partial unique indexes cover posts, comments and members, and `report_member` turns a violation into "You already have an open report for this member." (`23505`). After a report is resolved or dismissed, the same reporter can report again.
- **Reporter privacy:** the reported member gets no notification (there's no trigger and no notification type for reports), and there's no public count, view or history. Only admins can read reports. The admin Reports tab shows the reporter's display name (looked up by admin) and the reported member's name and public id. All member-written text is rendered with `textContent`.
- **Moderation:** `moderate_community_report(id, 'resolve' | 'dismiss')` is admin-only and works on open reports only. It records the review and applies no penalty. Reporting never blocks, mutes, unfollows or removes content.
- **Migration history (re-checked live, 2026-10-19):** `supabase_migrations.schema_migrations` still has its original 9 rows (through `phase7d_admin_avatar_removal`). **Eight** migrations were applied manually in the SQL Editor and are not recorded there:
  - 8A `phase8a_member_follows`
  - 8B-1 `phase8b1_handles_mentions_foundation`
  - 8C-1 `phase8c1_mention_notifications`
  - 8C-3 `phase8c3_follow_notifications`
  - 9A `phase9a_blocking_foundation`
  - 9B-1 `phase9b1_member_mutes`
  - 9C-1 `phase9c1_member_reports`
  - 10A `phase10a_community_growth` (community growth/milestones; its tables and functions are live)

  No history rows have been added by hand. The files in `supabase/migrations/` are the record.

## Phase 11A — My Recovery v1

Migration: `migrations/phase11a_my_recovery_v1.sql`. It's additive only (no DROP, ALTER or DELETE of existing objects). It was applied through the normal migration tool on 2026-10-19, so it **is** recorded in `schema_migrations` (row 10, `phase11a_my_recovery_v1`).

- **`recovery_daily_logs`:**
  - Columns: `id`, `user_id` (references `auth.users`, `ON DELETE CASCADE`), `log_date`, `mood` (1–5), `cravings` (0–10), `win_text`, `need_text` (each 1–300 characters or NULL), `created_at`, `updated_at`.
  - `unique (user_id, log_date)` enforces one row per member per date. A CHECK requires at least one value.
  - `log_date` is the member's local date. The RPC accepts up to one day past the server's UTC date and back to 366 days.
- **`recovery_goals`:**
  - Columns: `id`, `user_id` (`ON DELETE CASCADE`), `goal_text` (1–200), `target_date`, `completed`, `completed_at`, `cleared_at`, `created_at`, `updated_at`.
  - The partial unique index `recovery_goals_one_active_idx (user_id) where cleared_at is null` allows only one active goal. Clearing or replacing a goal sets `cleared_at`, and the row is kept.
- **Access:** RLS is on with **no policies**, and `public`, `anon` and `authenticated` have **no table privileges**. Members use only these RPCs:
  - `save_my_recovery_log(date, int, int, text, text)` upserts. Every field is replaced, and blank notes are stored as NULL.
  - `list_my_recovery_logs(p_since date)` returns the newest rows first, at most 60.
  - `get_my_recovery_goal()`.
  - `set_my_recovery_goal(text, date, p_replace boolean)` edits the active goal, or clears it and starts a new one.
  - `set_my_recovery_goal_completed(boolean)`.
  - `clear_my_recovery_goal()`.

  Each is `security definer` with `search_path = public, pg_temp`, executable by `authenticated` only (revoked from public/anon). Each acts on `auth.uid()`'s rows only and returns no `id` or `user_id`. Errors use `42501` for no session, `22023` for validation, and `P0002` for no current goal.
- **No other paths:** there's no admin RPC or policy, no view, no trigger, and no link to Community, profiles, notifications or badges. The app never uploads the on-device Check-In or Recovery Counter.

**Verification (2026-10-19):**
- **Privileges:** `has_table_privilege` is false for anon and authenticated on both tables, and EXECUTE is authenticated-only.
- **Rollback DO block** (two throwaway users, ending in RAISE EXCEPTION). These passed:
  - anon RPC and table access are denied, and direct table access as authenticated is denied;
  - save, then update, keeps one row per date;
  - validation rejects mood 6, cravings 11, an empty entry, 301 characters and a date in the future, and accepts 300 characters;
  - goals: create, edit (same row), complete, uncomplete, and replace (old row kept, one active). Blank and 201-character goals are rejected, and clear is idempotent;
  - member B sees none of A's logs or goals, and B's clear and complete calls don't touch A's;
  - Community post, comment and notification counts are unchanged.
- **Browser fixture suite (77 checks):** signed-out view, local Check-In and Counter, save/update/reload, the 7-day summary, 7/30-day history, editing past entries, the goal lifecycle, account switch and sign-out clearing, the error/retry path, no XSS, no recovery calls from Community, mobile (390px) and desktop header fit, and admin load.
- **Real data** was untouched: the new tables are empty after testing, and there are still 5 users, 2 posts, 4 comments and 1 notification.

## Phase 11B — Daily Porch v1

Migration: `migrations/phase11b_daily_porch_v1.sql`. It's additive only (no DROP, ALTER or DELETE). It was applied through the normal migration tool on 2026-10-19, so it **is** recorded in `schema_migrations` (row 11, `phase11b_daily_porch_v1`). The Daily Porch content isn't in the database: it's public app content in `CONFIG.dailyEntries`.

- **`recovery_daily_reflections`:**
  - Columns: `id`, `user_id` (references `auth.users`, `ON DELETE CASCADE`), `reflection_date`, `morning_text`, `evening_text` (each 1–500 characters or NULL), `created_at`, `updated_at`.
  - `unique (user_id, reflection_date)` gives one row per member per local date.
  - It's deliberately separate from `recovery_daily_logs`, so reflections never count as My Recovery entries or change its rules.
- **`saved_daily_porch`:**
  - Columns: `user_id` (`ON DELETE CASCADE`), `day_number` (1–365), `saved`, `saved_at`, `updated_at`. The primary key is `(user_id, day_number)`.
  - Unsave sets `saved = false` (the row is kept), which keeps the migration free of DELETE.
- **Access:** RLS is on with **no policies**, and `public`, `anon` and `authenticated` have **no table privileges**. Members use only these RPCs:
  - `save_my_daily_reflection(date, p_part 'morning'|'evening', text)` sets one part and leaves the other untouched. Blank text clears that part.
  - `list_my_daily_reflections(p_since date)` returns non-empty rows only, newest first, at most 60.
  - `set_daily_porch_saved(p_day int, p_saved bool)` is idempotent and keeps the original `saved_at` on a repeat save.
  - `list_my_saved_daily_porch()`.

  Each is `security definer` with `search_path = public, pg_temp`, executable by `authenticated` only. Each acts on `auth.uid()`'s rows and returns no `id` or `user_id`. Errors use `42501` for no session and `22023` for validation (bad part, more than 500 characters, a date more than a day ahead or more than 366 days back, a day outside 1–365).
- **No other paths:** there's no admin policy or RPC, no view, no trigger, no public counts, and no link to Community, profiles or notifications.

**Verification (2026-10-19):**
- **Privileges:** `has_table_privilege` is false for anon and authenticated on both tables, and EXECUTE is authenticated-only.
- **Rollback DO block** (two throwaway users). These passed:
  - anon RPC and table access are denied, and direct table access as authenticated is denied;
  - morning and evening save independently, an update keeps one row per date, blank clears a part, and empty rows are hidden from the list;
  - validation rejects a bad part, 501 characters, a future date and days 0 or 366, and accepts 500 characters;
  - save is idempotent, and unsave hides the day from the list;
  - member B sees none of A's reflections or saves, and B's writes don't touch A's;
  - My Recovery logs and Community post, comment and notification counts are unchanged.
- **Browser fixture suite:** 72 checks passed (see the Daily Porch section of the main README).

## What's next

**Phase 0 is complete and verified** — `schema.sql` ran clean against the dedicated FPR Supabase project, and all verification checks above passed, including the previously-deferred admin-access test.

**Phase 1 is complete and verified** — `supabase-js` and an optional, magic-link-only sign-in flow were added to `index.html` (anonymous use remains the default; Recovery Counter and Daily Check-In stay on-device, untouched).

**The `porch_stories_public` privilege correction above has been applied and verified** — `anon`/`authenticated` now have `select`-only on that view, confirmed via live permission tests and `has_table_privilege()`.

**Phase 2 is complete and live** — the read-only admin Porch Stories dashboard (`admin.html`) reads `porch_stories` directly as an authenticated admin session, gated by `is_admin()`/RLS exactly as described above.

**Phase 3 is complete and deployed** — the `submit-porch-story` Edge Function above is live, and `index.html`'s Porch Story form now submits to it instead of inserting anywhere directly. See the "Phase 3" section above for the full contract and the verification results recorded alongside this change.

**Phase 4 is complete and verified** — secure Porch Story moderation (approve/reject/publish/edit) is live in `admin.html`, enforced at the database level by `moderate_porch_story()`. See the "Phase 4" section above.

**Phase 5 is complete and deployed** — published database Porch Stories now appear automatically on the public Porch Stories page in `index.html`, merged with the three built-in `CONFIG.stories`, rendered entirely via safe DOM construction.

**Phase 6A is complete and deployed** — the Community Posts foundation described above (`community_posts`, its public view, its RPCs, the Community page in `index.html`, and the Community Posts moderation tab in `admin.html`) is live and was verified against all 25 required tests.

**Phase 6B is complete and deployed** — comments, one-level replies, own comment/reply editing, member reporting, and admin Community Posts, Community Comments, and Reports (resolve/dismiss) moderation. See the "Phase 6B" section above.

**Phase 6C is complete and deployed** — support/heart/celebrate reactions (one active reaction per member per target), aggregate reaction counts, in-app notifications with unread/read handling, and posts-only Community search. See the "Phase 6C" section above.

**Phase 7 is complete and deployed** — member profiles: opaque `public_id`, optional bio, photo, and recovery date with private/members/public visibility, the own-profile editor, the Community profile panel with recent posts, author avatars, and admin profile moderation. See the "Phase 7" section above.

**Phase 8A is complete** — private member follows (see "Phase 8A" above).

**Still not built:** DMs, public follower lists or counts, a member directory, anonymous posting, general uploads (only profile photos), groups, push/email/SMS notifications, and on-site payment processing. Optional Support FPR contributions use an external Cash App link; no payment credentials or transaction records are stored by this website.

Live migration history: `phase0_fpr_schema`, `fix_porch_stories_public_grants`, `phase4_porch_story_moderation`, `phase6a_community_posts_foundation`, `phase6b_comments_replies_reports`, `phase6c_community_engagement`, `phase7a_member_profiles_foundation`, `phase7b_revoke_direct_profile_update`, `phase7d_admin_avatar_removal`, `phase11a_my_recovery_v1`, `phase11b_daily_porch_v1`. `phase8a_member_follows` was applied directly in the SQL Editor (unchanged from `migrations/phase8a_member_follows.sql`), so it does not appear in the migration history. The Phase 6A member-read fix and the Phase 6B open-report fix were applied directly; their SQL is kept in `migrations/` as a record.
