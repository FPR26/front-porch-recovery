# Front Porch Recovery

Official Front Porch Recovery website and PWA.

One honest day at a time.

Live site: https://fpr26.github.io/front-porch-recovery/

## Status

- **PWA / install** — live. The site installs as an app from the root URL above (`manifest.webmanifest`, `sw.js`).
- **Phase 6B** — complete: Community comments, one-level replies, and member reporting.
- **Phase 6C** — complete and live: reactions, in-app notifications, and post search.
- **Phase 7 — Member Profiles** — complete and live: display name, optional bio, profile photo, and recovery date with private / members / public visibility; profile panel with recent posts; author avatars; admin profile moderation.
- **Phase 8A — Following** — private member follows: Follow / Unfollow from a member's profile panel and a Following list visible only to you. No public follower lists or counts.

## Community features

- Posts, comments, and one-level replies
- Reactions (support, heart, celebrate) — one per member per post or comment, with public counts
- In-app notifications for replies and first reactions (no push, email, or SMS)
- Post search (published posts only)
- Member reporting of posts and comments
- Admin moderation in `admin.html` (hide, restore, remove; reports resolve/dismiss; member profile moderation)
- Member profiles: edit your own profile from the account window; click an author to see their profile and recent posts

Database migrations are in `supabase/migrations/`; backend details are in `supabase/README.md`.
