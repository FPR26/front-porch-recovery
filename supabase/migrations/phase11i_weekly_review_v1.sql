-- ============================================================
-- Phase 11I: Weekly Review v1 (private weekly reflection)
-- ============================================================
-- The weekly factual summary (days logged, averages, support, Daily
-- Porch counts, wins, milestones) is DERIVED in the app from existing
-- records and never stored. This migration stores only what the member
-- writes about a week, plus two small read-only helpers that let the app
-- read one bounded date range (the existing list RPCs return the newest
-- 60 rows from a start date, which can miss older weeks).
--
--   - recovery_weekly_reviews: one row per member per week, keyed by the
--     week's Monday. Three reflections (each up to 750 characters) and a
--     next-week intention (up to 300). A new row needs at least one
--     field; an existing row may be cleared (empty rows aren't listed).
--   - list_my_recovery_logs_range(p_from, p_to): the caller's My Recovery
--     logs in a range of at most 100 days.
--   - list_my_daily_reflection_days(p_from, p_to): for each date in the
--     range (at most 100 days), only WHETHER a morning/evening reflection
--     exists. Reflection text is never returned.
--
-- Rules, same as 11A-11H: RLS on, no policies, no table privileges for
-- public/anon/authenticated; members use only these RPCs, which act on
-- auth.uid()'s rows and never return user_id. No admin path, no view,
-- no trigger, no Community/profile/notification connection. Existing
-- objects are not altered. Additive only.
-- ============================================================


create table public.recovery_weekly_reviews (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  week_start date not null,
  went_well text,
  was_hard text,
  what_helped text,
  next_week_intention text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recovery_weekly_reviews_user_week_key unique (user_id, week_start),
  constraint recovery_weekly_reviews_monday_check check (extract(isodow from week_start) = 1),
  constraint recovery_weekly_reviews_well_check check (went_well is null or char_length(went_well) between 1 and 750),
  constraint recovery_weekly_reviews_hard_check check (was_hard is null or char_length(was_hard) between 1 and 750),
  constraint recovery_weekly_reviews_helped_check check (what_helped is null or char_length(what_helped) between 1 and 750),
  constraint recovery_weekly_reviews_intention_check check (next_week_intention is null or char_length(next_week_intention) between 1 and 300)
);

alter table public.recovery_weekly_reviews enable row level security;
revoke all on table public.recovery_weekly_reviews from public, anon, authenticated;


-- ---------- list_my_weekly_reviews ----------
-- The caller's non-empty reviews for weeks starting on/after p_since
-- (newest first, at most 60).

create or replace function public.list_my_weekly_reviews(p_since date)
returns table (week_start date, went_well text, was_hard text, what_helped text,
               next_week_intention text, updated_at timestamptz)
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
    raise exception 'Sign in required to use Weekly Review.' using errcode = '42501';
  end if;

  return query
    select r.week_start, r.went_well, r.was_hard, r.what_helped, r.next_week_intention, r.updated_at
    from public.recovery_weekly_reviews r
    where r.user_id = caller_id
      and r.week_start >= coalesce(p_since, date '2000-01-01')
      and (r.went_well is not null or r.was_hard is not null or r.what_helped is not null or r.next_week_intention is not null)
    order by r.week_start desc
    limit 60;
end;
$$;

revoke all on function public.list_my_weekly_reviews(date) from public, anon;
grant execute on function public.list_my_weekly_reviews(date) to authenticated;


-- ---------- save_my_weekly_review ----------
-- Creates or replaces the caller's review for the week starting
-- p_week_start (a Monday, not after the current week; one day of
-- time-zone slack). Blank text is stored as NULL.

create or replace function public.save_my_weekly_review(
  p_week_start date,
  p_went_well text,
  p_was_hard text,
  p_what_helped text,
  p_next_week_intention text
)
returns table (week_start date, went_well text, was_hard text, what_helped text,
               next_week_intention text, updated_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  v_well text := nullif(btrim(coalesce(p_went_well, '')), '');
  v_hard text := nullif(btrim(coalesce(p_was_hard, '')), '');
  v_help text := nullif(btrim(coalesce(p_what_helped, '')), '');
  v_next text := nullif(btrim(coalesce(p_next_week_intention, '')), '');
  v_exists boolean;
begin
  if caller_id is null then
    raise exception 'Sign in required to use Weekly Review.' using errcode = '42501';
  end if;
  if p_week_start is null or extract(isodow from p_week_start) <> 1
     or p_week_start > (now() at time zone 'utc')::date + 1 or p_week_start < date '2000-01-03' then
    raise exception 'That week can''t be saved.' using errcode = '22023';
  end if;
  if char_length(v_well) > 750 or char_length(v_hard) > 750 or char_length(v_help) > 750 then
    raise exception 'Each reflection can be up to 750 characters.' using errcode = '22023';
  end if;
  if char_length(v_next) > 300 then
    raise exception 'Your intention can be up to 300 characters.' using errcode = '22023';
  end if;

  select true into v_exists from public.recovery_weekly_reviews r
  where r.user_id = caller_id and r.week_start = p_week_start;
  if coalesce(v_exists, false) = false and v_well is null and v_hard is null and v_help is null and v_next is null then
    raise exception 'Write something before saving.' using errcode = '22023';
  end if;

  insert into public.recovery_weekly_reviews as r
    (user_id, week_start, went_well, was_hard, what_helped, next_week_intention)
  values (caller_id, p_week_start, v_well, v_hard, v_help, v_next)
  on conflict (user_id, week_start) do update
    set went_well = excluded.went_well,
        was_hard = excluded.was_hard,
        what_helped = excluded.what_helped,
        next_week_intention = excluded.next_week_intention,
        updated_at = now();

  return query
    select r.week_start, r.went_well, r.was_hard, r.what_helped, r.next_week_intention, r.updated_at
    from public.recovery_weekly_reviews r
    where r.user_id = caller_id and r.week_start = p_week_start;
end;
$$;

revoke all on function public.save_my_weekly_review(date, text, text, text, text) from public, anon;
grant execute on function public.save_my_weekly_review(date, text, text, text, text) to authenticated;


-- ---------- list_my_recovery_logs_range ----------

create or replace function public.list_my_recovery_logs_range(p_from date, p_to date)
returns table (log_date date, mood smallint, cravings smallint)
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
    raise exception 'Sign in required.' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 100 then
    raise exception 'Choose a range of up to 100 days.' using errcode = '22023';
  end if;

  return query
    select l.log_date, l.mood, l.cravings
    from public.recovery_daily_logs l
    where l.user_id = caller_id and l.log_date between p_from and p_to
    order by l.log_date;
end;
$$;

revoke all on function public.list_my_recovery_logs_range(date, date) from public, anon;
grant execute on function public.list_my_recovery_logs_range(date, date) to authenticated;


-- ---------- list_my_daily_reflection_days ----------
-- Presence flags only; reflection text never leaves the table here.

create or replace function public.list_my_daily_reflection_days(p_from date, p_to date)
returns table (reflection_date date, has_morning boolean, has_evening boolean)
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
    raise exception 'Sign in required.' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 100 then
    raise exception 'Choose a range of up to 100 days.' using errcode = '22023';
  end if;

  return query
    select r.reflection_date, r.morning_text is not null, r.evening_text is not null
    from public.recovery_daily_reflections r
    where r.user_id = caller_id and r.reflection_date between p_from and p_to
      and (r.morning_text is not null or r.evening_text is not null)
    order by r.reflection_date;
end;
$$;

revoke all on function public.list_my_daily_reflection_days(date, date) from public, anon;
grant execute on function public.list_my_daily_reflection_days(date, date) to authenticated;
