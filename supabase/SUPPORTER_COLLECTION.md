# Phase 14 — member collection delivery

Prepared October 24, 2026. Implementation and local verification complete; hosted deployment pending. Real payments remain closed.

## Member experience

Account has Open my workbook and Open my card collection. Both use the existing same-page navigation, close the account window and focus the named destination. The collection has its own current-access message, six-design picker, Download collection PNG, optional rendered preview, and Refresh collection access. No-charge grants, sandbox test subscriptions and admin access use the same existing server entitlement as the workbook. Inactive/signed-out members retain all six labeled sample downloads. Owners retain saved workbook reading/deletion after access ends.

Every clean download calls supporter-cards with only a fixed design ID. The Edge Function validates the bearer token using Supabase Auth and calls get_my_supporter_benefits using that token. That RPC returns access metadata only; no workbook answers, payment data, customer IDs, user IDs or unrelated profiles are read or returned. Inactive access returns 403; unauthenticated returns 401; unknown design/invalid input returns 400; unavailable access returns 503. Only the six release designs are accepted. Payload and response are no-store. No service-role or Stripe key is used by this function.

The authenticated response contains fixed vector artwork and the official logo as separate PNG data. The browser composites both to a 1200 x 1200 PNG with the release filename. Keeping the logo separate avoids relying on embedded-image SVG decoding. Download and preview are suppressed after sign-out/account change. Errors hide collection controls and offer refresh; labeled samples continue working. Blob URLs are revoked. No automatic posting, sharing or private personalization is implemented. Existing downloads cannot be recalled after access ends. Public sample art is visible; this is controlled delivery, not DRM.

## Deploy once, in order

1. Apply ONLY migrations/phase14a_supporter_benefits.sql in Supabase SQL Editor. It adds a read-only own-access RPC. Do not rerun prior migrations.
2. From the repo in the user's authenticated VS Code terminal, deploy ONLY supporter-cards with --project-ref ptmazxslypzslhhcqudn. config.toml disables gateway JWT validation only because this handler verifies Auth and current entitlement itself on every POST. No existing function needs redeployment.
3. Push the committed website. Confirm Pages deployment directly. No new secret, Stripe configuration or payment test required.
4. A single hosted collection download is the only new operator acceptance case. Do not repeat checkout, scheduled cancellation, no-charge grant/revocation, or workbook save checks already completed. Signed-out endpoint rejection and deployed markup can be checked directly by the agent.

## Verification

- Actual PostgreSQL-compatible migration fixture: own access only, anonymous execution denied, inactive/active grant handling and no private-answer fields; existing isolation/revocation/expiry/stale-write checks also pass.
- Four server tests: unauthorized/inactive rejection, access rechecked after revocation, allowed-design validation, oversized/malformed requests, foreign origins, safe errors and catalog parity.
- Four DOM tests: signed-out/free sample behavior, active download via endpoint, PNG composition, sign-out during a pending request, revocation/server failure, sandbox label and scheduled cancellation.
- Actual render test decodes all six vector artworks, composites the official logo, checks visible logo pixels, exports/decodes 1200 x 1200 PNGs, and produces a visually inspected contact sheet. Preview/sample labels remain covered by the Phase 13 renderer test.
- Deno typecheck for the new Edge Function uses the existing pinned Supabase SDK and lockfile. No new browser dependency or new package is introduced.

Phone save-menu behavior still depends on the browser; success text identifies its download/sharing menu. Local tests are not claimed as hosted authenticated acceptance.
