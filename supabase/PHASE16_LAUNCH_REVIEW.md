# Phase 16 — launch review

Reviewed October 24, 2026. Decision: HOLD real payments. Phase 15 was deployed disabled; Phase 16 does not authorize live Stripe configuration, purchases, or activation.

## Accepted evidence — do not repeat

- GitHub 9c7e200 deployed successfully; new public membership interface present.
- Production availability returned sandbox=false, service_ready=false, checkout_open=false. Disabled live webhook returned HTTP 503.
- Admin's SQL result shows checkout_enabled=false and benefits_enabled=false. This is private database evidence supplied by the operator, not a claim that anonymous availability can read those flags while the runtime is disabled.
- Phase 15 local evidence: 64 server/DOM tests, complete migration fixture and five function typechecks passed. Phase 12–14 sandbox purchase/cancellation, independent access grants, saved reflection, expiry/read/clear and clean card flow were already accepted. They are not prerequisites to repeat for this phase.

## Review findings and work completed

- The public Terms had no description of workbook/collection grants and appeared to prohibit sharing the offered celebration-card download. Added the actual current access rules and a specific personal card-sharing permission.
- Privacy now describes the internal billing reference sent to Stripe and the general, non-personal card image saved on the member's device. Recovery writing is excluded from Stripe.
- Updated the legal-page date to October 24, 2026. Real payments remain described as closed.
- Owner selected: review refund requests individually, refund billing mistakes, cancel future renewals at the end of the paid period. Published as planned terms, not an assertion of an active paid service.
- Added tools/verify-membership-deployment.mjs: bounded read-only hosted checks for page controls, disabled routes and anonymous denial of installed own-status functions. A failed check is an investigation item, not a request to repeat purchases. This script is intentionally for the closed phase and must be revised when processing is explicitly configured later.

## Technical review

Private database tables use RLS and revoke browser roles. The service-only lease and snapshot functions cannot be called by members. Own-status RPC uses auth.uid(); it returns access metadata, not customer IDs, other members, or answers. Saved workbook reading and clearing remain owner-only after expiry. Admin grant controls do not expose answers. Tests exercise these rules with actual SQL migrations.

Confirmed users are required on production actions; sandbox remains admin-only. Server selects price, customer, currency, plan quantity and redirects. New sales need both database gates and valid explicitly enabled live configuration. Existing customers retain management when only new sales closes. Webhook processing verifies raw-body signature and mode, then rereads canonical Stripe state under a lease. Failures return retryable status; no webhook event payload can directly grant access. Logging uses fixed stages/categories, not payment payloads or private writing.

Production management UI uses labeled native buttons, a polite status region, an explicit sign-in action, focusable destination heading, keyboard-operable controls and HTTPS Stripe redirect validation. Existing DOM checks cover hidden closed controls, disabled unsigned purchase, account switching, failures and late redirect suppression. A full assistive-technology or real hosted live Checkout acceptance is not claimed.

## Remaining launch gates

| Gate | Current status | Required resolution |
| --- | --- | --- |
| Refund/cancellation policy | Owner approved individually reviewed refunds, billing mistakes refunded, period-end cancellation | Configure portal to match; confirm final launch copy |
| Stripe live account | Not inspected; no live credentials used | Owner-authorized review of account activation, payout readiness, business/support identity and statement descriptor |
| Catalog | Not created/verified in live mode | One approved product; USD 300 monthly and 2500 yearly, licensed quantity one, no trial or promotions at launch |
| Tax | Not decided; automatic_tax is not enabled by current Checkout code | Determine selling regions, registrations, product treatment and inclusive/exclusive pricing; adjust implementation and disclosures if tax collection is needed. Do not infer that no tax is owed from the absence of Stripe Tax configuration |
| Receipts and customer email | Not configured/verified | Checkout collects billing contact; current customer creation sends only internal FPR reference, not account email. Verify how live Checkout populates the existing Customer email and whether receipts/invoices reach the intended address. Set business support identity and customer-email settings; do not claim receipts work yet |
| Live portal | Not configured | Cancel at period end; payment method and invoice management enabled. Keep plan switching, quantity changes, coupons and retention offers off for the initial release |
| Restricted key | Not configured | Use the minimum resource permissions below; store only in Supabase Secrets |
| Live webhook | Not registered | Separate HTTPS endpoint stripe-live-webhook, live snapshot events, compatible API version and separate signing secret; register the exact event list in PRODUCTION_MEMBERSHIP.md |
| Privacy/Terms final paid version | Current closed-state copy prepared; paid copy below | Publish final approved paid disclosures before enabling checkout; remove closed-only language consistently |
| Refund/dispute operations | Manual workflow defined below; no automated entitlement reaction | Identify the person monitoring notifications. Refunds alone do not cancel a subscription or alter the paid snapshot; explicitly decide and perform any cancellation. No automatic chargeback access rule is claimed |
| Account deletion | No self-service deletion; FK cascades billing link | Before any manual Auth deletion, reconcile/cancel live subscriptions and outstanding sessions, preserve required billing evidence securely, and verify cancellation. Deleting an FPR account alone does not cancel Stripe billing |
| Monitoring | Runbook below; no background monitor installed | Owner must establish a monitored notification destination and responsibility before launch |
| Launch approval | NOT given | Separate explicit approval, followed by one controlled real purchase in Phase 17 |

## Minimum Stripe key resource review

Implementation calls: customers.create (Customers write); prices.retrieve (Prices read, with product access if Stripe permission dependencies require it); subscriptions.list with latest_invoice expansion (Subscriptions read and Invoices read); invoices.listLineItems (Invoices read); checkout.sessions.list/create/expire (Checkout Sessions write); billingPortal.sessions.create using a fixed configuration (Customer Portal session write and configuration read as required by Stripe). No application refund, payout, balance-transfer, product-writing, subscription-cancel/update or webhook-registration permission is required. Dashboard permission names/dependencies must be confirmed in the live account rather than guessed. Webhook signature verification is local and does not require Events read. Keep provisioning/operational privileges out of the app key.

## Final paid copy prepared for launch, not yet published as an active offer

Porch Supporter is an optional recurring membership, $3 USD per month or $25 USD per year, billed in advance and renewed automatically until canceled. It includes the seven-reflection Pull Up a Chair workbook and six clean celebration-card designs. Existing recovery tools and Community remain free. Cancel future renewals through Account → Manage paid membership; paid access continues through its end date. Refund requests are reviewed individually, and billing mistakes are refunded. Contact frontporchrecovery@gmail.com for billing help. No-charge access grants are independent of billing. Members can still read or clear saved workbook reflections after access ends and keep cards already downloaded. Applicable tax wording must be finalized before this copy is used.

For the paid Privacy update: Stripe handles checkout, payment details, invoices and billing management under its own privacy policy. FPR stores the linked customer/subscription references, status, access end and cancellation scheduling in Supabase, separately from recovery writing. An internal account reference links checkout to the correct account. No workbook answers, journal writing or recovery history are sent to Stripe. Do not promise immediate deletion of billing records or encryption against the service operator; establish the retention/deletion procedure first.

## Refund, dispute and deletion handling

1. Verify the request belongs to the account/customer without asking for card numbers or private recovery writing. Locate the transaction in Stripe, review billing error/refund request under the approved policy, and record a minimal billing decision separately from recovery records.
2. Issue any approved refund in Stripe Dashboard; verify its actual status before telling the customer it succeeded. Confirm future-renewal intent separately. A refund does not itself cancel a subscription, and current FPR code does not inspect refund/dispute events.
3. If ending the subscription immediately is appropriate to the agreed resolution, do it explicitly in Stripe, then reconcile through the supported member status refresh or verified subscription webhook. Do not directly manufacture an active database snapshot. An independent no-charge grant must not be revoked merely because billing ends.
4. Review disputes promptly in Stripe using its stated response deadline; retain only relevant billing/service evidence. Do not attach workbook answers or other recovery records. No automatic access revocation is currently implemented.
5. Before deleting Auth users, handle Stripe subscriptions and open Checkout sessions first. The local FK cascade would otherwise remove the customer link while external billing continues. Document any legally required retention separately; do not improvise a retention period.

## Monitoring and incident response

Owner responsibility must cover Stripe failed webhook deliveries, payment failures/actions, refunds/disputes, and Supabase production function error rates. Stripe delivery retries are not a monitoring system. Review unmatched-customer cases before deletion/migration; current webhook acknowledges an unknown customer without creating an account or entitlement. Keep paid support requests and operational evidence separate from recovery writing.

For a launch incident: close checkout_enabled only; preserve benefits_enabled and live runtime so existing subscribers can manage/cancel and receive canonical updates. Identify and expire outstanding FPR Checkout sessions if the incident requires stopping already-issued links; the app key can expire sessions, but no automated operator tool has been installed. Closing new checkout alone does not cancel sessions or subscriptions. Notify affected customers using an explicitly authorized channel. If credentials are compromised, rotate them and plan reconciliation of missed updates before restoring processing.

## Primary sources checked October 24, 2026

- Portal settings: https://docs.stripe.com/customer-management/configure-portal
- Integration security: https://docs.stripe.com/security/guide
- Refund operations: https://docs.stripe.com/refunds
- Webhook verification, retries and operational handling: https://docs.stripe.com/webhooks
- Tax integration: https://docs.stripe.com/tax/checkout

No live account is configured or launched by this review. Required business/account gates remain explicit rather than silently treated as passed.

## Final verification for this review

October 24, 2026, 7:49 PM America/Denver (2026-10-25T01:49Z): all five hosted closed-deployment checks passed. Both own-status RPCs now exist and deny anonymous calls with HTTP 401 / 42501; the earlier schema-cache missing-function result has cleared. Production availability and webhook remain disabled. Seven existing production UI tests passed after the public-copy edits; both inline scripts parsed successfully. No SQL, Edge Function behavior, access settings, live Stripe configuration, payment, or cancellation was changed in this phase.

Publication: this review's Terms/Privacy edits need the resulting Git commit pushed to main. No migration or function deployment is required for Phase 16.
