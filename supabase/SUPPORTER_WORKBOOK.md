# Supporter workbook and no-charge access v1

This adds actual private saved workbook answers and admin-managed no-charge access, independent of Stripe sandbox status. Real billing remains disabled. Public prompts and sample cards remain free; the free Journal is unchanged.

## Behavior

- Seven reflection sessions, three answers each, up to 2,000 characters per answer. Explicit save only, optional completion, private progress (not an admin dashboard metric).
- Authenticated admins may write their own workbook. Other confirmed members require an unexpired, nonrevoked no-charge grant.
- Expired/revoked members can still read and clear their own saved entries. Nobody can read another member's answers through the app, including admins.
- No localStorage/cookies/offline queue for answers. A failed save retains the in-memory draft. Account changes immediately clear fields/cache and invalidate in-flight responses. Day switching/reload warn before discarding unsaved drafts; browser-close warning is best effort and may not appear on mobile.
- Version checks prevent stale-tab overwrites. A sequence prevents delete/recreate from reusing a version and accepting an old write.
- Admin -> Member Profiles -> Supporter workbook access: search confirmed members, grant/extend 30/90/365 days, revoke, and inspect the most recent 20 access changes. Search is literal substring, 50 members per page. Actor/action/date retained in access history; no private answers returned. Extending cannot shorten a longer active grant. No billing subscription is created/canceled.

## Apply and publish

1. Apply ONLY supabase/migrations/phase12c_supporter_workbook.sql in Supabase SQL Editor. No Stripe changes, secret changes, or Edge Function deployments are required.
2. Push the committed frontend/admin update and confirm Pages deploy. Before migration, private saving/access controls show an unavailable message; public preview and ordinary moderation continue.
3. Admin can use the workbook personally. To verify sponsored access, open Admin -> Member Profiles -> Supporter workbook access; search MAXOM; grant 30 days at no charge. On MAXOM's normal app session, return to the membership preview to load access and save a draft. Signout/account switching must not retain visible answers. Revoke access and verify saved answers remain readable but saving is disabled.
4. Clear any test reflection using the owner-only Clear saved reflection button. Do not retain private test answers, and revoke test grants when finished; grant history remains an admin record.

## Validation

- Actual migration ran in local PostgreSQL-compatible PGlite: owner isolation, admin cannot read others' answers, anonymous/direct-table denial, grant/extend/revoke and audit history, expiry retains reads, input limits/completion validation, stale writes, clear after revocation, delete/recreate version safety.
- Ten DOM interaction tests cover explicit save, draft preservation, unsaved navigation confirmation, revoked read-only/clear, signout/account switching, stale-response suppression, signed-out RPC avoidance, safe admin text rendering, grant confirmation, history and unavailable-backend behavior.
- Tests are repository files. Node DB test uses test-only @electric-sql/pglite 0.5.11 installed separately or selected via FPR_PGLITE_MODULE. Deno DOM tests use test-only linkedom pinned by tests/workbook-deno.lock. Neither is shipped as an app dependency.

```text
node tests/supporter-workbook-db.cjs
deno test --allow-read --lock=tests/workbook-deno.lock tests/supporter-workbook-ui.test.mjs tests/supporter-access-admin.test.mjs
```

Hosted/mobile visual and real-account acceptance remain pending until migration and deployment. No real member data or Stripe credentials were used in local tests. Historical 503 webhook retry remains an open billing issue; this release does not claim it fixed or enable real subscriptions.
