-- ============================================================
-- Phase 11E: Meetings & Support v1 (private weekly support plan)
-- ============================================================
-- A signed-in member's own plan of support for the week: meetings of
-- any program, therapy, groups, calls, anything they choose. Not tied to
-- any program; no recommendations, scores or streaks.
--
--   - recovery_support_items: one row per support item. A one-time item
--     happens on scheduled_date. A weekly item (repeat_weekly) happens on
--     scheduled_date's weekday every week from scheduled_date on, until
--     ended_on (inclusive) if set. Removing a weekly item sets ended_on so
--     past weeks keep it; removing a one-time item sets removed_at. Rows
--     are never deleted, so check-off history is preserved.
--   - recovery_support_checkins: one row per item per occurrence date.
--     Marking one week's occurrence never touches any other week.
--     Un-marking sets completed = false (row kept).
--
-- Rules, same as 11A-11D: RLS on, no policies, no table privileges for
-- public/anon/authenticated; members use only the RPCs below, which act
-- on auth.uid()'s rows and never return user_id. Item ids are random
-- UUIDs used only to edit/check off the member's own items. No admin
-- path, no view, no trigger, no Community/profile/notification link.
-- Additive only.
-- ============================================================


create table public.recovery_support_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  category text,
  name text not null,
  scheduled_date date not null,
  scheduled_time time,
  location_note text,
  repeat_weekly boolean not null default false,
  ended_on date,
  removed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recovery_support_items_category_check check (category is null or char_length(category) between 1 and 40),
  constraint recovery_support_items_name_check check (char_length(name) between 1 and 120),
  constraint recovery_support_items_location_check check (location_note is null or char_length(location_note) between 1 and 300)
);

create index recovery_support_items_user_idx on public.recovery_support_items (user_id);

alter table public.recovery_support_items enable row level security;
revoke all on table public.recovery_support_items from public, anon, authenticated;


create table public.recovery_support_checkins (
  user_id uuid not null references auth.users(id) on delete cascade,
  item_id uuid not null references public.recovery_support_items(id) on delete cascade,
  occurrence_date date not null,
  completed boolean not null default true,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recovery_support_checkins_pkey primary key (item_id, occurrence_date)
);

create index recovery_support_checkins_user_date_idx on public.recovery_support_checkins (user_id, occurrence_date);

alter table public.recovery_support_checkins enable row level security;
revoke all on table public.recovery_support_checkins from public, anon, authenticated;


-- ---------- list_my_support_items ----------
-- Items that can have an occurrence between p_from and p_to (at most 62
-- days): weekly items that started by p_to and hadn't ended before
-- p_from, and one-time items dated in the range. Removed one-time items
-- are excluded.

create or replace function public.list_my_support_items(p_from date, p_to date)
returns table (id uuid, category text, name text, scheduled_date date, scheduled_time time,
               location_note text, repeat_weekly boolean, ended_on date, updated_at timestamptz)
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
    raise exception 'Sign in required to use Meetings & Support.' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'Choose a range of up to 62 days.' using errcode = '22023';
  end if;

  return query
    select i.id, i.category, i.name, i.scheduled_date, i.scheduled_time,
           i.location_note, i.repeat_weekly, i.ended_on, i.updated_at
    from public.recovery_support_items i
    where i.user_id = caller_id
      and i.removed_at is null
      and (
        (i.repeat_weekly and i.scheduled_date <= p_to and (i.ended_on is null or i.ended_on >= p_from))
        or (not i.repeat_weekly and i.scheduled_date between p_from and p_to)
      )
    order by i.scheduled_time nulls last, i.name
    limit 200;
end;
$$;

revoke all on function public.list_my_support_items(date, date) from public, anon;
grant execute on function public.list_my_support_items(date, date) to authenticated;


-- ---------- list_my_support_checkins ----------

create or replace function public.list_my_support_checkins(p_from date, p_to date)
returns table (item_id uuid, occurrence_date date, completed_at timestamptz)
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
    raise exception 'Sign in required to use Meetings & Support.' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 62 then
    raise exception 'Choose a range of up to 62 days.' using errcode = '22023';
  end if;

  return query
    select c.item_id, c.occurrence_date, c.completed_at
    from public.recovery_support_checkins c
    where c.user_id = caller_id and c.completed
      and c.occurrence_date between p_from and p_to
    order by c.occurrence_date
    limit 500;
end;
$$;

revoke all on function public.list_my_support_checkins(date, date) from public, anon;
grant execute on function public.list_my_support_checkins(date, date) to authenticated;


-- ---------- save_my_support_item ----------
-- p_id null creates an item (max 50 active per member); otherwise
-- updates the caller's own, not-removed item. Blank optional text is
-- stored as NULL.

create or replace function public.save_my_support_item(
  p_id uuid,
  p_category text,
  p_name text,
  p_scheduled_date date,
  p_scheduled_time time,
  p_location_note text,
  p_repeat_weekly boolean
)
returns table (id uuid, category text, name text, scheduled_date date, scheduled_time time,
               location_note text, repeat_weekly boolean, ended_on date, updated_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  v_cat text := nullif(btrim(coalesce(p_category, '')), '');
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_loc text := nullif(btrim(coalesce(p_location_note, '')), '');
  v_id uuid;
  v_count integer;
begin
  if caller_id is null then
    raise exception 'Sign in required to use Meetings & Support.' using errcode = '42501';
  end if;
  if v_name is null then
    raise exception 'Give it a name.' using errcode = '22023';
  end if;
  if char_length(v_name) > 120 then
    raise exception 'Names can be up to 120 characters.' using errcode = '22023';
  end if;
  if char_length(v_cat) > 40 then
    raise exception 'That type is too long.' using errcode = '22023';
  end if;
  if char_length(v_loc) > 300 then
    raise exception 'Location, link, or note can be up to 300 characters.' using errcode = '22023';
  end if;
  if p_scheduled_date is null or p_scheduled_date < date '2000-01-01' or p_scheduled_date > date '2100-12-31' then
    raise exception 'Choose a day.' using errcode = '22023';
  end if;

  if p_id is null then
    select count(*) into v_count from public.recovery_support_items i
    where i.user_id = caller_id and i.removed_at is null and (i.ended_on is null or i.ended_on >= current_date);
    if v_count >= 50 then
      raise exception 'You can have up to 50 support items.' using errcode = '22023';
    end if;
    insert into public.recovery_support_items
      (user_id, category, name, scheduled_date, scheduled_time, location_note, repeat_weekly)
    values (caller_id, v_cat, v_name, p_scheduled_date, p_scheduled_time, v_loc, coalesce(p_repeat_weekly, false))
    returning recovery_support_items.id into v_id;
  else
    update public.recovery_support_items i
    set category = v_cat, name = v_name, scheduled_date = p_scheduled_date,
        scheduled_time = p_scheduled_time, location_note = v_loc,
        repeat_weekly = coalesce(p_repeat_weekly, false), updated_at = now()
    where i.id = p_id and i.user_id = caller_id and i.removed_at is null
    returning i.id into v_id;
    if v_id is null then
      raise exception 'Support item not found.' using errcode = 'P0002';
    end if;
  end if;

  return query
    select i.id, i.category, i.name, i.scheduled_date, i.scheduled_time,
           i.location_note, i.repeat_weekly, i.ended_on, i.updated_at
    from public.recovery_support_items i
    where i.id = v_id;
end;
$$;

revoke all on function public.save_my_support_item(uuid, text, text, date, time, text, boolean) from public, anon;
grant execute on function public.save_my_support_item(uuid, text, text, date, time, text, boolean) to authenticated;


-- ---------- remove_my_support_item ----------
-- One-time item: hidden (removed_at). Weekly item: occurrences on or
-- after p_from_date stop (ended_on = p_from_date - 1); earlier weeks and
-- every check-off stay. If the weekly item hadn't started yet, it's hidden.

create or replace function public.remove_my_support_item(p_id uuid, p_from_date date)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  r public.recovery_support_items%rowtype;
begin
  if caller_id is null then
    raise exception 'Sign in required to use Meetings & Support.' using errcode = '42501';
  end if;
  if p_from_date is null then
    raise exception 'Choose a date.' using errcode = '22023';
  end if;

  select * into r from public.recovery_support_items i
  where i.id = p_id and i.user_id = caller_id and i.removed_at is null;
  if not found then
    raise exception 'Support item not found.' using errcode = 'P0002';
  end if;

  if r.repeat_weekly and r.scheduled_date < p_from_date then
    update public.recovery_support_items i
    set ended_on = least(coalesce(i.ended_on, p_from_date - 1), p_from_date - 1), updated_at = now()
    where i.id = r.id;
  else
    update public.recovery_support_items i
    set removed_at = now(), updated_at = now()
    where i.id = r.id;
  end if;
  return true;
end;
$$;

revoke all on function public.remove_my_support_item(uuid, date) from public, anon;
grant execute on function public.remove_my_support_item(uuid, date) to authenticated;


-- ---------- set_my_support_checkin ----------
-- Marks (or un-marks) ONE occurrence of the caller's own item as done.
-- The date must be a real occurrence of that item and not in the future
-- (one day of time-zone slack).

create or replace function public.set_my_support_checkin(p_item_id uuid, p_occurrence_date date, p_completed boolean)
returns table (item_id uuid, occurrence_date date, completed boolean, completed_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  r public.recovery_support_items%rowtype;
begin
  if caller_id is null then
    raise exception 'Sign in required to use Meetings & Support.' using errcode = '42501';
  end if;
  if p_completed is null or p_occurrence_date is null then
    raise exception 'Choose a day.' using errcode = '22023';
  end if;
  if p_occurrence_date > (now() at time zone 'utc')::date + 1 then
    raise exception 'You can mark this once the day comes.' using errcode = '22023';
  end if;

  select * into r from public.recovery_support_items i
  where i.id = p_item_id and i.user_id = caller_id and i.removed_at is null;
  if not found then
    raise exception 'Support item not found.' using errcode = 'P0002';
  end if;
  if r.repeat_weekly then
    if p_occurrence_date < r.scheduled_date
       or extract(isodow from p_occurrence_date) <> extract(isodow from r.scheduled_date)
       or (r.ended_on is not null and p_occurrence_date > r.ended_on) then
      raise exception 'That day isn''t one of this item''s days.' using errcode = '22023';
    end if;
  elsif p_occurrence_date <> r.scheduled_date then
    raise exception 'That day isn''t this item''s day.' using errcode = '22023';
  end if;

  insert into public.recovery_support_checkins as c (user_id, item_id, occurrence_date, completed, completed_at)
  values (caller_id, r.id, p_occurrence_date, p_completed, case when p_completed then now() end)
  on conflict (item_id, occurrence_date) do update
    set completed = excluded.completed,
        completed_at = case when excluded.completed then coalesce(c.completed_at, now()) else null end,
        updated_at = now();

  return query
    select c.item_id, c.occurrence_date, c.completed, c.completed_at
    from public.recovery_support_checkins c
    where c.item_id = r.id and c.occurrence_date = p_occurrence_date;
end;
$$;

revoke all on function public.set_my_support_checkin(uuid, date, boolean) from public, anon;
grant execute on function public.set_my_support_checkin(uuid, date, boolean) to authenticated;
