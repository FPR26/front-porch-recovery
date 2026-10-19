-- Run in the Supabase SQL editor AFTER phase9c1_member_reports.sql.
-- Uses a non-admin reporter and a different existing profile; all inserted reports are rolled back.
begin;

do $$
declare
  caller uuid;
  target uuid;
  caller_public uuid;
  target_public uuid;
  receipt uuid;
  visible_rows integer;
  before_count integer;
begin
  select p.id, p.public_id into caller, caller_public
  from public.profiles p where not exists
    (select 1 from public.admin_users a where a.user_id = p.id) limit 1;
  select p.id, p.public_id into target, target_public
  from public.profiles p where p.id <> caller limit 1;
  if caller is null or target is null then
    raise exception 'Need one non-admin member and one other profile for this rollback test.';
  end if;

  if has_function_privilege('anon', 'public.report_member(uuid,text,text)', 'EXECUTE') then
    raise exception 'FAIL: anonymous execute granted';
  end if;
  if not has_function_privilege('authenticated', 'public.report_member(uuid,text,text)', 'EXECUTE') then
    raise exception 'FAIL: authenticated execute missing';
  end if;
  if has_table_privilege('authenticated', 'public.community_reports', 'INSERT')
    or has_table_privilege('authenticated', 'public.community_reports', 'UPDATE')
    or has_table_privilege('anon', 'public.community_reports', 'SELECT') then
    raise exception 'FAIL: direct report access grants';
  end if;

  -- Clear fixture conflicts only inside this transaction; rollback restores them.
  delete from public.community_reports where reporter_user_id = caller and member_public_id = target_public;
  select count(*) into before_count from public.community_reports;
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform public.report_member(target_public, 'spam', null);
    raise exception 'FAIL: signed-out report accepted';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub', caller::text, true);
  begin
    perform public.report_member(caller_public, 'spam', null);
    raise exception 'FAIL: self report accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.report_member(gen_random_uuid(), 'spam', null);
    raise exception 'FAIL: unknown member accepted';
  exception when no_data_found then null;
  end;
  begin
    perform public.report_member(target_public, null, null);
    raise exception 'FAIL: null reason accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.report_member(target_public, 'invalid', null);
    raise exception 'FAIL: invalid reason accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.report_member(target_public, 'spam', repeat('x',501));
    raise exception 'FAIL: long details accepted';
  exception when invalid_parameter_value then null;
  end;

  execute 'set local role authenticated';
  receipt := public.report_member(target_public, 'harassment', '  Rollback-only member report test  ');
  select count(*) into visible_rows from public.community_reports;
  if visible_rows <> 0 then raise exception 'FAIL: ordinary member can read reports'; end if;
  begin
    perform public.report_member(target_public, 'other', null);
    raise exception 'FAIL: duplicate open report accepted';
  exception when unique_violation then null;
  end;
  begin
    perform public.moderate_community_report(receipt, 'resolve');
    raise exception 'FAIL: ordinary member can moderate';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';

  if not exists(select 1 from public.community_reports where id = receipt
    and reporter_user_id = caller and member_public_id = target_public
    and post_id is null and comment_id is null and status = 'open'
    and details = 'Rollback-only member report test') then
    raise exception 'FAIL: stored receipt mismatch';
  end if;
  if (select count(*) from public.community_reports) <> before_count + 1 then
    raise exception 'FAIL: unexpected report count';
  end if;
  raise notice 'PASS: permissions, signed-out/self/unknown/invalid input guards, authenticated insert, duplicate protection, private RLS, non-admin moderation rejection, stored receipt.';
end;
$$;
select 'PASS — member-report validation and privacy checks passed; test changes are rolled back.' as result;
rollback;
