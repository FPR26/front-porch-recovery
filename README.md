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
- **My Recovery v1 (Phase 11A)** — complete: a signed-in, account-private daily recovery dashboard (see below).
- **My Recovery Plan v1 (Phase 11C)** — complete: a private, signed-in plan for hard moments (see below).
- **Meetings & Support v1 (Phase 11E)** — complete: public meeting/resource finders plus a private weekly support plan (see below).
- **Recovery Toolbox v1 (Phase 11D)** — complete: the existing Toolbox page reorganised into built-in tools with private pinning, grounding and breathing tools, and plan contacts (see below).
- **Daily Porch v1 (Phase 11B)** — complete: the existing 365-day Daily Porch page upgraded with today's date view, private morning/evening reflections, saved days, and recent days (see below).
- **Admin mobile layout** — deployed and checked on a phone: wrapping tabs, readable text, account header, and filters. Current checkpoint: main at e9ad981 on 2026-10-19.

## My Recovery

"My Recovery" (main nav, next to Check In; `#myrecovery`) is a private dashboard for signed-in members. Signed out, it explains what it is and offers Sign in; the Check-In and Recovery Counter still work without an account.

- **Private to the account, not the device.** Entries are saved with the member's account so they follow them across devices. The on-device Daily Check-In and Recovery Counter are unchanged and are never uploaded or copied into My Recovery.
- **Today:** one entry per member per calendar day (the member's local date): mood 1–5, cravings 0–10, "One win today" and "What do I need today?" (each optional, up to 300 characters). At least one field is needed to save. Saving again updates the same day, with a Saved/Unsaved state. Tapping a selected mood or cravings value again clears it.
- **Recovery Counter card:** shows the on-device counter's current days (read only), or a "Set up your Recovery Counter" button that goes to the home counter.
- **Last 7 days:** days logged out of 7, average mood, average cravings, and a 7-day strip. No interpretation, scoring or advice.
- **Current goal:** one active goal with an optional target date. Members can create, edit, mark complete or not complete, start a new goal (replaces the current one), and clear it. Cleared or replaced goals stay stored but aren't listed in v1.
- **Recent history:** the last 7 days, expandable to the last 30. Tap a day to see the full entry; past entries can be edited.
- **Not connected to anything else:** no Community, profile, badge, follower, notification or admin exposure; no AI, points or streak rankings. Member text is rendered as plain text.

The backend is `supabase/migrations/phase11a_my_recovery_v1.sql` (applied; see `supabase/README.md`).

## Daily Porch

The Daily Porch (`#daily`, "Daily Porch" in the nav) gives everyone something to carry through the day. It's the same page and the same content as before, upgraded rather than duplicated.

- **Content:** `CONFIG.dailyEntries` in `index.html`, all 365 days written. Each entry has `title`, `morningThought` (shown as the reflection), `question` ("Something to think about"), `action` ("Today's small move"), `eveningThought` and `gratitude` (shown in the Evening Reflection card). To edit or replace content, change those entries only; the rendering doesn't need to change.
- **Date:** `getTodaysPorchDay()` maps the device's local calendar date to Day 1–365, so the same day shows all day and across reloads. In leap years Feb 29 reuses Day 59. The page heading is today's date with "Day N of 365".
- **Reading is open to everyone.** Signed out, the reflection, question, small move, recent days and the 1–365 browser all work. Private writing and saving invite sign-in, and nothing is stored on the device.
- **Signed in, private to the account:**
  - **Reflections:** a Morning Reflection ("What do I want to carry into today?") and an Evening Reflection ("What did today teach me?"), each up to 500 characters, saved separately and editable for today and the previous 7 days.
  - **Save this day:** a heart toggle with "Saved ✓" text and `aria-pressed`. Saved days are listed under "Your saved days". There are no counts and no notifications.
- **Recent Daily Porch:** the previous 7 dates, each opening that date's content and, for its owner, that date's private reflections. Prev/Next and "jump to day" browse all 365 days. A browsed day outside the last week shows no reflection fields.
- **Home:** the "From the porch" Daily Porch card shows today's title with "Read today’s reflection →".
- **My Recovery** stays separate: Daily Porch is for something to carry through the day, and My Recovery tracks how you're doing. The page links to it. There's no mood, cravings or goal here, and no AI, interpretation or scoring.

The backend is `supabase/migrations/phase11b_daily_porch_v1.sql` (applied; see `supabase/README.md`).

## My Recovery Plan

"My Recovery Plan" (`#recoveryplan`) is the member's own private plan, built ahead of time for when things get hard. It's not a clinical, therapy or emergency tool. A short note on the page says so and links 911 and 988, and Rough Day and the Toolbox stay public.

- **Signed out:** an explanation and a Sign in button, with links to Rough Day and the Recovery Toolbox, which need no account.
- **Empty state (signed in, no plan):** "Build your recovery plan", a short reassurance, and two buttons: **Build my plan** and **Open Rough Day**.
- **View mode** is the default once a plan exists, ordered for a stressful moment:
  1. **My next three steps**, as a numbered list.
  2. **People I can reach out to.** If an entry looks like a phone number (7–15 digits), it gets large **Call** (`tel:`) and **Text** (`sms:`) buttons. Otherwise the entry is shown as a note.
  3. **Open Rough Day** and **Edit my plan**.
  4. **What helps me**.
  5. **My warning signs**.
  6. **Why I'm choosing recovery**, highlighted.

  Empty sections are hidden.
- **Edit mode:** a simple form with Save and Cancel. Cancel asks before discarding changes. The fields are:
  - 3 step fields, up to 150 characters each;
  - up to 5 people (name or label, a phone number or note, an optional role), with Add and Remove;
  - three 750-character sections with example helper text. Nothing is pre-filled.

  Blank fields are cleared on save, and clearing everything returns to the empty state.
- **Links:** an "Open My Recovery Plan" button in Rough Day's "Reach out" card, shown signed in only (the crisis box is unchanged). A small link on My Recovery and a "My Recovery Plan" card in the Toolbox's "Right now" group. The plan is also in the mobile menu and the footer. The desktop nav is unchanged.
- **Private only:** no sharing, export, Community, profile or admin exposure, no contact-permission access, and nothing called or sent automatically. There's no AI analysis, scoring or classification.

The backend is `supabase/migrations/phase11c_recovery_plan_v1.sql` (applied; see `supabase/README.md`).

## Recovery Toolbox

The Recovery Toolbox (`#toolbox`, "Toolbox" in the nav) is the same page as before, reorganised rather than duplicated. From the top, it has:

1. **My Toolbox:**
   - **Signed in:** the member's pinned tools, as compact shortcuts in the order they were pinned (re-pinning moves a tool to the end). There's no drag and drop.
   - **Signed out:** a note that everything works without an account, and that signing in lets you pin favourites across devices.
2. **Built-in tools**, in four groups. They're defined in the Toolbox script (`TOOLS`) with stable keys:
   - **Right now:** `rough_day`, `recovery_plan`, `grounding_54321`, `box_breathing`.
   - **Daily:** `daily_porch`, `my_recovery`, `check_in`, `recovery_counter` (scrolls to the counter on this page).
   - **Connection:** `community`, `support_people`.
   - **Reset:** `walk`, `water`, `music`, `prayer`, `journal`.
3. **Guides and resources:** the existing 12 searchable guides (`CONFIG.toolboxResources`), unchanged.
4. **The Recovery Counter**, unchanged and shared with Home.

How the tools behave:

- **Pin / Unpin:** a "☆ Pin" / "★ Pinned" button (`aria-pressed` plus a full label) on every tool, shown to signed-in members only. Pins are private, with no counts and no notifications. Only built-in keys are stored, never URLs or markup.
- **5-4-3-2-1 grounding:** Start, then Back/Next step by step (see, feel, hear, smell, taste), then Done and Start again. There's no timer, focus stays on the controls, and the steps are announced in a polite live region. Nothing is stored or sent.
- **Box breathing:** Start/Stop with a 4-4-4-4 text count (breathe in, hold, breathe out, hold) and a small optional box. Phase changes are announced politely, and the per-second count is hidden from screen readers. Reduced motion turns the box transition off. It stops when you leave the page, and nothing is stored.
- **Quick resets** (walk, water, music, prayer): a short prompt with an "I'll do this" toggle that isn't stored. Music also links to Music from the Porch.
- **Write for five minutes** links to the existing private Daily Porch reflection and My Recovery log, with no new journal storage.
- **People I can reach out to** reads the member's own My Recovery Plan (`get_my_recovery_plan`) and shows the same Call (`tel:`) / Text (`sms:`) buttons, reusing the plan's phone-number check. With no contacts it says "Add support people to My Recovery Plan." Signed out, it invites sign-in.
- **Private tools** (My Recovery, My Recovery Plan, People) carry a "Free account" tag when signed out, and open their own sign-in screens.

Rough Day keeps its own page and crisis resources; the Toolbox links to it. There's no AI, diagnosis, scoring or gamification.

The backend is `supabase/migrations/phase11d_toolbox_pins_v1.sql` (applied; see `supabase/README.md`).

## Meetings & Support

"Meetings & Support" (`#meetings`) isn't tied to any program. It's in the mobile menu, the footer, the Toolbox's Connection group (`meetings_support`, pinnable) and a small link on My Recovery. The desktop nav is unchanged.

- **Find Support (everyone):** meeting finders and recovery resources, rendered from the "Finding Meetings" guide's own `external` list, so the guide and this page share one source. The list is AA, NA, SMART Recovery, Celebrate Recovery (added this phase after confirming the official site), FindTreatment.gov and USARA. Links are https only, open in a new tab with `rel="noopener noreferrer"`, and are labelled "(opens in a new tab)". The page also links the full guide and 988/911.
- **Signed out:** the explanation, a Sign in button, and Find Support. Rough Day and the Toolbox stay public.
- **Signed in: "My Support This Week"** (Monday–Sunday, local), with a "Private to your account" indicator and helper text.
  - **This week:** grouped as Today, Later this week, Earlier this week (only if something isn't marked yet), and Completed.
  - **Navigation:** Prev/Next week (up to 8 weeks either way) and "Back to this week".
  - **Each card shows:** name, type (and "Weekly"), day and time, and the location/link/note.
  - **Neutral states:** Today, Upcoming, Not marked, or ✓ Done. There's never "missed" or "failed", and no streaks or points.
  - **Actions:** **I went / Done** (a toggle with `aria-pressed`; for today and past days only), **Open link**, **Edit** and **Remove**.
  - **Open link** appears only when the note contains a plain `http(s)` URL; `javascript:` and `data:` text stays as text.
- **Add support form:**
  - Type: a preset (AA, NA, SMART, Celebrate Recovery, peer group, therapy, church/recovery group, call sponsor, meet with peer) or "Other…" with free text.
  - Name (required, up to 120 characters), Day (required), Time (optional), Location/link/note (up to 300), and **Repeats weekly**.
  - Only weekly recurrence is supported, on the chosen day's weekday from that date on.
- **Completion is per occurrence date.** Marking this week never marks another week, and past weeks can be marked from the week view.
- **Remove:**
  - A one-time item is hidden.
  - A weekly item stops from today; if today's occurrence is already marked done, it stops from tomorrow so today stays in Completed. Earlier weeks still show it.
  - Every check-off record is kept.
- **Editing:** editing a weekly item's day moves all its occurrences, including past weeks. Check-offs stay stored by their original date, so a check-off on the old weekday no longer shows in the week view. This is a known v1 trade-off.
- **People I can reach out to:** read from My Recovery Plan with the same Call/Text buttons, and not copied. Kept separate from the plan itself, which answers "what do I do when things get hard?".

The backend is `supabase/migrations/phase11e_meetings_support_v1.sql` (applied; see `supabase/README.md`).

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
