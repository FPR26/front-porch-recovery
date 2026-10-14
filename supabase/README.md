# Front Porch Recovery — Supabase Phase 0

This is the backend foundation only. **Nothing in the live site changes yet** — `index.html`, `sw.js`, and all existing public functionality are untouched. This is schema, policies, and functions in a new (or dedicated) Supabase project, for your review before anything runs.

See the architecture doc for the full plan, the phased migration, and the reasoning behind each design choice. This file covers what you need to actually run Phase 0 and what comes next.

## What `schema.sql` creates

- `profiles`, `admin_users`, `porch_stories` tables
- `porch_stories_public` view — the *only* way anyone reads a story publicly or as a non-admin member
- `is_admin()` and `submit_porch_story()` functions
- RLS policies, column-level and function-level grants/revokes, and `CHECK` constraints for all of the above
- An `on_auth_user_created` trigger that creates a `profiles` row automatically on sign-up

Community tables (`community_posts`, etc.) are **not** created — they're documented in the architecture doc for a later phase.

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

## What's next

**Phase 0 is complete and verified** — `schema.sql` ran clean against the dedicated FPR Supabase project, and all verification checks above passed, including the previously-deferred admin-access test.

**Phase 1 is complete and verified** — `supabase-js` and an optional, magic-link-only sign-in flow were added to `index.html` (anonymous use remains the default; Recovery Counter and Daily Check-In stay on-device, untouched; Porch Story submissions still go through the existing contact-form endpoint, not Supabase).

**The `porch_stories_public` privilege correction above has been applied and verified** — `anon`/`authenticated` now have `select`-only on that view, confirmed via live permission tests and `has_table_privilege()`.

**No Phase 2 work has begun.** The next step is Phase 2 — from the architecture doc's migration plan — and only after explicit approval.
