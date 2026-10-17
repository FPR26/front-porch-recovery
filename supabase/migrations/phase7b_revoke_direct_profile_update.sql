-- ============================================================
-- Phase 7B cleanup: revoke the transitional direct profile UPDATE
-- ============================================================
-- Since Phase 0, signed-in members could UPDATE their own
-- profiles.display_name and profiles.notification_prefs directly
-- (column grants + the profiles_update_own RLS policy). Phase 7A kept
-- that path on purpose while Phase 7B moved profile editing to the
-- SECURITY DEFINER RPCs (get_my_profile, update_my_profile,
-- set_my_avatar, clear_my_avatar). 7B is live and verified, so the
-- direct path is removed here.
--
-- Checked before revoking: nothing writes profiles directly — no
-- frontend file, Edge Function, or database function writes
-- notification_prefs (every row is '{}'), and the only profile
-- writers are the four RPCs above plus admin-only
-- moderate_member_profile(), all SECURITY DEFINER, so none of them
-- depend on the member's own UPDATE privilege.
--
-- Unchanged: authenticated keeps SELECT (RLS still limits it to the
-- member's own row, or every row for an admin); anon has no access;
-- the profiles_update_own policy is left in place and simply has no
-- effect without an UPDATE privilege; no profile data is touched.
-- ============================================================

revoke update (display_name, notification_prefs) on public.profiles from authenticated;

-- Belt and braces: no table-level UPDATE for members either (none is
-- granted today; this also clears any column-level UPDATE left over).
revoke update on public.profiles from authenticated;
