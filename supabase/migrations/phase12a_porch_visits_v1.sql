-- Porch Visits v1: one aggregate row, no visitor records or identifiers.
begin;
create table public.site_counters (
  key text primary key check (key = 'porch_visits'),
  count bigint not null default 0 check (count >= 0)
);
alter table public.site_counters enable row level security;
revoke all on table public.site_counters from public, anon, authenticated;
insert into public.site_counters (key, count) values ('porch_visits', 0);

create function public.record_porch_visit()
returns bigint
language sql
volatile
security definer
set search_path = public, pg_temp
as $$
  update public.site_counters set count = count + 1
  where key = 'porch_visits' returning count;
$$;

create function public.get_porch_visits()
returns bigint
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select count from public.site_counters where key = 'porch_visits';
$$;
revoke all on function public.record_porch_visit() from public, anon, authenticated;
revoke all on function public.get_porch_visits() from public, anon, authenticated;
grant execute on function public.record_porch_visit() to anon, authenticated;
grant execute on function public.get_porch_visits() to anon, authenticated;
commit;
