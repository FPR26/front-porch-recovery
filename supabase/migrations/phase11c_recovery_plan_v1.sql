-- ============================================================
-- Phase 11C: My Recovery Plan v1 (private personal recovery plan)
-- ============================================================
-- One private plan per signed-in member: warning signs, what helps,
-- up to 5 support contacts (manual entry only), up to 3 next steps, and
-- reasons for recovery. It's the member's own plan, not a clinical or
-- emergency tool, and it is never shared.
--
-- Rules, same as My Recovery (11A) and Daily Porch (11B):
--   - recovery_plans: one row per member (primary key user_id). Contacts
--     are a small JSON array validated and normalised by the save RPC
--     (max 5; name 1-80, contact 0-120, role 0-60 characters).
--   - RLS on, no policies, and no table privileges for public/anon/
--     authenticated. Members use only the two RPCs below, which act on
--     auth.uid()'s own row and never return user_id.
--   - No admin read path, no view, no trigger, no Community/profile/
--     follower/notification connection, no sharing or export.
--   - Additive only: no existing object is altered or dropped.
-- ============================================================


create table public.recovery_plans (
  user_id uuid primary key references auth.users(id) on delete cascade,
  warning_signs text,
  what_helps text,
  reasons_for_recovery text,
  step_1 text,
  step_2 text,
  step_3 text,
  contacts jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recovery_plans_warning_check check (warning_signs is null or char_length(warning_signs) between 1 and 750),
  constraint recovery_plans_helps_check check (what_helps is null or char_length(what_helps) between 1 and 750),
  constraint recovery_plans_reasons_check check (reasons_for_recovery is null or char_length(reasons_for_recovery) between 1 and 750),
  constraint recovery_plans_step1_check check (step_1 is null or char_length(step_1) between 1 and 150),
  constraint recovery_plans_step2_check check (step_2 is null or char_length(step_2) between 1 and 150),
  constraint recovery_plans_step3_check check (step_3 is null or char_length(step_3) between 1 and 150),
  constraint recovery_plans_contacts_check check (jsonb_typeof(contacts) = 'array' and jsonb_array_length(contacts) <= 5)
);

alter table public.recovery_plans enable row level security;
revoke all on table public.recovery_plans from public, anon, authenticated;


-- ---------- get_my_recovery_plan ----------
-- Zero rows if the member hasn't saved a plan yet.

create or replace function public.get_my_recovery_plan()
returns table (warning_signs text, what_helps text, reasons_for_recovery text,
               step_1 text, step_2 text, step_3 text, contacts jsonb,
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
    raise exception 'Sign in required to use My Recovery Plan.' using errcode = '42501';
  end if;

  return query
    select p.warning_signs, p.what_helps, p.reasons_for_recovery,
           p.step_1, p.step_2, p.step_3, p.contacts, p.created_at, p.updated_at
    from public.recovery_plans p
    where p.user_id = caller_id;
end;
$$;

revoke all on function public.get_my_recovery_plan() from public, anon;
grant execute on function public.get_my_recovery_plan() to authenticated;


-- ---------- save_my_recovery_plan ----------
-- Replaces the whole plan. Blank text is stored as NULL (clears that
-- field). p_contacts must be a JSON array of at most 5 objects
-- {name, contact, role}; entries with a blank name AND blank contact are
-- dropped, an entry with a contact or role needs a name, and only those
-- three keys are kept.

create or replace function public.save_my_recovery_plan(
  p_warning_signs text,
  p_what_helps text,
  p_reasons_for_recovery text,
  p_step_1 text,
  p_step_2 text,
  p_step_3 text,
  p_contacts jsonb
)
returns table (warning_signs text, what_helps text, reasons_for_recovery text,
               step_1 text, step_2 text, step_3 text, contacts jsonb,
               created_at timestamptz, updated_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  v_warn text := nullif(btrim(coalesce(p_warning_signs, '')), '');
  v_help text := nullif(btrim(coalesce(p_what_helps, '')), '');
  v_why text := nullif(btrim(coalesce(p_reasons_for_recovery, '')), '');
  v_s1 text := nullif(btrim(coalesce(p_step_1, '')), '');
  v_s2 text := nullif(btrim(coalesce(p_step_2, '')), '');
  v_s3 text := nullif(btrim(coalesce(p_step_3, '')), '');
  v_contacts jsonb := '[]'::jsonb;
  c jsonb;
  c_name text; c_contact text; c_role text;
begin
  if caller_id is null then
    raise exception 'Sign in required to use My Recovery Plan.' using errcode = '42501';
  end if;
  if char_length(v_warn) > 750 or char_length(v_help) > 750 or char_length(v_why) > 750 then
    raise exception 'Each section can be up to 750 characters.' using errcode = '22023';
  end if;
  if char_length(v_s1) > 150 or char_length(v_s2) > 150 or char_length(v_s3) > 150 then
    raise exception 'Each step can be up to 150 characters.' using errcode = '22023';
  end if;
  if p_contacts is not null and jsonb_typeof(p_contacts) <> 'array' then
    raise exception 'Contacts must be a list.' using errcode = '22023';
  end if;
  if p_contacts is not null and jsonb_array_length(p_contacts) > 5 then
    raise exception 'You can add up to 5 people.' using errcode = '22023';
  end if;

  for c in select value from jsonb_array_elements(coalesce(p_contacts, '[]'::jsonb)) loop
    if jsonb_typeof(c) <> 'object' then
      raise exception 'Each contact must be an entry.' using errcode = '22023';
    end if;
    c_name := nullif(btrim(coalesce(c->>'name', '')), '');
    c_contact := nullif(btrim(coalesce(c->>'contact', '')), '');
    c_role := nullif(btrim(coalesce(c->>'role', '')), '');
    if c_name is null and c_contact is null and c_role is null then
      continue;
    end if;
    if c_name is null then
      raise exception 'Each person needs a name or label.' using errcode = '22023';
    end if;
    if char_length(c_name) > 80 or char_length(c_contact) > 120 or char_length(c_role) > 60 then
      raise exception 'A contact entry is too long.' using errcode = '22023';
    end if;
    v_contacts := v_contacts || jsonb_build_array(jsonb_build_object('name', c_name, 'contact', c_contact, 'role', c_role));
  end loop;

  insert into public.recovery_plans as p
    (user_id, warning_signs, what_helps, reasons_for_recovery, step_1, step_2, step_3, contacts)
  values (caller_id, v_warn, v_help, v_why, v_s1, v_s2, v_s3, v_contacts)
  on conflict (user_id) do update
    set warning_signs = excluded.warning_signs,
        what_helps = excluded.what_helps,
        reasons_for_recovery = excluded.reasons_for_recovery,
        step_1 = excluded.step_1,
        step_2 = excluded.step_2,
        step_3 = excluded.step_3,
        contacts = excluded.contacts,
        updated_at = now();

  return query
    select p.warning_signs, p.what_helps, p.reasons_for_recovery,
           p.step_1, p.step_2, p.step_3, p.contacts, p.created_at, p.updated_at
    from public.recovery_plans p
    where p.user_id = caller_id;
end;
$$;

revoke all on function public.save_my_recovery_plan(text, text, text, text, text, text, jsonb) from public, anon;
grant execute on function public.save_my_recovery_plan(text, text, text, text, text, text, jsonb) to authenticated;
