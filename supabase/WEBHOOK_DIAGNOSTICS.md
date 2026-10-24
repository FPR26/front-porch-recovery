# Sandbox webhook diagnostics

Prepared October 24, 2026. Historical hosted 503 cause remains unconfirmed.

Signed webhook handlers retry a denied database claim after 150, 350 and 750 ms. If still busy, return 503 for Stripe redelivery. Database/Stripe operation errors are not internally retried. Admin API contention still returns 409 immediately. Every successful webhook still reads canonical Stripe state under the per-user lock before writing; no event payload can directly grant access.

Safe JSON error logs identify component membership and stage customer_lookup, lock_claim, stripe_subscriptions, snapshot_save, lock_release or request. Category is a fixed allowlist (busy, operation_failed or Stripe SDK error class); numeric HTTP error status is included when available. No raw errors, messages, user/customer IDs, event bodies, headers, answers, payment details or credentials are logged. A cleanup error cannot mask an earlier action failure; logger errors cannot change responses.

Validation: all 21 billing server/UI tests pass, including brief/persistent contention, operation-specific failures, diagnostic privacy, logger/cleanup failure and unchanged API contention. This is not evidence that historical hosted failures are fixed.

Deploy stripe-webhook and membership-api from the repository so both bundled copies of the shared handler receive diagnostics. No migration, secret changes or website rebuild required. Then redeliver one existing signed sandbox event in Stripe and inspect that fresh delivery; if it fails, the new function log should identify the operation. Real paid memberships remain disabled.
