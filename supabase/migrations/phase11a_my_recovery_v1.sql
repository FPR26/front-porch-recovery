-- ============================================================
-- Phase 11A: My Recovery v1 (private daily logs + one current goal)
-- ============================================================
-- My Recovery is a signed-in, account-private area. It is separate from
-- the on-device Daily Check-In and Recovery Counter, which are untouched
-- and never uploaded: nothing here reads or copies local data.
--
-- Rules this migration enforces:
--   - recovery_daily_logs: one row per member per calendar date
--     (the member's local date, sent by the app). mood 1-5, cravings
--     0-10, two optional notes of at most 300 characters each; at least
--     one field must be filled in.
--   - recovery_goals: at most one ACTIVE goal per member (cleared_at is
--     null). Clearing or replacing a goal sets cleared_at; older goals
--     stay stored but are not listed in v1.
--   - RLS is on and anon/authenticated have NO table privileges. Every
--     read/write goes through the RPCs below, which act only on
--     auth.uid()'s own rows and never return user_id or row ids.
--   - No admin read path, no public view, no Community/profile/
--     notification/badge connection.
--   - Additive only: no existing object is altered or dropped.
-- ============================================================


-- ---------- recovery_daily_logs ----------

create table public.recovery_daily_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  log_date date not null,
  mood smallint,
  cravings smallint,
  win_text text,
  need_text text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recovery_daily_logs_user_date_key unique (user_id, log_date),
  constraint recovery_daily_logs_mood_check check (mood is null or mood between 1 and 5),
  constraint recovery_daily_logs_cravings_check check (cravings is null or cravings between 0 and 10),
  constraint recovery_daily_logs_win_check check (win_text is null or char_length(win_text) between 1 and 300),
  constraint recovery_daily_logs_need_check check (need_text is null or char_length(need_text) between 1 and 300),
  constraint recovery_daily_logs_not_empty_check check (
    mood is not null or cravings is not null or win_text is not null or need_text is not null
  )
);

alter table public.recovery_daily_logs enable row level security;
revoke all on table public.recovery_daily_logs from public, anon, authenticated;


-- ---------- recovery_goals ----------

create table public.recovery_goals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  goal_text text not null,
  target_date date,
  completed boolean not null default false,
  completed_at timestamptz,
  cleared_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recovery_goals_text_check check (char_length(goal_text) between 1 and 200)
);

-- One active goal per member.
create unique index recovery_goals_one_active_idx
  on public.recovery_goals (user_id) where cleared_at is null;

alter table public.recovery_goals enable row level security;
revoke all on table public.recovery_goals from public, anon, authenticated;


-- ---------- save_my_recovery_log ----------
-- Creates or updates the caller's entry for p_log_date. Blank notes are
-- stored as null. p_log_date is the member's local date; it may be at
-- most one day ahead of the server's UTC date (time zones) and at most
-- 366 days in the past.

create or replace function public.save_my_recovery_log(
  p_log_date date,
  p_mood integer,
  p_cravings integer,
  p_win_text text,
  p_need_text text
)
returns table (log_date date, mood smallint, cravings smallint, win_text text, need_text text,
               created_at timestamptz, updated_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  v_win text := nullif(btrim(coalesce(p_win_text, '')), '');
  v_need text := nullif(btrim(coalesce(p_need_text, '')), '');
begin
  if caller_id is null then
    raise exception 'Sign in required to use My Recovery.' using errcode = '42501';
  end if;
  if p_log_date is null or p_log_date > (now() at time zone 'utc')::date + 1
     or p_log_date < (now() at time zone 'utc')::date - 366 then
    raise exception 'That date can''t be saved.' using errcode = '22023';
  end if;
  if p_mood is not null and (p_mood < 1 or p_mood > 5) then
    raise exception 'Mood must be from 1 to 5.' using errcode = '22023';
  end if;
  if p_cravings is not null and (p_cravings < 0 or p_cravings > 10) then
    raise exception 'Cravings must be from 0 to 10.' using errcode = '22023';
  end if;
  if char_length(v_win) > 300 or char_length(v_need) > 300 then
    raise exception 'Notes can be up to 300 characters.' using errcode = '22023';
  end if;
  if p_mood is null and p_cravings is null and v_win is null and v_need is null then
    raise exception 'Add at least one thing before saving.' using errcode = '22023';
  end if;

  insert into public.recovery_daily_logs as l (user_id, log_date, mood, cravings, win_text, need_text)
  values (caller_id, p_log_date, p_mood, p_cravings, v_win, v_need)
  on conflict (user_id, log_date) do update
    set mood = excluded.mood,
        cravings = excluded.cravings,
        win_text = excluded.win_text,
        need_text = excluded.need_text,
        updated_at = now();

  return query
    select l.log_date, l.mood, l.cravings, l.win_text, l.need_text, l.created_at, l.updated_at
    from public.recovery_daily_logs l
    where l.user_id = caller_id and l.log_date = p_log_date;
end;
$$;

revoke all on function public.save_my_recovery_log(date, integer, integer, text, text) from public, anon;
grant execute on function public.save_my_recovery_log(date, integer, integer, text, text) to authenticated;


-- ---------- list_my_recovery_logs ----------
-- The caller's entries on or after p_since (newest first), capped at
-- 60 rows and at most 366 days back.

create or replace function public.list_my_recovery_logs(p_since date)
returns table (log_date date, mood smallint, cravings smallint, win_text text, need_text text,
               created_at timestamptz, updated_at timestamptz)
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
    raise exception 'Sign in required to use My Recovery.' using errcode = '42501';
  end if;

  return query
    select l.log_date, l.mood, l.cravings, l.win_text, l.need_text, l.created_at, l.updated_at
    from public.recovery_daily_logs l
    where l.user_id = caller_id
      and l.log_date >= greatest(coalesce(p_since, (now() at time zone 'utc')::date - 30),
                                 (now() at time zone 'utc')::date - 366)
    order by l.log_date desc
    limit 60;
end;
$$;

revoke all on function public.list_my_recovery_logs(date) from public, anon;
grant execute on function public.list_my_recovery_logs(date) to authenticated;


-- ---------- get_my_recovery_goal ----------
-- The caller's active goal (zero or one row).

create or replace function public.get_my_recovery_goal()
returns table (goal_text text, target_date date, completed boolean, completed_at timestamptz,
               created_at timestamptz, updated_at timestamptz)
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
    raise exception 'Sign in required to use My Recovery.' using errcode = '42501';
  end if;

  return query
    select g.goal_text, g.target_date, g.completed, g.completed_at, g.created_at, g.updated_at
    from public.recovery_goals g
    where g.user_id = caller_id and g.cleared_at is null;
end;
$$;

revoke all on function public.get_my_recovery_goal() from public, anon;
grant execute on function public.get_my_recovery_goal() to authenticated;


-- ---------- set_my_recovery_goal ----------
-- p_replace = false: edit the active goal's text/target date (or create
-- one if none is active). p_replace = true: clear the active goal (kept
-- stored) and start a new, not-completed goal.

create or replace function public.set_my_recovery_goal(
  p_goal_text text,
  p_target_date date,
  p_replace boolean default false
)
returns table (goal_text text, target_date date, completed boolean, completed_at timestamptz,
               created_at timestamptz, updated_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  v_text text := nullif(btrim(coalesce(p_goal_text, '')), '');
  v_updated integer := 0;
begin
  if caller_id is null then
    raise exception 'Sign in required to use My Recovery.' using errcode = '42501';
  end if;
  if v_text is null then
    raise exception 'Write a goal first.' using errcode = '22023';
  end if;
  if char_length(v_text) > 200 then
    raise exception 'Goals can be up to 200 characters.' using errcode = '22023';
  end if;
  if p_target_date is not null and (p_target_date < date '2000-01-01' or p_target_date > date '2100-12-31') then
    raise exception 'That target date can''t be saved.' using errcode = '22023';
  end if;

  if coalesce(p_replace, false) then
    update public.recovery_goals g set cleared_at = now(), updated_at = now()
    where g.user_id = caller_id and g.cleared_at is null;
  else
    update public.recovery_goals g
    set goal_text = v_text, target_date = p_target_date, updated_at = now()
    where g.user_id = caller_id and g.cleared_at is null;
    get diagnostics v_updated = row_count;
  end if;

  if v_updated = 0 then
    insert into public.recovery_goals (user_id, goal_text, target_date)
    values (caller_id, v_text, p_target_date);
  end if;

  return query
    select g.goal_text, g.target_date, g.completed, g.completed_at, g.created_at, g.updated_at
    from public.recovery_goals g
    where g.user_id = caller_id and g.cleared_at is null;
end;
$$;

revoke all on function public.set_my_recovery_goal(text, date, boolean) from public, anon;
grant execute on function public.set_my_recovery_goal(text, date, boolean) to authenticated;


-- ---------- set_my_recovery_goal_completed ----------

create or replace function public.set_my_recovery_goal_completed(p_completed boolean)
returns table (goal_text text, target_date date, completed boolean, completed_at timestamptz,
               created_at timestamptz, updated_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'Sign in required to use My Recovery.' using errcode = '42501';
  end if;
  if p_completed is null then
    raise exception 'Choose complete or not complete.' using errcode = '22023';
  end if;

  update public.recovery_goals g
  set completed = p_completed,
      completed_at = case when p_completed then coalesce(g.completed_at, now()) else null end,
      updated_at = now()
  where g.user_id = caller_id and g.cleared_at is null;
  if not found then
    raise exception 'No current goal.' using errcode = 'P0002';
  end if;

  return query
    select g.goal_text, g.target_date, g.completed, g.completed_at, g.created_at, g.updated_at
    from public.recovery_goals g
    where g.user_id = caller_id and g.cleared_at is null;
end;
$$;

revoke all on function public.set_my_recovery_goal_completed(boolean) from public, anon;
grant execute on function public.set_my_recovery_goal_completed(boolean) to authenticated;


-- ---------- clear_my_recovery_goal ----------
-- Idempotent. The goal stays stored (cleared_at set) but is no longer shown.

create or replace function public.clear_my_recovery_goal()
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'Sign in required to use My Recovery.' using errcode = '42501';
  end if;

  update public.recovery_goals g set cleared_at = now(), updated_at = now()
  where g.user_id = caller_id and g.cleared_at is null;
  return true;
end;
$$;

revoke all on function public.clear_my_recovery_goal() from public, anon;
grant execute on function public.clear_my_recovery_goal() to authenticated;
