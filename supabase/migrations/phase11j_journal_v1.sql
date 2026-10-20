-- ============================================================
-- Phase 11J: Journal v1 (private freeform journal)
-- ============================================================
-- The member's own freeform writing. Private only: no sharing, export,
-- analysis, or Community/profile/notification connection.
--
--   - recovery_journal_entries: entry_date (not future, from 1900), an
--     optional title (up to 120), a body (1-5000) and up to 5 private tags
--     (each up to 30; trimmed, blanks dropped, case-insensitive
--     duplicates removed). Removing an entry sets removed_at (soft remove,
--     like the other recovery features; no DELETE).
--   - Reads are bounded: lists return pages of at most 50 with a short
--     preview; the full body comes only from get_my_journal_entry; search
--     runs in the database and returns at most 50 matches.
--
-- Rules, same as 11A-11I: RLS on, no policies, no table privileges for
-- public/anon/authenticated; members use only the RPCs below, which act
-- on auth.uid()'s rows and never return user_id. Entry ids are random
-- UUIDs used only for the owner's own reads/edits. Additive only.
-- ============================================================


create table public.recovery_journal_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  entry_date date not null,
  title text,
  body text not null,
  tags text[] not null default '{}',
  removed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint recovery_journal_title_check check (title is null or char_length(title) between 1 and 120),
  constraint recovery_journal_body_check check (char_length(body) between 1 and 5000),
  constraint recovery_journal_tags_check check (cardinality(tags) <= 5)
);

create index recovery_journal_user_date_idx on public.recovery_journal_entries (user_id, entry_date desc, created_at desc);

alter table public.recovery_journal_entries enable row level security;
revoke all on table public.recovery_journal_entries from public, anon, authenticated;


-- ---------- list_my_journal_entries ----------
-- Newest first, a page of at most 50, optionally only entries with a tag
-- (case-insensitive). Returns a preview (first 200 characters), never the
-- full body.

create or replace function public.list_my_journal_entries(p_limit integer, p_offset integer, p_tag text)
returns table (id uuid, entry_date date, title text, preview text, tags text[],
               created_at timestamptz, updated_at timestamptz, edited boolean)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  v_tag text := nullif(lower(btrim(coalesce(p_tag, ''))), '');
begin
  if caller_id is null then
    raise exception 'Sign in required to use your Journal.' using errcode = '42501';
  end if;

  return query
    select e.id, e.entry_date, e.title, left(e.body, 200), e.tags, e.created_at, e.updated_at,
           e.updated_at > e.created_at
    from public.recovery_journal_entries e
    where e.user_id = caller_id and e.removed_at is null
      and (v_tag is null or exists (select 1 from unnest(e.tags) t where lower(t) = v_tag))
    order by e.entry_date desc, e.created_at desc
    limit least(greatest(coalesce(p_limit, 20), 1), 50)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

revoke all on function public.list_my_journal_entries(integer, integer, text) from public, anon;
grant execute on function public.list_my_journal_entries(integer, integer, text) to authenticated;


-- ---------- get_my_journal_entry ----------

create or replace function public.get_my_journal_entry(p_id uuid)
returns table (id uuid, entry_date date, title text, body text, tags text[],
               created_at timestamptz, updated_at timestamptz, edited boolean)
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
    raise exception 'Sign in required to use your Journal.' using errcode = '42501';
  end if;

  return query
    select e.id, e.entry_date, e.title, e.body, e.tags, e.created_at, e.updated_at,
           e.updated_at > e.created_at
    from public.recovery_journal_entries e
    where e.id = p_id and e.user_id = caller_id and e.removed_at is null;
  if not found then
    raise exception 'Entry not found.' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.get_my_journal_entry(uuid) from public, anon;
grant execute on function public.get_my_journal_entry(uuid) to authenticated;


-- ---------- search_my_journal ----------
-- Case-insensitive substring search over title, body and tags (so
-- partial words match). The query is matched literally (% and _ have no
-- special meaning). At most 50 results, newest first, preview only.

create or replace function public.search_my_journal(p_query text, p_limit integer)
returns table (id uuid, entry_date date, title text, preview text, tags text[],
               created_at timestamptz, updated_at timestamptz, edited boolean)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  v_q text := btrim(coalesce(p_query, ''));
  v_pat text;
begin
  if caller_id is null then
    raise exception 'Sign in required to use your Journal.' using errcode = '42501';
  end if;
  if char_length(v_q) < 1 or char_length(v_q) > 100 then
    raise exception 'Search for 1 to 100 characters.' using errcode = '22023';
  end if;
  v_pat := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';

  return query
    select e.id, e.entry_date, e.title, left(e.body, 200), e.tags, e.created_at, e.updated_at,
           e.updated_at > e.created_at
    from public.recovery_journal_entries e
    where e.user_id = caller_id and e.removed_at is null
      and (e.title ilike v_pat or e.body ilike v_pat or array_to_string(e.tags, ' ') ilike v_pat)
    order by e.entry_date desc, e.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 50);
end;
$$;

revoke all on function public.search_my_journal(text, integer) from public, anon;
grant execute on function public.search_my_journal(text, integer) to authenticated;


-- ---------- save_my_journal_entry ----------
-- p_id null creates an entry; otherwise edits the caller's own,
-- not-removed entry. entry_date: from 1900, at most one day past the
-- server's UTC date (time zones).

create or replace function public.save_my_journal_entry(
  p_id uuid,
  p_entry_date date,
  p_title text,
  p_body text,
  p_tags text[]
)
returns table (id uuid, entry_date date, title text, body text, tags text[],
               created_at timestamptz, updated_at timestamptz, edited boolean)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  caller_id uuid := auth.uid();
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_body text := btrim(coalesce(p_body, ''), E' \t\r\n');
  v_tags text[] := '{}';
  t text;
  v_id uuid;
begin
  if caller_id is null then
    raise exception 'Sign in required to use your Journal.' using errcode = '42501';
  end if;
  if char_length(v_body) < 1 then
    raise exception 'Write something before saving.' using errcode = '22023';
  end if;
  if char_length(v_body) > 5000 then
    raise exception 'Entries can be up to 5,000 characters.' using errcode = '22023';
  end if;
  if char_length(v_title) > 120 then
    raise exception 'Titles can be up to 120 characters.' using errcode = '22023';
  end if;
  if p_entry_date is null or p_entry_date > (now() at time zone 'utc')::date + 1 or p_entry_date < date '1900-01-01' then
    raise exception 'Choose a date that isn''t in the future.' using errcode = '22023';
  end if;

  foreach t in array coalesce(p_tags, '{}'::text[]) loop
    t := btrim(coalesce(t, ''));
    continue when t = '';
    if char_length(t) > 30 then
      raise exception 'Tags can be up to 30 characters.' using errcode = '22023';
    end if;
    continue when exists (select 1 from unnest(v_tags) x where lower(x) = lower(t));
    v_tags := v_tags || t;
  end loop;
  if cardinality(v_tags) > 5 then
    raise exception 'You can use up to 5 tags.' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.recovery_journal_entries (user_id, entry_date, title, body, tags)
    values (caller_id, p_entry_date, v_title, v_body, v_tags)
    returning recovery_journal_entries.id into v_id;
  else
    update public.recovery_journal_entries e
    set entry_date = p_entry_date, title = v_title, body = v_body, tags = v_tags, updated_at = now()
    where e.id = p_id and e.user_id = caller_id and e.removed_at is null
    returning e.id into v_id;
    if v_id is null then
      raise exception 'Entry not found.' using errcode = 'P0002';
    end if;
  end if;

  return query
    select e.id, e.entry_date, e.title, e.body, e.tags, e.created_at, e.updated_at,
           e.updated_at > e.created_at
    from public.recovery_journal_entries e
    where e.id = v_id;
end;
$$;

revoke all on function public.save_my_journal_entry(uuid, date, text, text, text[]) from public, anon;
grant execute on function public.save_my_journal_entry(uuid, date, text, text, text[]) to authenticated;


-- ---------- remove_my_journal_entry ----------

create or replace function public.remove_my_journal_entry(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'Sign in required to use your Journal.' using errcode = '42501';
  end if;

  update public.recovery_journal_entries e
  set removed_at = now(), updated_at = now()
  where e.id = p_id and e.user_id = caller_id and e.removed_at is null;
  if not found then
    raise exception 'Entry not found.' using errcode = 'P0002';
  end if;
  return true;
end;
$$;

revoke all on function public.remove_my_journal_entry(uuid) from public, anon;
grant execute on function public.remove_my_journal_entry(uuid) to authenticated;
