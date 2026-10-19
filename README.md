# Front Porch Recovery

Official Front Porch Recovery website and PWA.

One honest day at a time.

Live site: https://fpr26.github.io/front-porch-recovery/

## Status

- **PWA / install** — live. The site installs as an app from the root URL above (`manifest.webmanifest`, `sw.js`).
- **Phase 6B** — complete: Community comments, one-level replies, and post/comment reporting.
- **Phase 6C** — complete and live: reactions, in-app notifications, and post search.
- **Phase 7 — Member Profiles** — complete and live: display name, optional bio, profile photo, and recovery date with private / members / public visibility; profile panel with recent posts; author avatars; admin profile moderation.
- **Phase 8A — Following** — private member follows: Follow / Unfollow from a member's profile panel and a private Following list. No public follower lists or counts.
- **Phase 8B — Handles and @mentions** — complete: optional unique public handles, clickable @mentions in posts, comments and replies, and @handle autocomplete in the composers.
- **Phase 8C — Connection notifications** — complete: in-app notifications when you're @mentioned or followed, alongside the existing reply and reaction notifications.
- **Phase 9A — Member blocking** — complete: private blocking from a member's profile, with a private Blocked members list. Blocking and muting are separate controls (see below).

- **Phase 9B — Member muting** — complete: profile Mute/Unmute, private Muted members list, hidden feed/search posts, collapsed comments/replies, and notification filtering. Muting and blocking are independent.
- **Onboarding (ONBOARD-1, ONBOARD-2)** — complete: a small inline "Start here" card under the Home hero, plus a one-time Community orientation.
  - Signed out, it gives four quick pointers (Check In, the private counter, Rough day, reading the Community) and a short "What’s private?" explainer.
  - Signed in, it becomes a four-item checklist (check in today, choose a display name, optional @handle, visit the Community), with done states worked out from existing data.
  - "Got it"/"Done" dismiss it per device, and per account when signed in (keyed by public id). "Not now" hides it for the session. It can be replayed from Account ("Show the getting-started guide") or the footer ("Getting started").
  - On a signed-in member's first Community visit (per account, this device), a short inline note appears above search: "Welcome in. Posts here are public… you can Mute, Block, or Report anytime from a member's profile." It opens the existing "Manage what you see and report concerns" explainer once. "Got it" dismisses it for that account (`fpr_onboard_v1_community_seen:<public_id>`, separate from the visit flag the Home checklist uses). There's no replay for the note; it's intentionally one-time. Signed-out visitors don't see it.
  - Browser storage only: no database fields, no analytics, no money asks.
- **Support FPR** — complete: an optional "Help Keep the Porch Light On" card at the bottom of the Porch Shop (after the products), reached from the footer's "Support FPR" link. One "Support Front Porch Recovery" button opens the FPR Cash App business profile ($FPR2026) externally, with small links to the books and shop. FPR is free to use, the site never processes payments, contributions aren't tax-deductible (FPR isn't a registered nonprofit), and there are no support prompts in recovery tools, Community, or crisis content. Privacy and Terms mention Cash App.
- **Phase 9D — Safety polish** — complete: Mute · Block · Report share one subdued row in the profile panel, the account window groups Blocked and Muted members under "Safety & visibility", confirmation copy is consistent across the three, and the admin Reports tab adds a type filter (All/Member/Post/Comment) with Open as the default status.
- **Phase 9C — Report a member** — complete: profile report form and private admin review alongside existing content reports. Live checks covered submission, duplicate-open-report prevention, reporting again after dismissal, target identification, Dismiss, Resolve, and dismissal persistence after refresh.
- **Admin mobile layout** — deployed and checked on a phone: wrapping tabs, readable text, account header, and filters. Current checkpoint: main at e9ad981 on 2026-10-19.

## Community features

- Posts, comments, and one-level replies
- Reactions (support, heart, celebrate) — one per member per post or comment, with public counts
- In-app notifications (Community page, signed-in members only):
  - replies to your comments, first reactions to your posts and comments, @mentions of you in posts, comments and replies, and new followers
  - unread badge, per-item "Mark as read", and "Mark all as read"; opening the panel doesn't mark anything read
  - **View** on a mention goes to the post and scrolls to and highlights the exact comment or reply; **View profile** on a follow opens the follower's profile
  - the unread badge refreshes on each Community visit, after read actions, and when the tab becomes visible again on the Community page
  - no email, SMS or push notifications, and no polling or realtime connection
- Post search (published posts only)
- Reporting of posts, comments, and members
- Admin moderation in `admin.html` (hide, restore, remove; reports resolve/dismiss; member profile moderation)
- Member profiles: edit your own profile from the account window; click an author to see their profile and recent posts
- Following: your Following list is private, and there are no public follower lists or counts; a member you follow gets an in-app notification saying you followed them (removed if you unfollow)
- Blocking:
  - **Block member** / **Unblock** in a member's profile panel (with confirmation), and a private **Blocked members** list with Unblock in the account window. The blocked person isn't told.
  - Blocking removes follows both ways; unblocking doesn't restore them.
  - While either member has blocked the other, they can't follow each other, can't create new @mentions of each other (or find each other in autocomplete), and can't reply directly to each other's comments. New notifications between them are suppressed.
  - Public posts and comments stay visible to everyone, older mentions stay, and top-level comments and reactions are still allowed. Hiding someone's content (muting) is not part of 9A.
- Muting:
  - **Mute member** / **Unmute** in another member’s profile, plus a private **Muted members** account list.
  - Muted authors’ posts are excluded from the viewer’s Community feed and post search. Their comments and replies keep their place in the thread behind a **Show** placeholder.
  - Show temporarily reveals the original card and controls; refreshing collapses it again. Unmuting restores normal rendering and notification visibility.
  - Notification list/count exclude muted actors at read time; stored notifications are retained. Muting does not block interactions or remove follows, posts, comments, or reactions.
  - The client loads one mute cache for the signed-in identity, reloads on fpr:mutechange, and clears on sign-out. If loading fails, Community remains available and content is shown normally.
  - If every loaded post is from muted members, the feed says so ("You've muted the authors of some posts.") instead of implying the Community is empty.
  - A muted member's profile, including Recent Posts, stays visible when you open it on purpose.
  - Mute and block are independent: blocking doesn't mute, muting doesn't block, and unblocking or unmuting leaves the other in place. Muting doesn't remove follows or stop @mentions, autocomplete, replies, or reactions.
- Member reporting:
  - Signed-in members can report another member from their profile, choosing a reason and optionally adding up to 500 characters of details. Self-reports are rejected.
  - Only one open member report per reporter/target pair is permitted. A new report can be submitted once the earlier one is resolved or dismissed.
  - Reports are reviewed in the admin Reports tab. Resolve/Dismiss record the review; neither automatically suspends, blocks, or mutes the member. No report notification is sent to the target.
  - Reporter privacy: the reported member never learns who reported them and can't read reports; admins see the reporter's display name to review.
- Mute vs Block vs Report: **Mute** controls what you see, **Block** limits how someone can interact with you, and **Report** asks FPR's admins to review someone's behavior. They're independent: reporting doesn't block, mute, unfollow, remove content, or notify anyone.
- Handles: an optional, unique public `@handle` (3–24 characters: lowercase letters, numbers and single underscores, starting with a letter; changeable once every 30 days; admins can reset but not assign one)
- @mentions: `@handle` in a post, comment or reply links to that member's profile. Mentions are stored by the database when the text is saved and bound to the member's public id, so older text keeps working after a handle change (see `supabase/README.md` for the one edit-after-rename caveat)
- @handle autocomplete for signed-in members in the post, comment and reply boxes

Database migrations are in `supabase/migrations/`; backend details are in `supabase/README.md`.

## Community growth

The Community header displays the aggregate number of confirmed FPR accounts with profiles. Facebook membership, visits, and activity are not included. No individual browsing tracking was added. Milestones are 10, 25, 50, 100, 250, 500, 1,000, 2,500, 5,000, and 10,000.

The migration records already-passed thresholds silently at setup. Future milestones create one durable announcement per threshold. It remains recorded if the current count later decreases. Existing confirmed members can read it in a separate Community milestones section inside Notifications, with private, idempotent read receipts. It does not affect unread replies/reactions or Mark all as read. People who confirm after a milestone do not receive that older announcement. There is no email, push notification, polling, or per-member announcement fanout.

Apply supabase/migrations/phase10a_community_growth.sql and run supabase/verify_phase10a_community_growth.sql before publishing. The verification simulates a threshold inside a rollback transaction; the real count function is restored before the final result is selected. Frontend checks passed for counts, failure handling, milestone read state, and existing mute/report behavior. The rollback database checks subsequently passed, and the member-count display was confirmed live at be10862. A real milestone announcement has not yet been observed live.

## Community celebration cards (prepared; deployment pending)

Recorded milestone announcements offer View celebration. A separate accessible dialog uses the official CONFIG.brand.brandLogoUrl artwork to render a 1200 × 1200 PNG with the recorded threshold, community-growth wording, and site address. Cards do not include personal recovery dates or member identities. Download, retry, Escape, focus trapping/restoration, and object-URL cleanup are supported. Viewing/downloading does not mark the announcement read or change counts. No database migration, automatic posting, or external sharing is added. Sample exported images are design previews, not claims about the current membership.

Tests passed for modal lifecycle, failed artwork/retry, download requests, stale rendering cleanup, growth read state, and mute/report regressions. The actual renderer was used to export and visually inspect sample milestone cards. Browser/iPhone download behavior remains to be verified live.
