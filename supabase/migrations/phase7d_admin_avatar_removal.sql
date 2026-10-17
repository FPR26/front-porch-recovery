-- ============================================================
-- Phase 7D: let admins remove a moderated avatar file
-- ============================================================
-- moderate_member_profile(p_public_id, 'clear_avatar') (Phase 7A) only
-- clears profiles.avatar_path. The image file itself stays in the
-- public avatars bucket, still reachable at its public URL, and the
-- Phase 7A storage policies let only the owning member delete it.
--
-- These two policies let an authenticated admin (is_admin()) see and
-- delete objects in the avatars bucket, so admin.html can remove the
-- file through the Storage API right after clearing it from the
-- profile (the Storage API's delete needs both SELECT and DELETE).
-- Nothing else changes: members keep their own-folder policies, no one
-- else gains access, and no profile data is touched.
-- ============================================================

create policy "avatars_admin_select"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'avatars' and public.is_admin());

create policy "avatars_admin_delete"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'avatars' and public.is_admin());
