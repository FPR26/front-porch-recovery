-- ============================================================
-- Phase 11K: Recovery History v1 (one read-only metadata helper)
-- ============================================================
-- Recovery History is a long-term, private view built from records the
-- member already has. It stores NOTHING new (no table). The existing
-- list RPCs are bounded to short ranges or return text (journal
-- previews, review reflections, win notes), so this adds one read-only
-- helper that returns dated METADATA for a range of up to 366 days:
--
--   kind        event_date   other columns
--   'log'       log_date     mood, cravings            (no notes)
--   'reflection' date        has_morning, has_evening  (no text)
--   'support'   occurrence   label = item name, category (completed only)
--   'journal'   entry_date   (nothing else: no title, body or tags)
--   'review'    week_start   (non-empty reviews only; no text)
--   'win'       win_date     label = win title (no note)
--
-- Same rules as 11A-11J: security definer, search_path public,pg_temp,
-- authenticated only, scoped to auth.uid(), never returns user_id or
-- private text. Removed journal entries / wins are excluded. Additive
-- only: no table, no change to existing objects.
-- ============================================================

create or replace function public.list_my_history_events(p_from date, p_to date)
returns table (kind text, event_date date, mood smallint, cravings smallint,
               has_morning boolean, has_evening boolean, label text, category text)
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
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'Choose a range of up to 366 days.' using errcode = '22023';
  end if;

  return query
    select * from (
      select 'log'::text, l.log_date, l.mood, l.cravings, null::boolean, null::boolean, null::text, null::text
      from public.recovery_daily_logs l
      where l.user_id = caller_id and l.log_date between p_from and p_to
      union all
      select 'reflection', r.reflection_date, null, null, r.morning_text is not null, r.evening_text is not null, null, null
      from public.recovery_daily_reflections r
      where r.user_id = caller_id and r.reflection_date between p_from and p_to
        and (r.morning_text is not null or r.evening_text is not null)
      union all
      select 'support', c.occurrence_date, null, null, null, null, i.name, i.category
      from public.recovery_support_checkins c
      join public.recovery_support_items i on i.id = c.item_id and i.user_id = caller_id
      where c.user_id = caller_id and c.completed and c.occurrence_date between p_from and p_to
      union all
      select 'journal', j.entry_date, null, null, null, null, null, null
      from public.recovery_journal_entries j
      where j.user_id = caller_id and j.removed_at is null and j.entry_date between p_from and p_to
      union all
      select 'review', w.week_start, null, null, null, null, null, null
      from public.recovery_weekly_reviews w
      where w.user_id = caller_id and w.week_start between p_from and p_to
        and (w.went_well is not null or w.was_hard is not null or w.what_helped is not null or w.next_week_intention is not null)
      union all
      select 'win', x.win_date, null, null, null, null, x.title, null
      from public.recovery_wins x
      where x.user_id = caller_id and x.removed_at is null and x.win_date between p_from and p_to
    ) ev
    order by 2, 1
    limit 10000;
end;
$$;

revoke all on function public.list_my_history_events(date, date) from public, anon;
grant execute on function public.list_my_history_events(date, date) to authenticated;
