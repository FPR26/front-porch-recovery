-- Rollback-only verification after phase10a_community_growth.sql.
-- Temporarily substitutes a threshold count only inside this transaction,
-- and invokes the real trigger on a temporary probe table. Rollback restores
-- the real count function and removes all test events/read receipts.
begin;
create temporary table pg_temp.growth_trigger_probe(id integer);
create trigger growth_probe_after_insert after insert on pg_temp.growth_trigger_probe
  for each row execute function public.record_community_growth_milestones();

do $$
declare
  real_count bigint;
  expected_count bigint;
  threshold integer;
  first_user uuid;
  second_user uuid;
  result_rows integer;
  original_time timestamptz;
begin
  select count(*) into expected_count from public.profiles p join auth.users u on u.id=p.id
    where u.email_confirmed_at is not null;
  real_count := public.get_community_member_count();
  if real_count <> expected_count then raise exception 'FAIL: real account count mismatch'; end if;
  if not has_function_privilege('anon','public.get_community_member_count()','EXECUTE') then
    raise exception 'FAIL: public count missing'; end if;
  if has_function_privilege('anon','public.list_my_community_milestones()','EXECUTE')
    or has_function_privilege('authenticated','public.record_community_growth_milestones()','EXECUTE') then
    raise exception 'FAIL: function grants'; end if;
  if has_table_privilege('authenticated','public.community_growth_reads','SELECT')
    or has_table_privilege('authenticated','public.community_growth_milestones','INSERT') then
    raise exception 'FAIL: direct table access'; end if;
  if not exists(select 1 from pg_trigger where tgname='community_growth_after_profile_insert'
    and tgrelid='public.profiles'::regclass and not tgisinternal) then
    raise exception 'FAIL: profile trigger missing'; end if;
  if not exists(select 1 from pg_trigger where tgname='community_growth_after_email_confirmation'
    and tgrelid='auth.users'::regclass and not tgisinternal) then
    raise exception 'FAIL: confirmation trigger missing'; end if;

  select min(t) into threshold from unnest(array[10,25,50,100,250,500,1000,2500,5000,10000]) t
    where t > real_count;
  if threshold is null then raise exception 'Need a future configured threshold for this test'; end if;
  select u.id into first_user from auth.users u join public.profiles p on p.id=u.id
    where u.email_confirmed_at is not null limit 1;
  select u.id into second_user from auth.users u join public.profiles p on p.id=u.id
    where u.email_confirmed_at is not null and u.id<>first_user limit 1;
  if second_user is null then raise exception 'Need two confirmed profiles for read-isolation test'; end if;

  delete from public.community_growth_milestones where member_count=threshold;
  execute format('create or replace function public.get_community_member_count() returns bigint language sql stable security definer set search_path=public,pg_temp as %L',
    'select ' || threshold::text || '::bigint');
  insert into pg_temp.growth_trigger_probe values(1);
  select reached_at into original_time from public.community_growth_milestones where member_count=threshold and announce;
  if original_time is null then raise exception 'FAIL: trigger did not record threshold'; end if;
  insert into pg_temp.growth_trigger_probe values(2);
  if (select count(*) from public.community_growth_milestones where member_count=threshold) <> 1
    or (select reached_at from public.community_growth_milestones where member_count=threshold) <> original_time then
    raise exception 'FAIL: repeated threshold changed announcement'; end if;

  perform set_config('request.jwt.claim.sub',first_user::text,true);
  execute 'set local role authenticated';
  select count(*) into result_rows from public.list_my_community_milestones() m
    where m.member_count=threshold and m.read_at is null;
  if result_rows<>1 then raise exception 'FAIL: new announcement missing'; end if;
  perform public.mark_community_milestone_read(threshold);
  perform public.mark_community_milestone_read(threshold);
  select count(*) into result_rows from public.list_my_community_milestones() m
    where m.member_count=threshold and m.read_at is not null;
  if result_rows<>1 then raise exception 'FAIL: mark read'; end if;
  begin
    perform public.mark_community_milestone_read(999999);
    raise exception 'FAIL: nonexistent milestone accepted';
  exception when no_data_found then null; end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',second_user::text,true);
  execute 'set local role authenticated';
  select count(*) into result_rows from public.list_my_community_milestones() m
    where m.member_count=threshold and m.read_at is null;
  if result_rows<>1 then raise exception 'FAIL: read state leaked between members'; end if;
  execute 'reset role';
  if (select count(*) from public.community_growth_reads where user_id=first_user and member_count=threshold)<>1 then
    raise exception 'FAIL: duplicate read receipt'; end if;
end;
$$;
rollback;
select public.get_community_member_count() as actual_confirmed_members,
  'PASS — simulation rolled back; real count restored.' as result;
