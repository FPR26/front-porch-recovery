-- Sandbox membership state. No recovery content or payment details are stored.
begin;
create table public.membership_billing (
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
alter table public.membership_billing enable row level security;
revoke all on public.membership_billing from public, anon, authenticated;
grant select, insert, update on public.membership_billing to service_role;

create function public.claim_membership_billing(p_user_id uuid, p_token uuid)
returns boolean language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  insert into public.membership_billing(user_id) values(p_user_id) on conflict do nothing;
  update public.membership_billing set lock_token=p_token, lock_until=now()+interval '90 seconds'
  where user_id=p_user_id and (lock_until is null or lock_until < now());
  return found;
end;
$$;
create function public.save_membership_snapshot(
  p_user_id uuid, p_token uuid, p_subscription_id text, p_status text,
  p_access_until timestamptz, p_cancel_at_period_end boolean
) returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  update public.membership_billing set subscription_id=p_subscription_id,
    status=p_status, access_until=p_access_until, cancel_at_period_end=p_cancel_at_period_end,
    updated_at=now()
  where user_id=p_user_id and lock_token=p_token and lock_until>now();
  if not found then raise exception 'Billing lock expired.'; end if;
end;
$$;
revoke all on function public.claim_membership_billing(uuid,uuid) from public, anon, authenticated;
revoke all on function public.save_membership_snapshot(uuid,uuid,text,text,timestamptz,boolean) from public, anon, authenticated;
grant execute on function public.claim_membership_billing(uuid,uuid) to service_role;
grant execute on function public.save_membership_snapshot(uuid,uuid,text,text,timestamptz,boolean) to service_role;

create function public.get_my_supporter_membership()
returns table(sandbox boolean, has_access boolean, status text, access_until timestamptz, cancel_at_period_end boolean)
language plpgsql stable security definer set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'Sign in required.' using errcode='42501'; end if;
  return query select true,
    coalesce(b.status='active' and b.access_until>now(),false),
    coalesce(b.status,'none'), b.access_until, coalesce(b.cancel_at_period_end,false)
  from (select auth.uid() as id) u left join public.membership_billing b on b.user_id=u.id;
end;
$$;
revoke all on function public.get_my_supporter_membership() from public, anon, authenticated;
grant execute on function public.get_my_supporter_membership() to authenticated;
commit;
