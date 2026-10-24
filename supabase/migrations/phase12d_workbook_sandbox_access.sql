-- Workbook test access from server-verified sandbox billing only.
-- Does not enable live checkout or production paid entitlement.
begin;
create function public.supporter_workbook_entitlement()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp
as $$
declare caller uuid:=auth.uid(); grant_end timestamptz; test_end timestamptz; scheduled boolean;
begin
  if caller is null then raise exception 'Sign in required.' using errcode='42501';end if;
  select access_until into grant_end from public.supporter_workbook_access
    where user_id=caller and revoked_at is null and access_until>now();
  select access_until,cancel_at_period_end into test_end,scheduled from public.membership_billing
    where user_id=caller and status='active' and access_until>now() and subscription_id is not null;
  -- Prefer an independent no-charge grant; ending billing cannot revoke that grant.
  if grant_end is not null then return jsonb_build_object('can_write',true,'access_until',grant_end,'access_source','no_charge','sandbox',false,'cancellation_scheduled',false);end if;
  if test_end is not null then return jsonb_build_object('can_write',true,'access_until',test_end,'access_source','sandbox','sandbox',true,'cancellation_scheduled',coalesce(scheduled,false));end if;
  if coalesce(public.is_admin(),false) then return jsonb_build_object('can_write',true,'access_until',null,'access_source','admin','sandbox',false,'cancellation_scheduled',false);end if;
  return jsonb_build_object('can_write',false,'access_until',null,'access_source','none','sandbox',false,'cancellation_scheduled',false);
end;
$$;
revoke all on function public.supporter_workbook_entitlement() from public,anon,authenticated;

create or replace function public.get_my_supporter_workbook()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp
as $$
declare caller uuid:=auth.uid();
begin
  if caller is null then raise exception 'Sign in required.' using errcode='42501';end if;
  return public.supporter_workbook_entitlement() || jsonb_build_object('entries',
    coalesce((select jsonb_agg(jsonb_build_object('reflection_number',w.reflection_number,
      'answers',w.answers,'completed',w.completed,'version',w.version,'updated_at',w.updated_at)
      order by w.reflection_number) from public.supporter_workbook_answers w where w.user_id=caller),'[]'::jsonb));
end;
$$;

create or replace function public.save_my_supporter_reflection(p_reflection integer,p_answers text[],p_completed boolean,p_version integer)
returns integer language plpgsql security definer set search_path=public,pg_temp
as $$
declare caller uuid:=auth.uid(); next_version integer;
begin
  if caller is null then raise exception 'Sign in required.' using errcode='42501';end if;
  -- Serialize access revocation and billing snapshot changes against this save.
  perform 1 from public.supporter_workbook_access where user_id=caller for update;
  perform 1 from public.membership_billing where user_id=caller for update;
  if not (public.supporter_workbook_entitlement()->>'can_write')::boolean then
    raise exception 'Workbook access is not active. Your saved answers remain available to you.' using errcode='42501';
  end if;
  if p_reflection is null or p_reflection not between 1 and 7 or p_version is null or p_version<0 or p_completed is null
    or p_answers is null or array_ndims(p_answers) is distinct from 1 or array_lower(p_answers,1) is distinct from 1
    or cardinality(p_answers)<>3 or array_position(p_answers,null) is not null
    or exists(select 1 from unnest(p_answers) a where char_length(a)>2000)
    or (p_completed and exists(select 1 from unnest(p_answers) a where btrim(a)='')) then
    raise exception 'Use three answers of up to 2,000 characters. Complete all three before marking this reflection complete.' using errcode='22023';
  end if;
  if p_version=0 then
    insert into public.supporter_workbook_answers(user_id,reflection_number,answers,completed)
      values(caller,p_reflection,p_answers,p_completed) on conflict do nothing returning version into next_version;
  else
    update public.supporter_workbook_answers set answers=p_answers,completed=p_completed,
      version=nextval('public.supporter_workbook_version_seq'),updated_at=now() where user_id=caller and reflection_number=p_reflection and version=p_version
      returning version into next_version;
  end if;
  if next_version is null then raise exception 'This reflection changed in another tab. Reload it before saving.' using errcode='40001';end if;
  return next_version;
end;
$$;


-- CREATE OR REPLACE preserves grants, restated explicitly for review.
revoke all on function public.get_my_supporter_workbook(),public.save_my_supporter_reflection(integer,text[],boolean,integer) from public,anon,authenticated;
grant execute on function public.get_my_supporter_workbook(),public.save_my_supporter_reflection(integer,text[],boolean,integer) to authenticated;
commit;
