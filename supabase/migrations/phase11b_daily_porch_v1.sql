-- ============================================================
-- Phase 11B: Daily Porch v1 (private reflections + saved days)
-- ============================================================
-- The Daily Porch content itself is public app content
-- (CONFIG.dailyEntries in index.html, days 1-365). This migration only
-- stores what a signed-in member writes or saves:
--
--   - recovery_daily_reflections: one row per member per local calendar
--     date, with an optional morning and evening reflection (each at most
--     500 characters). Separate from recovery_daily_logs (My Recovery) so
--     reflections never count as My Recovery entries or alter its rules.
--   - saved_daily_porch: one row per member per Daily Porch day (1-365).
--     Unsaving sets saved = false (the row is kept, no history UI).
--
-- Rules, same as My Recovery (Phase 11A):
--   - RLS on, no policies, and no table privileges for public/anon/
--     authenticated. Members use only the RPCs below, which act on
--     auth.uid()'s own rows and never return ids or user_id.
--   - No admin read path, no view, no trigger, no Community/profile/
--     notification connection, no public counts.
--   - Additive only: no existing object is altered or dropped.
-- ============================================================


-- ---------- recovery_daily_reflections ----------

create table public.recovery_daily_reflections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  reflection_date date not null,
  morning_text text,
  evening_text text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recovery_daily_reflections_user_date_key unique (user_id, reflection_date),
  constraint recovery_daily_reflections_morning_check check (morning_text is null or char_length(morning_text) between 1 and 500),
  constraint recovery_daily_reflections_evening_check check (evening_text is null or char_length(evening_text) between 1 and 500)
);

alter table public.recovery_daily_reflections enable row level security;
revoke all on table public.recovery_daily_reflections from public, anon, authenticated;


-- ---------- saved_daily_porch ----------

create table public.saved_daily_porch (
  user_id uuid not null references auth.users(id) on delete cascade,
  day_number smallint not null,
  saved boolean not null default true,
  saved_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint saved_daily_porch_pkey primary key (user_id, day_number),
  constraint saved_daily_porch_day_check check (day_number between 1 and 365)
);

alter table public.saved_daily_porch enable row level security;
revoke all on table public.saved_daily_porch from public, anon, authenticated;


-- ---------- save_my_daily_reflection ----------
-- Sets ONE part ('morning' or 'evening') for p_date and leaves the other
-- untouched. Blank text clears that part. p_date is the member's local
-- date: at most one day ahead of the server's UTC date, at most 366 back.

create or replace function public.save_my_daily_reflection(
  p_date date,
  p_part text,
  p_text text
)
returns table (reflection_date date, morning_text text, evening_text text, updated_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  v_text text := nullif(btrim(coalesce(p_text, '')), '');
begin
  if caller_id is null then
    raise exception 'Sign in required to save reflections.' using errcode = '42501';
  end if;
  if p_date is null or p_date > (now() at time zone 'utc')::date + 1
     or p_date < (now() at time zone 'utc')::date - 366 then
    raise exception 'That date can''t be saved.' using errcode = '22023';
  end if;
  if p_part is null or p_part not in ('morning', 'evening') then
    raise exception 'Choose morning or evening.' using errcode = '22023';
  end if;
  if char_length(v_text) > 500 then
    raise exception 'Reflections can be up to 500 characters.' using errcode = '22023';
  end if;

  insert into public.recovery_daily_reflections as r (user_id, reflection_date, morning_text, evening_text)
  values (caller_id, p_date,
          case when p_part = 'morning' then v_text end,
          case when p_part = 'evening' then v_text end)
  on conflict (user_id, reflection_date) do update
    set morning_text = case when p_part = 'morning' then v_text else r.morning_text end,
        evening_text = case when p_part = 'evening' then v_text else r.evening_text end,
        updated_at = now();

  return query
    select r.reflection_date, r.morning_text, r.evening_text, r.updated_at
    from public.recovery_daily_reflections r
    where r.user_id = caller_id and r.reflection_date = p_date;
end;
$$;

revoke all on function public.save_my_daily_reflection(date, text, text) from public, anon;
grant execute on function public.save_my_daily_reflection(date, text, text) to authenticated;


-- ---------- list_my_daily_reflections ----------
-- The caller's non-empty reflections on or after p_since (newest first),
-- capped at 60 rows and at most 366 days back.

create or replace function public.list_my_daily_reflections(p_since date)
returns table (reflection_date date, morning_text text, evening_text text, updated_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'Sign in required to read reflections.' using errcode = '42501';
  end if;

  return query
    select r.reflection_date, r.morning_text, r.evening_text, r.updated_at
    from public.recovery_daily_reflections r
    where r.user_id = caller_id
      and (r.morning_text is not null or r.evening_text is not null)
      and r.reflection_date >= greatest(coalesce(p_since, (now() at time zone 'utc')::date - 7),
                                        (now() at time zone 'utc')::date - 366)
    order by r.reflection_date desc
    limit 60;
end;
$$;

revoke all on function public.list_my_daily_reflections(date) from public, anon;
grant execute on function public.list_my_daily_reflections(date) to authenticated;


-- ---------- set_daily_porch_saved ----------

create or replace function public.set_daily_porch_saved(p_day integer, p_saved boolean)
returns table (day_number smallint, saved boolean, saved_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'Sign in required to save days.' using errcode = '42501';
  end if;
  if p_day is null or p_day < 1 or p_day > 365 then
    raise exception 'Day must be from 1 to 365.' using errcode = '22023';
  end if;
  if p_saved is null then
    raise exception 'Choose save or unsave.' using errcode = '22023';
  end if;

  insert into public.saved_daily_porch as s (user_id, day_number, saved)
  values (caller_id, p_day, p_saved)
  on conflict (user_id, day_number) do update
    set saved = excluded.saved,
        saved_at = case when excluded.saved and not s.saved then now() else s.saved_at end,
        updated_at = now();

  return query
    select s.day_number, s.saved, s.saved_at
    from public.saved_daily_porch s
    where s.user_id = caller_id and s.day_number = p_day;
end;
$$;

revoke all on function public.set_daily_porch_saved(integer, boolean) from public, anon;
grant execute on function public.set_daily_porch_saved(integer, boolean) to authenticated;


-- ---------- list_my_saved_daily_porch ----------

create or replace function public.list_my_saved_daily_porch()
returns table (day_number smallint, saved_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'Sign in required to read saved days.' using errcode = '42501';
  end if;

  return query
    select s.day_number, s.saved_at
    from public.saved_daily_porch s
    where s.user_id = caller_id and s.saved
    order by s.saved_at desc
    limit 365;
end;
$$;

revoke all on function public.list_my_saved_daily_porch() from public, anon;
grant execute on function public.list_my_saved_daily_porch() to authenticated;
