-- ============================================================
-- Phase 11D: Recovery Toolbox v1 (private pinned tools)
-- ============================================================
-- The Toolbox's tools are built into the app (stable keys such as
-- 'rough_day', 'grounding_54321', 'box_breathing'). This migration only
-- stores which built-in tools a signed-in member has pinned to
-- "My Toolbox". Grounding/breathing/quick-action use is never stored.
--
--   - recovery_toolbox_pins: one row per member per tool_key. tool_key
--     must be a short lowercase key (no URLs or markup). Unpinning sets
--     pinned = false (row kept). sort_order is the pin order; re-pinning
--     moves the tool to the end. At most 30 pinned tools per member.
--
-- Rules, same as 11A-11C: RLS on, no policies, no table privileges for
-- public/anon/authenticated; members use only the RPCs below, which act
-- on auth.uid()'s rows and never return user_id. No admin path, no view,
-- no trigger, no Community/profile/notification connection, no counts.
-- Additive only.
-- ============================================================


create table public.recovery_toolbox_pins (
  user_id uuid not null references auth.users(id) on delete cascade,
  tool_key text not null,
  pinned boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recovery_toolbox_pins_pkey primary key (user_id, tool_key),
  constraint recovery_toolbox_pins_key_check check (tool_key ~ '^[a-z0-9_]{1,40}$')
);

alter table public.recovery_toolbox_pins enable row level security;
revoke all on table public.recovery_toolbox_pins from public, anon, authenticated;


-- ---------- list_my_toolbox_pins ----------

create or replace function public.list_my_toolbox_pins()
returns table (tool_key text, sort_order integer)
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
    raise exception 'Sign in required to use My Toolbox.' using errcode = '42501';
  end if;

  return query
    select t.tool_key, t.sort_order
    from public.recovery_toolbox_pins t
    where t.user_id = caller_id and t.pinned
    order by t.sort_order, t.tool_key
    limit 30;
end;
$$;

revoke all on function public.list_my_toolbox_pins() from public, anon;
grant execute on function public.list_my_toolbox_pins() to authenticated;


-- ---------- set_toolbox_pin ----------
-- Pin (moves to the end of the pin order) or unpin one tool. Idempotent:
-- pinning an already-pinned tool keeps its place.

create or replace function public.set_toolbox_pin(p_tool_key text, p_pinned boolean)
returns table (tool_key text, pinned boolean, sort_order integer)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  v_next integer;
  v_count integer;
  v_was boolean;
begin
  if caller_id is null then
    raise exception 'Sign in required to use My Toolbox.' using errcode = '42501';
  end if;
  if p_tool_key is null or p_tool_key !~ '^[a-z0-9_]{1,40}$' then
    raise exception 'Unknown tool.' using errcode = '22023';
  end if;
  if p_pinned is null then
    raise exception 'Choose pin or unpin.' using errcode = '22023';
  end if;

  select t.pinned into v_was from public.recovery_toolbox_pins t
  where t.user_id = caller_id and t.tool_key = p_tool_key;

  if p_pinned and coalesce(v_was, false) = false then
    select count(*) into v_count from public.recovery_toolbox_pins t
    where t.user_id = caller_id and t.pinned;
    if v_count >= 30 then
      raise exception 'You can pin up to 30 tools.' using errcode = '22023';
    end if;
    select coalesce(max(t.sort_order), 0) + 1 into v_next from public.recovery_toolbox_pins t
    where t.user_id = caller_id;
    insert into public.recovery_toolbox_pins as t (user_id, tool_key, pinned, sort_order)
    values (caller_id, p_tool_key, true, v_next)
    on conflict (user_id, tool_key) do update
      set pinned = true, sort_order = v_next, updated_at = now();
  elsif not p_pinned and v_was is not null then
    update public.recovery_toolbox_pins t
    set pinned = false, updated_at = now()
    where t.user_id = caller_id and t.tool_key = p_tool_key;
  end if;

  return query
    select p_tool_key, coalesce(t.pinned, false), coalesce(t.sort_order, 0)
    from (select 1) x
    left join public.recovery_toolbox_pins t on t.user_id = caller_id and t.tool_key = p_tool_key;
end;
$$;

revoke all on function public.set_toolbox_pin(text, boolean) from public, anon;
grant execute on function public.set_toolbox_pin(text, boolean) to authenticated;
