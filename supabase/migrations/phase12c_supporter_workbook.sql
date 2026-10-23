-- Private supporter workbook + no-charge access grants. No live billing integration.
begin;
create table public.supporter_workbook_access (
  user_id uuid primary key references auth.users(id) on delete cascade,
  access_until timestamptz not null,
  granted_at timestamptz not null default now(),
  granted_by uuid references auth.users(id) on delete set null,
  revoked_at timestamptz,
  revoked_by uuid references auth.users(id) on delete set null
);
create table public.supporter_access_history (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  action text not null check(action in ('grant','revoke')),
  access_until timestamptz,
  occurred_at timestamptz not null default now()
);
create sequence public.supporter_workbook_version_seq as integer;
create table public.supporter_workbook_answers (
  user_id uuid not null references auth.users(id) on delete cascade,
  reflection_number smallint not null check(reflection_number between 1 and 7),
  answers text[] not null,
  completed boolean not null default false,
  version integer not null default nextval('public.supporter_workbook_version_seq'),
  updated_at timestamptz not null default now(),
  primary key(user_id,reflection_number),
  check(array_ndims(answers)=1 and array_lower(answers,1)=1 and cardinality(answers)=3),
  check(array_position(answers,null) is null),
  check(char_length(answers[1])<=2000 and char_length(answers[2])<=2000 and char_length(answers[3])<=2000)
);
alter table public.supporter_workbook_access enable row level security;
alter table public.supporter_access_history enable row level security;
alter table public.supporter_workbook_answers enable row level security;
revoke all on public.supporter_workbook_access,public.supporter_access_history,public.supporter_workbook_answers from public,anon,authenticated;
revoke all on sequence public.supporter_workbook_version_seq,public.supporter_access_history_id_seq from public,anon,authenticated;

create function public.get_my_supporter_workbook()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp
as $$
declare caller uuid:=auth.uid(); until_date timestamptz; allowed boolean;
begin
  if caller is null then raise exception 'Sign in required.' using errcode='42501';end if;
  select a.access_until into until_date from public.supporter_workbook_access a
    where a.user_id=caller and a.revoked_at is null and a.access_until>now();
  allowed:=coalesce(public.is_admin(),false) or until_date is not null;
  return jsonb_build_object('can_write',allowed,'access_until',until_date,'entries',
    coalesce((select jsonb_agg(jsonb_build_object('reflection_number',w.reflection_number,
      'answers',w.answers,'completed',w.completed,'version',w.version,'updated_at',w.updated_at)
      order by w.reflection_number) from public.supporter_workbook_answers w where w.user_id=caller),'[]'::jsonb));
end;
$$;

create function public.save_my_supporter_reflection(p_reflection integer,p_answers text[],p_completed boolean,p_version integer)
returns integer language plpgsql security definer set search_path=public,pg_temp
as $$
declare caller uuid:=auth.uid(); next_version integer;
begin
  if caller is null then raise exception 'Sign in required.' using errcode='42501';end if;
  -- Row lock serializes revocation with writes: once revoked, later saves fail.
  perform 1 from public.supporter_workbook_access where user_id=caller for update;
  if not coalesce(public.is_admin(),false) and not exists(select 1 from public.supporter_workbook_access
    where user_id=caller and revoked_at is null and access_until>now()) then
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

create function public.clear_my_supporter_reflection(p_reflection integer,p_version integer)
returns void language plpgsql security definer set search_path=public,pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'Sign in required.' using errcode='42501';end if;
  if p_reflection is null or p_reflection not between 1 and 7 or p_version is null or p_version<1 then
    raise exception 'Choose a saved reflection.' using errcode='22023';end if;
  delete from public.supporter_workbook_answers where user_id=auth.uid() and reflection_number=p_reflection and version=p_version;
  if not found then raise exception 'This reflection changed in another tab. Reload it before clearing.' using errcode='40001';end if;
end;
$$;

create function public.admin_list_supporter_access(p_search text default '',p_offset integer default 0)
returns table(public_id uuid,display_name text,handle text,access_until timestamptz,revoked_at timestamptz,granted_at timestamptz)
language plpgsql stable security definer set search_path=public,pg_temp
as $$
begin
  if auth.uid() is null or not coalesce(public.is_admin(),false) then raise exception 'Admin required.' using errcode='42501';end if;
  if p_offset is null or p_offset<0 or char_length(coalesce(p_search,''))>80 then raise exception 'Invalid search.' using errcode='22023';end if;
  return query select p.public_id,p.display_name,p.handle,a.access_until,a.revoked_at,a.granted_at
  from public.profiles p join auth.users u on u.id=p.id and u.email_confirmed_at is not null
  left join public.supporter_workbook_access a on a.user_id=p.id
  where coalesce(p_search,'')='' or position(lower(p_search) in lower(coalesce(p.display_name,'')||' '||coalesce(p.handle,'')))>0
  order by p.created_at desc,p.public_id limit 51 offset p_offset;
end;
$$;

create function public.admin_set_supporter_access(p_public_id uuid,p_days integer)
returns void language plpgsql security definer set search_path=public,pg_temp
as $$
declare target uuid; until_date timestamptz;
begin
  if auth.uid() is null or not coalesce(public.is_admin(),false) then raise exception 'Admin required.' using errcode='42501';end if;
  if p_days is null or p_days not in (0,30,90,365) then raise exception 'Choose 30, 90 or 365 days, or revoke.' using errcode='22023';end if;
  select p.id into target from public.profiles p join auth.users u on u.id=p.id and u.email_confirmed_at is not null
    where p.public_id=p_public_id for update of p;
  if target is null then raise exception 'Confirmed member not found.' using errcode='P0002';end if;
  if p_days=0 then
    update public.supporter_workbook_access set revoked_at=now(),revoked_by=auth.uid()
      where user_id=target and revoked_at is null returning access_until into until_date;
    if not found then return;end if;
  else
    until_date:=now()+make_interval(days=>p_days);
    insert into public.supporter_workbook_access(user_id,access_until,granted_by)
      values(target,until_date,auth.uid()) on conflict(user_id) do update
      set access_until=case when supporter_workbook_access.revoked_at is null then greatest(supporter_workbook_access.access_until,excluded.access_until) else excluded.access_until end,
        granted_at=now(),granted_by=auth.uid(),revoked_at=null,revoked_by=null
      returning supporter_workbook_access.access_until into until_date;
  end if;
  insert into public.supporter_access_history(user_id,actor_id,action,access_until)
    values(target,auth.uid(),case when p_days=0 then 'revoke' else 'grant' end,until_date);
end;
$$;

create function public.admin_supporter_access_history(p_public_id uuid)
returns table(action text,access_until timestamptz,occurred_at timestamptz,actor_name text)
language plpgsql stable security definer set search_path=public,pg_temp
as $$
begin
  if auth.uid() is null or not coalesce(public.is_admin(),false) then raise exception 'Admin required.' using errcode='42501';end if;
  return query select h.action,h.access_until,h.occurred_at,coalesce(actor.display_name,'Former administrator')
    from public.supporter_access_history h join public.profiles target on target.id=h.user_id
    left join public.profiles actor on actor.id=h.actor_id where target.public_id=p_public_id
    order by h.occurred_at desc,h.id desc limit 20;
end;
$$;
revoke all on function public.get_my_supporter_workbook(),public.save_my_supporter_reflection(integer,text[],boolean,integer),public.clear_my_supporter_reflection(integer,integer),public.admin_list_supporter_access(text,integer),public.admin_set_supporter_access(uuid,integer),public.admin_supporter_access_history(uuid) from public,anon,authenticated;
grant execute on function public.get_my_supporter_workbook(),public.save_my_supporter_reflection(integer,text[],boolean,integer),public.clear_my_supporter_reflection(integer,integer),public.admin_list_supporter_access(text,integer),public.admin_set_supporter_access(uuid,integer),public.admin_supporter_access_history(uuid) to authenticated;
commit;
