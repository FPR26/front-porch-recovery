-- Community growth: confirmed member-account count and durable milestone announcements.
-- Apply and verify before publishing the associated frontend.
begin;

create table public.community_growth_milestones (
  member_count integer primary key check (member_count in (10,25,50,100,250,500,1000,2500,5000,10000)),
  reached_at timestamptz not null default clock_timestamp(),
  announce boolean not null default true
);
create table public.community_growth_reads (
  user_id uuid not null references auth.users(id) on delete cascade,
  member_count integer not null references public.community_growth_milestones(member_count) on delete cascade,
  read_at timestamptz not null default now(),
  primary key(user_id, member_count)
);
alter table public.community_growth_milestones enable row level security;
alter table public.community_growth_reads enable row level security;
revoke all on public.community_growth_milestones, public.community_growth_reads from public, anon, authenticated;

create function public.get_community_member_count()
returns bigint language sql stable security definer set search_path = public, pg_temp
as $$
  select count(*) from public.profiles p join auth.users u on u.id = p.id
  where u.email_confirmed_at is not null;
$$;
revoke all on function public.get_community_member_count() from public, anon, authenticated;
grant execute on function public.get_community_member_count() to anon, authenticated;

-- Internal trigger only. The lock serializes concurrent milestone checks;
-- the primary key remains the final guarantee against repeat announcements.
create function public.record_community_growth_milestones()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
declare current_count bigint;
begin
  perform pg_advisory_xact_lock(947310, 1);
  select public.get_community_member_count() into current_count;
  insert into public.community_growth_milestones(member_count)
    select threshold from unnest(array[10,25,50,100,250,500,1000,2500,5000,10000]) as threshold
    where threshold <= current_count
    on conflict (member_count) do nothing;
  return new;
end;
$$;
revoke all on function public.record_community_growth_milestones() from public, anon, authenticated;

create trigger community_growth_after_profile_insert
  after insert on public.profiles for each row
  execute function public.record_community_growth_milestones();
create trigger community_growth_after_email_confirmation
  after update of email_confirmed_at on auth.users for each row
  when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
  execute function public.record_community_growth_milestones();

-- Do not invent historic celebration dates or notify members of old thresholds.
select pg_advisory_xact_lock(947310, 1);
insert into public.community_growth_milestones(member_count, announce)
  select threshold, false from unnest(array[10,25,50,100,250,500,1000,2500,5000,10000]) as threshold
  where threshold <= public.get_community_member_count()
  on conflict (member_count) do nothing;

create function public.list_my_community_milestones()
returns table(member_count integer, reached_at timestamptz, read_at timestamptz)
language sql stable security definer set search_path = public, pg_temp
as $$
  select m.member_count, m.reached_at, r.read_at
  from public.community_growth_milestones m
  join auth.users u on u.id = auth.uid()
  join public.profiles p on p.id = u.id
  left join public.community_growth_reads r on r.member_count = m.member_count and r.user_id = u.id
  where m.announce and u.email_confirmed_at is not null
    and u.email_confirmed_at <= m.reached_at
  order by m.member_count desc;
$$;
revoke all on function public.list_my_community_milestones() from public, anon, authenticated;
grant execute on function public.list_my_community_milestones() to authenticated;

create function public.mark_community_milestone_read(p_member_count integer)
returns boolean language plpgsql security definer set search_path = public, pg_temp
as $$
declare caller uuid := auth.uid();
begin
  if caller is null then raise exception 'Sign in required.' using errcode = '42501'; end if;
  if not exists (
    select 1 from public.community_growth_milestones m
    join auth.users u on u.id = caller join public.profiles p on p.id = caller
    where m.member_count = p_member_count and m.announce
      and u.email_confirmed_at is not null and u.email_confirmed_at <= m.reached_at
  ) then raise exception 'Milestone not available.' using errcode = 'P0002'; end if;
  insert into public.community_growth_reads(user_id, member_count) values(caller, p_member_count)
    on conflict(user_id, member_count) do nothing;
  return true;
end;
$$;
revoke all on function public.mark_community_milestone_read(integer) from public, anon, authenticated;
grant execute on function public.mark_community_milestone_read(integer) to authenticated;
commit;
