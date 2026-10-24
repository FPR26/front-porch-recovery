# Membership sandbox server: deployment and acceptance

This release is admin-only and TEST-only. It does not charge real money, restrict free tools, or activate production paid access. The default feature flag is disabled. No-charge workbook grants are implemented separately; real paid production entitlements remain future work.

## Implemented

- membership-api verifies Supabase Auth identity and is_admin on every action. Price, product, customer and return URLs are controlled on the server. It reuses open app Checkout sessions and rejects duplicate subscriptions. A per-user lock prevents overlapping requests.
- stripe-webhook verifies the raw Stripe signature using the official SDK, rejects live events, then fetches canonical Stripe subscription state under the same user lock. Replayed/out-of-order payloads cannot restore canceled access. Only active, paid, unexpired approved subscriptions record sandbox access.
- Private billing table stores identifiers and dates, never recovery text, card details or billing addresses. Own-status RPC returns sandbox=true, never customer identifiers. It must not authorize production benefits.
- Admin-only panel on #supporter provides test monthly/yearly checkout, customer portal, and status synchronization. Nonadmins have no new payment controls. Browser return never activates access.

## Exact deployment order

1. Apply ONLY migrations/phase12b_supporter_sandbox.sql in FPR's Supabase SQL Editor. No historical migrations need rerunning.
2. From this repository, with Supabase CLI installed and signed in:

```powershell
supabase functions deploy membership-api --project-ref ptmazxslypzslhhcqudn
supabase functions deploy stripe-webhook --project-ref ptmazxslypzslhhcqudn
```

The two gateway configurations in config.toml intentionally disable JWT gateway checks: the API validates the token and admin on the server; Stripe's webhook uses signatures instead. submit-porch-story remains unchanged.

3. Create a Stripe SANDBOX webhook destination:

https://ptmazxslypzslhhcqudn.supabase.co/functions/v1/stripe-webhook

Use snapshot events and these types: checkout.session.completed, checkout.session.async_payment_succeeded, checkout.session.async_payment_failed, customer.subscription.created, customer.subscription.updated, customer.subscription.deleted, invoice.paid, invoice.payment_failed.

4. Configure Stripe's sandbox customer portal with cancellation at period end enabled. Leave price switching disabled for this test. Save its configuration ID.
5. Save server configuration directly in Supabase project -> Edge Functions -> Secrets:

| Secret name | Value |
|---|---|
| STRIPE_TEST_SECRET_KEY | Replacement test secret key, entered directly. Expire the previously exposed key first. |
| STRIPE_TEST_WEBHOOK_SECRET | Signing secret for the new endpoint. |
| STRIPE_TEST_PRODUCT_ID | prod_VTyW339p5jJfiy |
| STRIPE_TEST_MONTHLY_PRICE_ID | price_1UT0ZFPGL7cABCD6v8j1Eb8W |
| STRIPE_TEST_YEARLY_PRICE_ID | price_1UT0b3PGL7cABCD6dPpAFpnl |
| STRIPE_TEST_PORTAL_CONFIGURATION_ID | Saved sandbox portal configuration ID. |

Never paste secret values in chat, source files, git or terminal arguments. Supabase supplies SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY automatically.

6. Enable LAST: set FPR_MEMBERSHIP_SANDBOX_ENABLED=true in the same Secrets page. Without it the functions fail closed and do not call Stripe. Live secret keys are rejected.
7. Publish the website commit. The admin dashboard has Open membership test controls, which opens the main FPR site at the admin-only Membership sandbox panel in the same browser.

## Hosted acceptance record (updated October 24, 2026)

Completed operator checks: monthly $3 and yearly $25 successful sandbox checkout; declined test payment without access; scheduled cancellation; immediate cancellation; nonadmin phone preview without billing controls; signature rejection and unauthenticated API rejection. Earlier failed checkout delivery recovered automatically October 21 at 21:10:14 (as displayed by Stripe), before October 24 diagnostics changes. Do not represent that historical recovery as verification of the new retry code.

October 24: phase12d applied, Pages deployed; monthly checkout produced explicitly labeled sandbox workbook access through November 24, 2026. Scheduled cancellation appeared in Stripe and then in the workbook after the combined-refresh fix aeb2bdc. User confirmed that message. These operator checks are complete; do not request repetition without a relevant regression or a new failure. Undo cancellation was an unnecessary additional check and is not a launch gate. Real payments remain disabled. Other cases covered only by automated tests must not be described as hosted acceptance.

## Local verification

Node: node --test tests/membership-server.test.mjs tests/membership-ui.test.mjs

Deno: deno check --node-modules-dir=none --lock=supabase/functions/deno.lock supabase/functions/membership-api/index.ts supabase/functions/stripe-webhook/index.ts

Deno signature test: deno test --node-modules-dir=none --lock=supabase/functions/deno.lock tests/membership-signature.test.ts

Actual migration separately ran in PostgreSQL-compatible PGlite: permissions, identity isolation, lock exclusion, stale writer refusal, and expired access denial passed. No live Stripe call was made and no user-provided secret was used. The hosted acceptance above is verified separately; remaining automated-only cases are not hosted evidence.
