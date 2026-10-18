# Front Porch Recovery

Official Front Porch Recovery website and PWA.

One honest day at a time.

Live site: https://fpr26.github.io/front-porch-recovery/

## Status

- **PWA / install** — live. The site installs as an app from the root URL above (`manifest.webmanifest`, `sw.js`).
- **Phase 6B** — complete: Community comments, one-level replies, and member reporting.
- **Phase 6C** — complete and live: reactions, in-app notifications, and post search.
- **Phase 7 — Member Profiles** — complete and live: display name, optional bio, profile photo, and recovery date with private / members / public visibility; profile panel with recent posts; author avatars; admin profile moderation.
- **Phase 8A — Following** — private member follows: Follow / Unfollow from a member's profile panel and a private Following list. No public follower lists or counts.
- **Phase 8B — Handles and @mentions** — complete: optional unique public handles, clickable @mentions in posts, comments and replies, and @handle autocomplete in the composers.
- **Phase 8C — Connection notifications** — complete: in-app notifications when you're @mentioned or followed, alongside the existing reply and reaction notifications.

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
- Member reporting of posts and comments
- Admin moderation in `admin.html` (hide, restore, remove; reports resolve/dismiss; member profile moderation)
- Member profiles: edit your own profile from the account window; click an author to see their profile and recent posts
- Following: your Following list is private, and there are no public follower lists or counts; a member you follow gets an in-app notification saying you followed them (removed if you unfollow)
- Handles: an optional, unique public `@handle` (3–24 characters: lowercase letters, numbers and single underscores, starting with a letter; changeable once every 30 days; admins can reset but not assign one)
- @mentions: `@handle` in a post, comment or reply links to that member's profile. Mentions are stored by the database when the text is saved and bound to the member's public id, so older text keeps working after a handle change (see `supabase/README.md` for the one edit-after-rename caveat)
- @handle autocomplete for signed-in members in the post, comment and reply boxes

Database migrations are in `supabase/migrations/`; backend details are in `supabase/README.md`.
