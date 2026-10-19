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

- **Phase 9B — Member muting** — deployed and checked live: profile Mute/Unmute, private Muted members list, hidden feed/search posts, collapsed comments/replies, and notification filtering.
- **Support FPR** — deployed and checked live: optional support section on the Porch Shop page, footer access, Books/Etsy links, and an external Cash App link to the FPR business profile ($FPR2026). The website does not process payments.
- **Phase 9C — Report a member** — deployed: profile report form and private admin review alongside existing content reports. Live checks covered submission, duplicate-open-report prevention, reporting again after dismissal, target identification, Dismiss, Resolve, and dismissal persistence after refresh.
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
- Member reporting:
  - Signed-in members can report another member from their profile, choosing a reason and optionally adding up to 500 characters of details. Self-reports are rejected.
  - Only one open member report per reporter/target pair is permitted. A new report can be submitted once the earlier one is resolved or dismissed.
  - Reports are reviewed in the admin Reports tab. Resolve/Dismiss record the review; neither automatically suspends, blocks, or mutes the member. No report notification is sent to the target.
- Handles: an optional, unique public `@handle` (3–24 characters: lowercase letters, numbers and single underscores, starting with a letter; changeable once every 30 days; admins can reset but not assign one)
- @mentions: `@handle` in a post, comment or reply links to that member's profile. Mentions are stored by the database when the text is saved and bound to the member's public id, so older text keeps working after a handle change (see `supabase/README.md` for the one edit-after-rename caveat)
- @handle autocomplete for signed-in members in the post, comment and reply boxes

Database migrations are in `supabase/migrations/`; backend details are in `supabase/README.md`.
