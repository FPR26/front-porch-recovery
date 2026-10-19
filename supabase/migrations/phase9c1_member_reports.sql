-- Phase 9C-1: member reports in the existing admin-only reports queue.
-- Apply BEFORE publishing the frontend/admin changes in this phase.
-- No member suspensions, notifications, blocks, or mutes are created.
begin;

alter table public.community_reports
  add column member_public_id uuid references public.profiles(public_id) on delete cascade;

alter table public.community_reports
  drop constraint community_reports_exactly_one_target_check,
  add constraint community_reports_exactly_one_target_check
    check (num_nonnulls(post_id, comment_id, member_public_id) = 1);

create unique index community_reports_one_open_member_per_reporter
  on public.community_reports(reporter_user_id, member_public_id)
  where status = 'open' and member_public_id is not null;
create index community_reports_member_public_id_idx
  on public.community_reports(member_public_id) where member_public_id is not null;

-- Return only the report receipt, never another member's auth user id.
create function public.report_member(
  p_target_public_id uuid,
  p_reason text,
  p_details text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  target_user_id uuid;
  report_id uuid;
begin
  if caller_id is null then
    raise exception 'Sign in required to report a member.' using errcode = '42501';
  end if;
  if p_target_public_id is null then
    raise exception 'Member not found.' using errcode = 'P0002';
  end if;
  if p_reason is null or p_reason not in
    ('harassment', 'hate_or_abuse', 'dangerous_content', 'spam', 'privacy', 'other') then
    raise exception 'Choose a valid report reason.' using errcode = '22023';
  end if;
  if p_details is not null and char_length(p_details) > 500 then
    raise exception 'Report details must be 500 characters or fewer.' using errcode = '22023';
  end if;
  select id into target_user_id from public.profiles where public_id = p_target_public_id;
  if target_user_id is null then
    raise exception 'Member not found.' using errcode = 'P0002';
  end if;
  if target_user_id = caller_id then
    raise exception 'You cannot report yourself.' using errcode = '22023';
  end if;

  begin
    insert into public.community_reports(reporter_user_id, member_public_id, reason, details)
    values (caller_id, p_target_public_id, p_reason, nullif(btrim(p_details), ''))
    returning id into report_id;
  exception when unique_violation then
    raise exception 'You already have an open report for this member.' using errcode = '23505';
  end;
  return report_id;
end;
$$;

revoke all on function public.report_member(uuid, text, text) from public, anon;
grant execute on function public.report_member(uuid, text, text) to authenticated;

-- Existing table RLS, admin SELECT policy, and table grants are unchanged.
-- moderate_community_report() already supports resolve/dismiss for this row type.
commit;
