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
- **Recovery History v1 (Phase 11K)** — complete: a private year-by-year and month-by-month record built from existing data (see below).
- **Resources v2** — complete: a searchable national recovery-resource directory built from one shared catalog (see below).
- **Journal v1 (Phase 11J)** — complete: a private freeform journal with search and tags (see below).
- **Weekly Review v1 (Phase 11I)** — complete: a factual Monday–Sunday summary plus a private weekly reflection (see below).
- **Milestones & Wins v1 (Phase 11H)** — complete: calculated recovery milestones plus private personal wins in one timeline (see below).
- **Progress v1 (Phase 11G)** — complete: a private 7/30-day history view computed from existing data, with no new storage (see below).
- **Today v1 (Phase 11F)** — complete: a signed-in daily dashboard over existing data, with no new storage (see below).
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

## Today

"Today" (`#today`) is the signed-in member's daily dashboard: "What does my recovery look like today?" Home stays the public welcome page. Signed-in members get a small "Your Today / Open Today" card under Home's onboarding card; signed-out visitors don't see it.

- **Navigation:** Today sits right after Home in the desktop nav, mobile menu and footer. To keep the 12-item desktop header from breaking, **About** left the desktop nav. It's still reachable from the mobile menu ("My Story"), the two "Our Story" buttons on Home, and a new "Our Story" link in the footer.
- **Signed out:** "Your recovery, in one place", a Sign in button, and public links to Check-In, Daily Porch and Rough Day. No private calls are made.
- **Signed in:** a local-time greeting ("Good morning/afternoon/evening, <display name>." The name is left out if it's still "New member"), the full local date, and "Private to your account" with helper text. Then, in this order (two columns on wide screens):
  1. **Daily Porch:** today's title, the first sentence, "Saved ✓" if the day is saved, and **Read today's Daily Porch**.
  2. **My Recovery:** "Nothing logged today yet." / Not logged with **Check in to My Recovery**; or the mood, cravings, a win preview and Saved ✓, with **Open My Recovery**. The entry form isn't duplicated.
  3. **My Goal:** the current goal, its target date, and Active or ✓ Completed; or "Set one small recovery goal."
  4. **Support Today:** today's Meetings & Support occurrences (weekly and one-time) by time, showing Planned or Done. **I went / Done** calls the existing `set_my_support_checkin` and updates in place. Empty: "No support items planned today." with **Plan my support**.
  5. **My Toolbox:** up to 4 pinned tools in pin order (from the Toolbox's own tool list), plus **Show all tools →**. Empty: "Pin the tools that help you most."
  6. **My Recovery Plan:** quick access only, **Open my plan** or **Build my recovery plan**. The plan's text is never shown or kept; Today only checks whether a plan exists.
  7. **Having a rough day?** with **Open Rough Day**. Calm styling; Rough Day itself is unchanged.
- **Status, not evaluation:** Saved, Done, Planned, Not logged, Active, Completed. No scores, percentages, colours-as-judgment, AI, points or streaks.
- **Data and requests:**
  - **No new storage and no migration.** One parallel batch of 8 existing RPCs per load: `list_my_recovery_logs`, `get_my_recovery_goal`, `list_my_saved_daily_porch`, `list_my_support_items`, `list_my_support_checkins`, `get_my_recovery_plan`, `list_my_toolbox_pins`, `get_my_profile`.
  - **Caching:** results are reused until something changes. The other features dispatch `fpr:recoverychange` (log/goal), `fpr:dailysavedchange`, `fpr:pinschange`, `fpr:planchange` and `fpr:supportchange`, and `fpr:profilechange` already existed. The cache is also dropped when the local date changes (checked on each Today visit and when the tab becomes visible) or when the account changes.
  - **No timers or polling.** Signing out or switching accounts clears everything.

## Recovery History

"Recovery History" (`#history`) asks: "What has my recovery looked like over time?" It's private, signed-in only, and stores nothing new. It presents the member's own record: no AI, scores, grades, comparisons or judgment.

- **Navigation:** the mobile menu and footer, plus links from Progress, My Recovery and Milestones & Wins. It's not in the desktop nav.
- **Signed out:** "Your recovery story, over time", a Sign in button, and Daily Porch / Check-In links. No private calls are made.
- **Year selector:** Prev/Next back to 2000, never past the current year.
- **Year at a glance:** days logged in My Recovery, journal entries, support activities completed, Daily Porch reflections, Weekly Reviews saved, personal wins, and recovery milestones reached (calculated from the profile recovery date with the shared milestone helper).
- **Month by month:** January–December cards with concise counts and any "✓ X milestone". An empty month says "No recovery activity logged." In the current year, the current month is marked "So far this month" and later months are "Upcoming" and not clickable.
- **Month detail** (tap a month; it reuses the year's data, with no extra request):
  - **Summary:** days logged, average mood and cravings ("—" when there's nothing), support completed, journal entries, morning and evening reflections, saved Daily Porch days, Weekly Reviews, wins and milestones.
  - **Milestones & wins:** win titles only (never notes), opening Milestones & Wins.
  - **My Recovery calendar:** Logged / Not logged, through today only. Logged days from the last 30 days open My Recovery on that date; older ones aren't clickable, because My Recovery only edits its recent window.
  - **Support completed:** by stored category, alphabetical.
  - **Daily Porch:** counts only.
  - **Journal:** a count only, with Open Journal.
  - **Weekly Reviews:** week ranges only, which open that review if it's within Weekly Review's 12-week window. A review counts in the month its week starts.
  - **"This month" timeline:** milestones, wins, "Support done", "Weekly Review saved", "Journal entry written" and "Logged in My Recovery", in date order.
- **Empty year:** "Nothing logged here yet" with Open My Recovery, Open Journal and Open Daily Porch.
- **Data:**
  - **Per year:** one call to the new read-only `list_my_history_events(p_from, p_to)`, which returns dated metadata only and never journal, review, reflection, plan or note text.
  - **Once per session:** `list_my_saved_daily_porch` and `get_my_profile` (for the recovery date).
  - **Caching:** month detail and revisited years reuse the cache. It's refreshed by `fpr:recoverychange`, `fpr:supportchange`, `fpr:dailyreflectionchange`, `fpr:journalchange` (new; fired by Journal save and remove), `fpr:weeklyreviewchange`, `fpr:winschange`, `fpr:dailysavedchange`, `fpr:profilechange`, a date change or an account change. There's no polling.

The backend is `supabase/migrations/phase11k_recovery_history_v1.sql` (applied; see `supabase/README.md`).

## Resources (national directory)

"Resources" (`#resources`) answers "What kind of help do I need, and where can I find it?". It's public, needs no account, uses no location, and stores nothing. It's in the mobile menu and footer, linked from the Toolbox's "Guides and resources", and from Meetings & Support's Find Support ("More meeting finders in Resources →" opens the Meetings category, plus "Browse all resources →"). The desktop nav is unchanged, and Rough Day's crisis resources are unchanged.

- **Page order:**
  1. **Need immediate help?** — 911 and 988 (call or text), and **Rough Day →**.
  2. **What do you need help with?** — ten need buttons, e.g. Find a meeting, Find treatment, Housing.
  3. **Search resources** — name, organization, description, category and tags; case-insensitive, partial words, every word must match.
  4. **Category chips** — All plus 10 categories, with `aria-pressed` and a ✓; combines with search.
  5. **Results** — grouped by category when showing All, otherwise emergency services first.
- **When nothing matches:** "No resources found" with **Show all resources**.
- **Cards:** name, organization, labels (audience such as "For family & loved ones" or "Veterans", and the scope, e.g. "Utah only"), a short plain description, availability, and only the actions that exist:
  - **Call** (`tel:`) and **Text** (`sms:`), digits only;
  - **Website** (http/https only), opening in a new tab with `rel="noopener noreferrer"` and an accessible "opens the organization's site in a new tab" label.

  Anything else is never rendered as a link.
- **How to use this directory:** a short note that FPR doesn't operate or endorse these services and that availability can change.

### Maintaining the catalog

- **One catalog:** `CONFIG.resourceCatalog` in `index.html` is the only list of outside resources. `CONFIG.resourceCategories` lists the categories: `crisis`, `meetings`, `treatment`, `housing`, `food`, `employment`, `legal`, `family`, `veterans`, `peer`.
  - **Toolbox guides** reference entries with `{"ref": "<key>", "note": "guide-specific context"}` in their `external` lists, through `CONFIG.sharedResources`, which is generated from the catalog.
  - **Meetings & Support's Find Support** uses the Finding Meetings guide's refs.

  Change a link once, in the catalog, and every place updates.
- **To add a resource**, add an object to `resourceCatalog`:

  ```js
  { key: 'unique_key', name: 'Name people know', organization: 'Who runs it', category: 'housing', also: ['food'],
    description: 'One or two plain sentences in our own words.', website_url: 'https://…', button_label: 'Visit …',
    phone: '18005551234', phone_label: 'Call 1-800-555-1234', text_number: '12345', text_label: 'Text HELLO to 12345',
    availability: '24/7', audience: 'family', scope: 'national', tags: ['search', 'words'], featured: false, emergency: false }
  ```

  - **Required fields:** `key`, `name`, `description`, `category`, `scope`, and normally `website_url`. Everything else is optional.
  - **Values:** `phone` and `text_number` are digits only. `audience` is one of `recovery`, `family`, `veterans`, `reentry`, `anyone` or `professionals`.
  - **Emergency entries:** `emergency: true` marks a crisis service, which is listed first in filtered views.
- **Scopes (ready for state and local listings):**
  - `scope: 'national'` is the default for v2.
  - `scope: 'state'` needs `state` (e.g. `'UT'`) and shows a "Utah only" label.
  - `scope: 'local'` needs `state` plus `county` and/or `city`, and shows that as its label.

  There's no location detection or ZIP logic yet. A later version can add a state/local filter without replacing the national catalog.
- **Verification rules:** every new URL and number must be checked on the organization's own site before it's added. Check that the page loads over HTTPS, that it's the organization it claims to be, that there's no redirect to a commercial lead service, and that the phone and text numbers appear on the official page.
  - **Use:** government, official program and established nonprofit sources.
  - **Don't use:** lead-generation, affiliate or paid-placement treatment directories.
  - **Writing:** paraphrase descriptions rather than copying them.
- **Current catalog (verified 2026-10-19):** 35 entries, 34 national plus USARA (Utah).
  - **Mental health & crisis:** 988 Lifeline, Crisis Text Line, NAMI HelpLine, National Domestic Violence Hotline, Poison Help, SAMHSA Find Support.
  - **Meetings:** AA, NA, SMART Recovery, Celebrate Recovery, Recovery Dharma, LifeRing, Women for Sobriety.
  - **Peer services:** Faces & Voices of Recovery, USARA.
  - **Treatment:** FindTreatment.gov, SAMHSA National Helpline.
  - **Housing:** HUD Find Shelter, 211.
  - **Food:** USDA National Hunger Hotline, Feeding America food bank finder, USA.gov Benefits.
  - **Employment:** American Job Center Finder, CareerOneStop for justice-impacted people.
  - **Legal & reentry:** LawHelp.org, LSC Find Legal Aid, National Reentry Resource Center.
  - **Family:** Al-Anon, Nar-Anon, SMART Recovery Family & Friends, Partnership to End Addiction.
  - **Veterans:** Veterans Crisis Line, VA substance use treatment, Find VA locations, VA homeless programs.
- **Not in the catalog:** the guides' existing Psychology Today Therapist Finder and In The Rooms links are commercial directories and platforms, so they stay as plain guide links.
- **No database:** this is public reference content, so there's no table or migration.

## Journal

"Journal" (`#journal`) is the member's private freeform writing space: "What do I need to get out of my head?" There's no AI, analysis, sharing, export, streaks or nagging.

- **Navigation:** the mobile menu and footer, plus:
  - the Toolbox "Write for five minutes" card, whose primary action **Write in my Journal** opens a new entry (the Daily Porch reflection and My Recovery log options stay);
  - "Write in Journal →" on Today (a link only, with no entry status, to avoid an extra call);
  - "Open Journal" on My Recovery, and "Open Journal →" on Weekly Review.

  It's not in the desktop nav.
- **Signed out:** "A private place to write", a Sign in button, and Daily Porch / Check-In links. There's no local journal storage, and no private calls are made.
- **Empty state:** "This space is yours", your copy, and **Write my first entry**.
- **New and edit entry:**
  - Date (today by default; today or earlier, not before 1900) and an optional title (up to 120).
  - The entry itself (required, up to 5,000, in a large textarea) and optional tags (comma-separated, up to 5, each up to 30; trimmed and de-duplicated ignoring case).
  - Visible counters, "Unsaved changes" / "Saved ✓" in text, and Save / Cancel. There's no autosave.
  - Cancel, Back or opening another entry asks before discarding changes. Leaving the page keeps the draft, and closing the tab warns.
- **Recent entries:** newest first, 20 at a time with **Load more**. Each card shows the date, the title (or "Untitled entry"), a short preview, tags, and "Edited" if it was changed later, with Edit and Remove. Tapping a card opens the entry.
- **Entry view:** the date, title, full body (line breaks preserved, rendered as text), tags, and "Written … · Edited …", with Edit, Remove and ← Back to Journal.
- **Search my journal:** a case-insensitive partial match on title, body and tags, run in the database (at most 50 results). `%` and `_` are matched literally.
- **Tags:** tap a tag to show only those entries (case-insensitive); "All entries" clears the filter.
- **Remove:** asks first. It's a soft remove, and the entry disappears from the list and search immediately. There's no Trash UI yet.
- **Data and requests:** the full body loads only when an entry is opened. There's no polling, and everything is cleared on sign-out or account switch. Journal text never appears in Community, profiles, notifications, Progress, Weekly Review or admin.

The backend is `supabase/migrations/phase11j_journal_v1.sql` (applied; see `supabase/README.md`).

## Weekly Review

"Weekly Review" (`#weekly`) asks: "What happened this week, what mattered, and what do I want to carry into next week?" The numbers come from the member's own activity, and the meaning comes from them: no AI, score, grade, streaks or nagging.

- **Navigation:** the mobile menu and footer; "Weekly Review →" on Today (slightly bolder on Sundays, never a prompt); "Open Weekly Review →" on Progress; "Weekly Review" on My Recovery. It's not in the desktop nav.
- **Weeks:** Monday–Sunday in local time, labelled like "October 19–25, 2026", "September 28 – October 4, 2026" or "December 28, 2026 – January 3, 2027". Prev/Next go back up to 12 weeks, never forward past this week, with "Back to this week".
- **Signed out:** "Your week, in perspective", a Sign in button, and Daily Porch / Check-In links. No private calls are made.
- **This week at a glance**, derived and never stored:
  - days logged, average mood and cravings ("—" when there's nothing);
  - support activities completed;
  - morning reflections and evening reflections;
  - personal wins;
  - any recovery milestone reached that week.

  A week with no activity shows "No recovery activity is logged for this week yet." and the form still works.
- **Moments from this week:** milestones reached, personal wins (title and date), completed support activities (by name), and the current goal if it was completed that week, in date order. Daily Porch reflections, My Recovery notes and plan text are never shown.
- **My reflection:** What went well? / What was hard? / What helped? (up to 750 characters each) and Next week (up to 300), with visible counters, "Saved ✓" / "Unsaved changes" in text, and a link to set or edit the Recovery Goal.
  - One review per week (keyed by its Monday), editable any time within the 12 weeks.
  - A new review needs at least one field filled in. Switching weeks with unsaved changes asks first.
- **Previous Reviews:** saved reviews from the previous 12 weeks, showing the range, Saved ✓ and a short first-line preview. Tapping one opens that week.
- **Data:**
  - **Per selected week:** one parallel batch of 4 calls, cached per week: the new bounded `list_my_recovery_logs_range` and `list_my_daily_reflection_days` (presence flags only, never text), plus `list_my_support_items` / `list_my_support_checkins`.
  - **Once per session:** `list_my_weekly_reviews`, `list_my_wins`, `get_my_recovery_goal` and `get_my_profile` (the recovery date, for milestones).
  - **Refresh:** on `fpr:recoverychange`, `fpr:supportchange`, `fpr:dailyreflectionchange`, the new `fpr:winschange` (fired by Milestones & Wins), `fpr:profilechange`, a date change or an account change. Saving fires `fpr:weeklyreviewchange`. There's no polling.

The backend is `supabase/migrations/phase11i_weekly_review_v1.sql` (applied; see `supabase/README.md`).

## Milestones & Wins

"Milestones & Wins" (`#milestones`) answers "How far have I come, and what do I want to remember?". It's private only: no sharing, badges, points, leaderboards or Community posting.

- **Navigation:** the mobile menu and footer, "View milestones & wins →" on Today (plus a "Milestone today" card only on a milestone day), "Milestones & Wins →" on Progress, and "View Milestones & Wins" on My Recovery. It's not in the desktop nav.
- **Recovery date source:** the **account profile `recovery_date`**, through the existing `get_my_profile` / `update_my_profile`.
  - **Viewing never writes.** Changing an existing date, or who can see it, stays in the Account window ("Change date or who can see it" opens it).
  - **No date on the account:** "Set my recovery date" saves one as **private**. If the account's visibility was members or everyone while it had no date, it's set to private, so a date is never disclosed by this page. Display name and bio are re-read and sent back unchanged.
  - **Device counter date:** if the on-device Recovery Counter has a date, a note says it hasn't been added to the account. "Use this date for my private milestones" asks for confirmation first. Nothing is uploaded automatically, and the device counter itself is never changed.
- **Milestones:** 7, 14, 30, 60 and 90 days, 6 months, 9 months, 1 year, 18 months, 2 years, then every year.
  - **Date math:** they're calculated, never stored, with the Recovery Counter's calendar-aware `FPRMilestones.milestoneDate`. If the start day doesn't exist in the target month, the milestone rolls to the 1st of the next month. For example, a Feb 29 start's 1 Year is Mar 1 in non-leap years (and Feb 29 in leap years), and an Aug 31 start's 6 Months is Mar 1.
  - **Invalid dates:** future dates are rejected, and very old dates (1900 on) work.
- **Your recovery:** total days, "N years, N months" when it applies, the start date, and who can see that date.
- **Next milestone:** its name, "N days away" and the date, plus the next 3 after it. On a milestone day it says "Today is your X milestone. Every one of those days counted." Nothing is celebrated publicly.
- **Personal wins:** a title (required, up to 120 characters), a date (defaults to today, not in the future) and an optional private note (up to 500). Add, Edit, and Remove (asks first; it's a soft remove).
- **My Recovery Timeline:** reached milestones and wins in one list, newest first, each labelled "Recovery milestone" or "Personal win" in text. Filters: All / Milestones / My wins.
- **Empty state** (no date and no wins): "Your story is still being written", with Add a win and Set my recovery date (plus the device-date option if there is one).
- **Data:** one parallel load (`get_my_profile` + `list_my_wins`). It refreshes on `fpr:profilechange`, a date change, or an account change. Sign-out clears everything.

The backend is `supabase/migrations/phase11h_recovery_wins_v1.sql` (applied; see `supabase/README.md`).

## Progress

"Progress" (`#progress`) answers "How have I been showing up for my recovery lately?" with facts only: no score, interpretation, prediction or judgment.

- **Navigation:** the mobile menu and footer (after My Recovery), "View my progress →" under Today's cards, and "View Progress" in My Recovery's Last 7 days card. It's not in the desktop nav, which is full.
- **Signed out:** "Your progress, over time", a Sign in button, and Check-In / Daily Porch links. No private calls are made.
- **Ranges:** **7 days** or **30 days** (the default). This is a two-button `aria-pressed` group with a ✓ on the selected one, ending today (local).
- **Progress at a glance:** "You logged recovery entries on N of the last 30 days.", plus:
  - days logged;
  - average mood and average cravings (averaged only over days that have that value, shown as "—" when there's none);
  - support activities completed;
  - Daily Porch reflections (morning plus evening).
- **Mood and cravings:** two small CSS bar strips (no chart library). Days without a value are left as gaps and never filled in. The bars are hidden from screen readers, and a "Day-by-day values" table with a caption gives every day's exact value or "Not logged".
- **Logging history:** a Monday-first calendar of the range. Logged days are ✓ buttons that open My Recovery editing that date, using its existing past-entry editing via `FPRMyRecoveryOpenDate`. Other days are "–", labelled "Not logged".
- **Support this period:** completed Meetings & Support check-offs, counted by the category stored on the item. Categories are listed alphabetically, never ranked. Check-offs whose item was later removed (so it has no stored category) count as "Other". Planned-but-not-marked items aren't counted or mentioned.
- **Daily Porch:** counts of morning reflections, evening reflections and saved days (by save date). Reflection text is never shown or kept.
- **Current goal:** the text, target date, and Active or ✓ Completed; or "Set one small recovery goal." Open My Recovery.
- **Empty state** (nothing in the last 30 days): "Your progress will build over time", the explanation, and Open My Recovery / Open Daily Porch. The goal card still shows.
- **Data:**
  - **No new storage and no migration.** One parallel batch of 6 existing RPCs covering 30 days: `list_my_recovery_logs`, `get_my_recovery_goal`, `list_my_support_items`, `list_my_support_checkins`, `list_my_daily_reflections`, `list_my_saved_daily_porch`. The 7-day view reuses it, so switching ranges makes no requests.
  - **Refresh:** cached until `fpr:recoverychange`, `fpr:supportchange`, `fpr:dailysavedchange` or the new `fpr:dailyreflectionchange` (fired by a Daily Porch reflection save), a date change, or an account change. There's no polling.
  - **Sign-out** clears the page, including hidden markup.

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

## Porch Visits v1

Home shows a small aggregate visit count beneath “From the porch.” A visit is one browser-tab/app session, independent of sign-in. The versioned sessionStorage flag `fpr_porch_visit_v1` is saved only after a successful increment. Reloads and internal navigation read the count; account changes never record another visit. A new tab/session may count again (browsers can copy sessionStorage when duplicating tabs). If storage is disabled, an in-memory guard protects the current document only.

Porch Visits is a lightweight aggregate visit counter, not a unique-visitor analytics system. It can be inflated by repeated sessions or direct calls. No visitor identifiers, per-visit timestamps, cookies, fingerprints, location, referrers, or activity records are stored by this feature. Only one key/count row is stored. Offline/failure hides the display; a later Home navigation or reconnect can retry, with no queue or retry loop. A lost response after the database commits can cause a later retry to count again; exact-once delivery across network failures would require additional deduplication data.

Apply `supabase/migrations/phase12a_porch_visits_v1.sql` before deploying the frontend. Both public RPCs are available to anon/authenticated; direct table access is revoked and RLS is enabled. Increment uses one atomic UPDATE, so concurrent calls cannot lose updates. No service-worker changes are needed: Supabase requests already bypass its public-file cache.

## Porch Supporter preview

Optional membership preview at #supporter, reached from Shop → Support FPR. Approved proposed pricing is $3/month or $25/year; no billing, subscription activation, entitlement checks, or access restrictions are implemented. All current tools remain free. Sponsored access and personalization are explicitly planned, not active. Existing Cash App support remains separate.

Includes a seven-part Pull Up a Chair workbook sample (prompts only, no answer collection or storage) and two downloadable sample PNG designs using the official brand mark. Both exports visibly say DESIGN PREVIEW · SAMPLE. Journal navigation uses the existing free page; no changes to journal storage, privacy, auth, admin, notifications, or milestone eligibility. A payment provider and server-verified entitlements/admin sponsorship controls are needed before a membership launch.

## Membership sandbox server

Admin-only Stripe test checkout, portal and signature-verified subscription updates are implemented, default disabled. No live payments or production paid access. Deployment order and pending hosted acceptance checks are in supabase/MEMBERSHIP_SANDBOX_SETUP.md. Server secrets belong only in Supabase Edge Function Secrets.

## Private supporter workbook and no-charge access

Seven private saved reflection sessions and admin grant/extend/revoke controls are prepared. Workbook access is independent of Stripe sandbox billing; paid production access remains disabled. Existing previews and Journal remain free. Apply phase12c_supporter_workbook.sql before publishing. Deployment, privacy and verification details: supabase/SUPPORTER_WORKBOOK.md.
