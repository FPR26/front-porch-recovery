-- ============================================================
-- Phase 6B follow-up: race-safe "one open report per reporter per
-- target" for community_reports.
-- ============================================================
-- RECORDKEEPING ONLY. This change is already live in the Supabase
-- project but was applied outside the migration history (it is not
-- part of the recorded phase6b_comments_replies_reports migration).
-- This file was reconstructed on 2026-10-16 from the live catalog
-- (pg_indexes.indexdef and pg_get_functiondef) so the repository
-- matches the database. Do not re-run it against the live project.
--
-- What it does on top of phase6b_comments_replies_reports.sql:
--   1. Two unique partial indexes, so two concurrent reports from the
--      same member against the same post/comment cannot both be
--      stored while open.
--   2. report_community_content() wraps its insert in a
--      unique_violation handler, turning a lost race into the same
--      friendly "already have an open report" error as the pre-check.
-- Grants are unchanged from the original Phase 6B migration
-- (authenticated only; no anon/public).
-- ============================================================

CREATE UNIQUE INDEX community_reports_one_open_post_per_reporter ON public.community_reports USING btree (reporter_user_id, post_id) WHERE ((status = 'open'::text) AND (post_id IS NOT NULL));

CREATE UNIQUE INDEX community_reports_one_open_comment_per_reporter ON public.community_reports USING btree (reporter_user_id, comment_id) WHERE ((status = 'open'::text) AND (comment_id IS NOT NULL));

CREATE OR REPLACE FUNCTION public.report_community_content(p_reason text, p_post_id uuid DEFAULT NULL::uuid, p_comment_id uuid DEFAULT NULL::uuid, p_details text DEFAULT NULL::text)
 RETURNS community_reports
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  caller_id uuid := auth.uid();
  result_row public.community_reports;
  existing_open_id uuid;
begin
  if caller_id is null then
    raise exception 'Sign in required to report content.' using errcode = '42501';
  end if;

  if (p_post_id is null) = (p_comment_id is null) then
    raise exception 'Exactly one of a post or a comment must be reported.' using errcode = '22023';
  end if;

  if p_reason not in ('harassment', 'hate_or_abuse', 'dangerous_content', 'spam', 'privacy', 'other') then
    raise exception 'Invalid report reason: %', p_reason using errcode = '22023';
  end if;

  if p_details is not null and char_length(p_details) > 500 then
    raise exception 'Report details must be 500 characters or fewer.' using errcode = '22023';
  end if;

  if p_post_id is not null then
    if not exists (select 1 from public.community_posts where id = p_post_id) then
      raise exception 'Post not found.' using errcode = 'P0002';
    end if;
  else
    if not exists (select 1 from public.community_comments where id = p_comment_id) then
      raise exception 'Comment not found.' using errcode = 'P0002';
    end if;
  end if;

  -- Friendly pre-check (keeps the common case fast and the error
  -- path simple), kept even though it cannot fully close the race on
  -- its own: two concurrent calls can both pass this check before
  -- either commits its insert. The unique partial indexes above are
  -- the actual race-safe guarantee; the exception handler below turns
  -- the second call's unique_violation into the same friendly error
  -- rather than a raw constraint-violation message.
  select id into existing_open_id
  from public.community_reports
  where reporter_user_id = caller_id
    and status = 'open'
    and (
      (p_post_id is not null and post_id = p_post_id)
      or (p_comment_id is not null and comment_id = p_comment_id)
    )
  limit 1;

  if existing_open_id is not null then
    raise exception 'You already have an open report for this content.' using errcode = '23505';
  end if;

  begin
    insert into public.community_reports (
      reporter_user_id, post_id, comment_id, reason, details, status
    ) values (
      caller_id, p_post_id, p_comment_id, p_reason,
      case when p_details is null then null else btrim(p_details) end,
      'open'
    )
    returning * into result_row;
  exception
    when unique_violation then
      raise exception 'You already have an open report for this content.' using errcode = '23505';
  end;

  return result_row;
end;
$function$
;

revoke execute on function public.report_community_content from public;
revoke execute on function public.report_community_content from anon;
grant execute on function public.report_community_content to authenticated;
