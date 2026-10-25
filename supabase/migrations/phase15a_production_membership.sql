-- Production billing foundation. Both launch gates start OFF.
-- This migration does not enable checkout or grant production paid access.
begin;
create table public.membership_live_settings(
 singleton boolean primary key default true check(singleton),
 checkout_enabled boolean not null default false,
 benefits_enabled boolean not null default false,
 updated_at timestamptz not null default now()
);
insert into public.membership_live_settings(singleton) values(true);
alter table public.membership_live_settings enable row level security;
revoke all on public.membership_live_settings from public,anon,authenticated;
grant select,update on public.membership_live_settings to service_role;
create table public.membership_live_billing (
  user_id uuid primary key references auth.users(id) on delete cascade,
  customer_id text unique,
  subscription_id text,
  status text not null default 'none',
  access_until timestamptz,
  cancel_at_period_end boolean not null default false,
  lock_token uuid,
  lock_until timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.membership_live_billing enable row level security;
revoke all on public.membership_live_billing from public, anon, authenticated;
grant select, insert, update on public.membership_live_billing to service_role;

create function public.claim_membership_live_billing(p_user_id uuid, p_token uuid)
returns boolean language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  insert into public.membership_live_billing(user_id) values(p_user_id) on conflict do nothing;
  update public.membership_live_billing set lock_token=p_token, lock_until=now()+interval '90 seconds'
  where user_id=p_user_id and (lock_until is null or lock_until < now());
  return found;
end;
$$;
create function public.save_membership_live_snapshot(
  p_user_id uuid, p_token uuid, p_subscription_id text, p_status text,
  p_access_until timestamptz, p_cancel_at_period_end boolean
) returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  update public.membership_live_billing set subscription_id=p_subscription_id,
    status=p_status, access_until=p_access_until, cancel_at_period_end=p_cancel_at_period_end,
    updated_at=now()
  where user_id=p_user_id and lock_token=p_token and lock_until>now();
  if not found then raise exception 'Billing lock expired.'; end if;
end;
$$;
revoke all on function public.claim_membership_live_billing(uuid,uuid) from public, anon, authenticated;
revoke all on function public.save_membership_live_snapshot(uuid,uuid,text,text,timestamptz,boolean) from public, anon, authenticated;
grant execute on function public.claim_membership_live_billing(uuid,uuid) to service_role;
grant execute on function public.save_membership_live_snapshot(uuid,uuid,text,text,timestamptz,boolean) to service_role;


create function public.get_membership_live_launch_state()
returns jsonb language sql stable security definer set search_path=public,pg_temp
as $$select jsonb_build_object('checkout_enabled',checkout_enabled,'benefits_enabled',benefits_enabled) from public.membership_live_settings where singleton$$;
revoke all on function public.get_membership_live_launch_state() from public,anon,authenticated;
grant execute on function public.get_membership_live_launch_state() to service_role;

create function public.get_my_paid_membership()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp
as $$
begin
 if auth.uid() is null then raise exception 'Sign in required.' using errcode='42501';end if;
 return (select jsonb_build_object('sandbox',false,'has_access',coalesce(settings.benefits_enabled and b.status='active' and b.subscription_id is not null and b.access_until>now(),false),
   'status',coalesce(b.status,'none'),'access_until',b.access_until,'cancel_at_period_end',coalesce(b.cancel_at_period_end,false),'has_customer',b.customer_id is not null)
   from public.membership_live_settings settings left join public.membership_live_billing b on b.user_id=auth.uid() where settings.singleton);
end;
$$;
revoke all on function public.get_my_paid_membership() from public,anon,authenticated;
grant execute on function public.get_my_paid_membership() to authenticated;

create or replace function public.supporter_workbook_entitlement()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp
as $$
declare caller uuid:=auth.uid(); grant_end timestamptz; test_end timestamptz; scheduled boolean; paid_end timestamptz; paid_scheduled boolean;
begin
  if caller is null then raise exception 'Sign in required.' using errcode='42501';end if;
  select access_until into grant_end from public.supporter_workbook_access
    where user_id=caller and revoked_at is null and access_until>now();
  select access_until,cancel_at_period_end into test_end,scheduled from public.membership_billing
    where user_id=caller and status='active' and access_until>now() and subscription_id is not null;
  select b.access_until,b.cancel_at_period_end into paid_end,paid_scheduled
    from public.membership_live_billing b cross join public.membership_live_settings settings
    where settings.singleton and settings.benefits_enabled and b.user_id=caller and b.status='active'
      and b.access_until>now() and b.subscription_id is not null;
  -- Prefer an independent no-charge grant; ending billing cannot revoke that grant.
  if grant_end is not null then return jsonb_build_object('can_write',true,'access_until',grant_end,'access_source','no_charge','sandbox',false,'cancellation_scheduled',false);end if;
  if paid_end is not null then return jsonb_build_object('can_write',true,'access_until',paid_end,'access_source','paid','sandbox',false,'cancellation_scheduled',coalesce(paid_scheduled,false));end if;
  if test_end is not null then return jsonb_build_object('can_write',true,'access_until',test_end,'access_source','sandbox','sandbox',true,'cancellation_scheduled',coalesce(scheduled,false));end if;
  if coalesce(public.is_admin(),false) then return jsonb_build_object('can_write',true,'access_until',null,'access_source','admin','sandbox',false,'cancellation_scheduled',false);end if;
  return jsonb_build_object('can_write',false,'access_until',null,'access_source','none','sandbox',false,'cancellation_scheduled',false);
end;
$$;
revoke all on function public.supporter_workbook_entitlement() from public,anon,authenticated;


create or replace function public.save_my_supporter_reflection(p_reflection integer,p_answers text[],p_completed boolean,p_version integer)
returns integer language plpgsql security definer set search_path=public,pg_temp
as $$
declare caller uuid:=auth.uid(); next_version integer;
begin
  if caller is null then raise exception 'Sign in required.' using errcode='42501';end if;
  -- Serialize access revocation and billing snapshot changes against this save.
  perform 1 from public.supporter_workbook_access where user_id=caller for update;
  perform 1 from public.membership_billing where user_id=caller for update;
  perform 1 from public.membership_live_billing where user_id=caller for update;
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



commit;

-- Deployment verification: both values must remain false in this phase.
select checkout_enabled,benefits_enabled from public.membership_live_settings where singleton;
