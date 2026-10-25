# Phase 15 — production billing foundation (launch disabled)

Prepared October 24, 2026. This implementation is NOT authorization to activate real payments. No live Stripe API call was made during development. Live credentials, live products/prices, live portal and live webhook registration are NOT requested in this phase.

## Isolation and gates

- Sandbox retains membership_billing, membership-api, stripe-webhook, STRIPE_TEST_* and fpr-sandbox-* idempotency keys. Production uses membership_live_billing, membership-live-api, stripe-live-webhook, STRIPE_LIVE_* and fpr-live-* keys. No billing records are copied between tables.
- FPR_MEMBERSHIP_LIVE_ENABLED must be exactly true and every live credential/catalog setting must validate before the runtime constructs a Stripe client. Absent/false configuration responds to availability with service_ready=false and checkout_open=false, refuses POSTs, and never calls Stripe.
- membership_live_settings is private, service-only for SELECT/UPDATE, with checkout_enabled=false and benefits_enabled=false inserted by migration. New checkout requires BOTH flags; availability never returns keys, price IDs or customer IDs. A check runs before locking and again before returning an open session or creating a new one.
- Real paid entitlement also requires benefits_enabled, a server-verified active production snapshot, subscription ID and unexpired paid access end. No-charge grants remain independent. Entitlement priority is no-charge, enabled paid production, sandbox, admin. Clients cannot update billing rows, grants or launch settings directly.

## Production processing

Only confirmed authenticated members may create checkout, manage their own customer portal or synchronize their own production status. The server fixes identity, customer, return URLs, price/product, USD, $3/month or $25/year, one licensed recurring unit and interval count one. Open checkouts are reused; active/incomplete/past-due subscriptions prevent duplicate checkout. Body-provided user/customer/price/redirect data is ignored. Customer creation and checkout use separate production idempotency namespaces.

Webhook signature verification and strict live-mode checks precede processing. A per-user database lease serializes API and webhook writes. Canonical subscriptions are fetched from Stripe, rather than trusting event status. The Stripe SDK stays pinned to 19.1.0, with production requests explicitly pinned to API version 2025-09-30.clover. Subscription, item, price, currency, product and live-mode identity must agree. Paid access ends at the earliest of the subscription period end, cancellation date and the matched paid invoice-line coverage end. The positive recurring invoice line must belong to the same subscription item and approved price, cover now, and the invoice must be paid/live/USD. A fully credited invoice can qualify when its underlying recurring line is positive; zero-price trials do not qualify.

Truncated invoice lines are reread with limit 100; a still-truncated list fails with a retryable response rather than granting unverifiable access. More than 100 subscriptions also fails for review. Canceled, paused, unpaid, payment-pending, expired, wrong-customer, wrong-mode or mismatched invoice/price records do not grant paid access. Classic and flexible scheduled cancellation are normalized. Old/replayed events cannot restore canceled access using stale payloads.

Production webhook event list: checkout.session.completed, checkout.session.async_payment_succeeded, checkout.session.async_payment_failed, customer.subscription.created, customer.subscription.updated, customer.subscription.deleted, customer.subscription.paused, customer.subscription.resumed, invoice.paid, invoice.payment_failed, invoice.payment_action_required, invoice.voided, invoice.marked_uncollectible. Snapshot payloads suffice; only event type, mode and customer are used before canonical reread. The two new functions verify Auth/signatures internally with gateway JWT verification disabled for those routes only.

## Member experience

The real-payment panel stays hidden unless production availability permits signup or the signed-in member already has a production billing account. Prices and recurring terms are explicit. Existing members retain portal/refresh controls even when new checkout closes. Account can discover their management link on any page using own-status metadata; Stripe sync only runs on the supporter page. Returning from checkout or opening the page triggers server synchronization for an existing customer, then refreshes workbook and collection entitlement without discarding unsaved answers. Browser return alone never grants benefits. Sandbox responses cannot redirect through the production controls; only HTTPS checkout.stripe.com and billing.stripe.com are accepted. Sign-out invalidates pending redirects and clears management state. No new answer sharing or private browser persistence is added.

## Deploy DISABLED, in order

1. Apply ONLY migrations/phase15a_production_membership.sql after phases 12b/12c/12d/14a. Its final read-only query must show checkout_enabled=false and benefits_enabled=false. Do not change those values in this phase.
2. From the authenticated user terminal, deploy membership-live-api and stripe-live-webhook for project ptmazxslypzslhhcqudn. Existing sandbox/card functions do not require redeployment; their existing deployed behavior remains unchanged.
3. Push the committed website. No new secret or Stripe setup is required now. Do not enable FPR_MEMBERSHIP_LIVE_ENABLED.
4. Agent verifies GitHub deployment, public GET availability is closed, POST processing is disabled and existing free/member markup remains present. No repeat sandbox purchase, cancellation, grant or workbook tests are requested.

## Later configuration — RESERVED for approved launch preparation

Names only (values belong solely in Supabase Edge Function Secrets): STRIPE_LIVE_SECRET_KEY (restricted live key preferred; sandbox prefixes rejected), STRIPE_LIVE_WEBHOOK_SECRET, STRIPE_LIVE_PRODUCT_ID, STRIPE_LIVE_MONTHLY_PRICE_ID, STRIPE_LIVE_YEARLY_PRICE_ID, STRIPE_LIVE_PORTAL_CONFIGURATION_ID, FPR_MEMBERSHIP_LIVE_ENABLED. A complete valid configuration alone does not open checkout while the database gates are false. Live catalog/portal/webhook creation, credential entry and enabling switches require the user's explicit launch/configuration authorization. This document intentionally contains no activation command.

## Stop-sales / rollback

After an eventual launch, close NEW sales by setting only checkout_enabled=false through an authorized service/admin deployment process. Keep paid benefits and live processing on for existing customers, portal access, renewals and webhook reconciliation. This does not expire already-issued Stripe Checkout sessions or cancel subscriptions; any emergency plan must separately address outstanding sessions and Stripe billing. Disabling benefits is a separate access shutdown and is not the normal stop-sales procedure. Turning off FPR_MEMBERSHIP_LIVE_ENABLED disables portal/sync/webhooks too, so it is not a normal stop-sales switch. Reading/deleting saved workbook answers and independent no-charge grants remain available even if paid access ends.

## Verification and Phase 16 boundary

Actual PostgreSQL-compatible tests apply the complete migrations and verify closed defaults, private settings, mode isolation, paid access, stop-sales preserving existing access, revocation/expiry, stale lock denial, owner-only metadata and saved-answer retention. Production handler tests use synthetic fixtures only: credentials/gates, fixed prices/identity, separate idempotency, mode/customer isolation, paid invoice coverage, failed/paused/canceled state, invoice pagination and browser GET CORS. DOM tests cover closed/open UI, sign-in, existing member management after closing new sales, redirects, account switching and distinct paid benefit labels. Existing sandbox and collection/workbook regressions remain covered. Deno typechecks the new runtimes with the existing lockfile.

Not claimed: hosted authenticated production checkout, live payment processing, real catalog validation, real portal/webhook configuration or a production purchase. Phase 16 still reviews the live account/catalog, restricted key permissions, privacy/Terms changes (current public copy still states that real payments are closed), refund/dispute handling policy, tax/receipt configuration, operational monitoring and launch/rollback procedure. No automatic refund/dispute access rule is implemented in this phase; the policy must be resolved before launch. Live checkout must stay closed through that review. The first real purchase belongs only to the expressly approved controlled launch.

## Primary references checked during implementation

- Stripe subscription events and signature guidance: https://docs.stripe.com/billing/subscriptions/webhooks
- Key/mode separation: https://docs.stripe.com/keys
- Invoice-line service periods: https://docs.stripe.com/api/invoice-line-item/object
- Invoice and parent/lines fields: https://docs.stripe.com/api/invoices/object
- Installed pinned SDK type definitions confirm subscription-item current_period_end, invoice parent subscription details and subscription-item line references.

Final local verification: 64 server/DOM tests passed (38 Node, 26 Deno), the actual combined SQL migration fixture passed, all inline HTML scripts parsed, and all five relevant Edge Function entrypoints passed Deno typechecking. These are local/synthetic results, not a live-payment acceptance claim.

## Phase 16 review prepared

See `PHASE16_LAUNCH_REVIEW.md` for current accepted evidence, the owner-approved planned refund/cancellation policy, remaining launch gates, minimum key permissions and operational handling. The review does not authorize activation. `node tools/verify-membership-deployment.mjs` checks the disabled hosted deployment without repeating purchases.
