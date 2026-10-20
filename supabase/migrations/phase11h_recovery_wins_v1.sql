-- ============================================================
-- Phase 11H: Milestones & Wins v1 (private personal wins)
-- ============================================================
-- Automatic recovery milestones are CALCULATED in the app from the
-- member's existing profile recovery_date; nothing about milestones is
-- stored. This migration only adds private personal wins.
--
--   - recovery_wins: one row per win (title 1-120, optional note up to
--     500, win_date not in the future). Removing a win sets removed_at
--     (soft remove, like the other recovery features; no DELETE).
--
-- Rules, same as 11A-11E: RLS on, no policies, no table privileges for
-- public/anon/authenticated; members use only the RPCs below, which act
-- on auth.uid()'s rows and never return user_id. Win ids are random
-- UUIDs used only for the owner's own edits. No admin path, no view, no
-- trigger, no Community/profile/notification connection, no sharing.
-- Additive only.
-- ============================================================


create table public.recovery_wins (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  win_date date not null,
  title text not null,
  note text,
  removed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recovery_wins_title_check check (char_length(title) between 1 and 120),
  constraint recovery_wins_note_check check (note is null or char_length(note) between 1 and 500)
);

create index recovery_wins_user_date_idx on public.recovery_wins (user_id, win_date);

alter table public.recovery_wins enable row level security;
revoke all on table public.recovery_wins from public, anon, authenticated;


-- ---------- list_my_wins ----------

create or replace function public.list_my_wins()
returns table (id uuid, win_date date, title text, note text, updated_at timestamptz)
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
    raise exception 'Sign in required to use Milestones & Wins.' using errcode = '42501';
  end if;

  return query
    select w.id, w.win_date, w.title, w.note, w.updated_at
    from public.recovery_wins w
    where w.user_id = caller_id and w.removed_at is null
    order by w.win_date desc, w.created_at desc
    limit 500;
end;
$$;

revoke all on function public.list_my_wins() from public, anon;
grant execute on function public.list_my_wins() to authenticated;


-- ---------- save_my_win ----------
-- p_id null adds a win (max 500 kept per member); otherwise edits the
-- caller's own, not-removed win. win_date may be at most one day past
-- the server's UTC date (time zones) and no earlier than 1900.

create or replace function public.save_my_win(p_id uuid, p_win_date date, p_title text, p_note text)
returns table (id uuid, win_date date, title text, note text, updated_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid;
  v_count integer;
begin
  if caller_id is null then
    raise exception 'Sign in required to use Milestones & Wins.' using errcode = '42501';
  end if;
  if v_title is null then
    raise exception 'Give your win a title.' using errcode = '22023';
  end if;
  if char_length(v_title) > 120 then
    raise exception 'Titles can be up to 120 characters.' using errcode = '22023';
  end if;
  if char_length(v_note) > 500 then
    raise exception 'Notes can be up to 500 characters.' using errcode = '22023';
  end if;
  if p_win_date is null or p_win_date > (now() at time zone 'utc')::date + 1 or p_win_date < date '1900-01-01' then
    raise exception 'Choose a date that isn''t in the future.' using errcode = '22023';
  end if;

  if p_id is null then
    select count(*) into v_count from public.recovery_wins w
    where w.user_id = caller_id and w.removed_at is null;
    if v_count >= 500 then
      raise exception 'You can keep up to 500 wins.' using errcode = '22023';
    end if;
    insert into public.recovery_wins (user_id, win_date, title, note)
    values (caller_id, p_win_date, v_title, v_note)
    returning recovery_wins.id into v_id;
  else
    update public.recovery_wins w
    set win_date = p_win_date, title = v_title, note = v_note, updated_at = now()
    where w.id = p_id and w.user_id = caller_id and w.removed_at is null
    returning w.id into v_id;
    if v_id is null then
      raise exception 'Win not found.' using errcode = 'P0002';
    end if;
  end if;

  return query
    select w.id, w.win_date, w.title, w.note, w.updated_at
    from public.recovery_wins w
    where w.id = v_id;
end;
$$;

revoke all on function public.save_my_win(uuid, date, text, text) from public, anon;
grant execute on function public.save_my_win(uuid, date, text, text) to authenticated;


-- ---------- remove_my_win ----------

create or replace function public.remove_my_win(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'Sign in required to use Milestones & Wins.' using errcode = '42501';
  end if;

  update public.recovery_wins w
  set removed_at = now(), updated_at = now()
  where w.id = p_id and w.user_id = caller_id and w.removed_at is null;
  if not found then
    raise exception 'Win not found.' using errcode = 'P0002';
  end if;
  return true;
end;
$$;

revoke all on function public.remove_my_win(uuid) from public, anon;
grant execute on function public.remove_my_win(uuid) to authenticated;
