-- ============================================================
-- Phase 6B: Community comments, one-level replies, and member
-- reporting
-- ============================================================

create table public.community_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.community_posts (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  parent_comment_id uuid references public.community_comments (id) on delete cascade,
  body text not null,
  status text not null default 'published',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  edited_at timestamptz,
  moderated_at timestamptz,
  moderated_by uuid references public.admin_users (user_id)
);

alter table public.community_comments
  add constraint community_comments_status_check
  check (status in ('published', 'hidden', 'removed'));

alter table public.community_comments
  add constraint community_comments_body_check
  check (char_length(btrim(body)) > 0 and char_length(body) <= 1000);

alter table public.community_comments
  add constraint community_comments_not_self_parent_check
  check (parent_comment_id is null or parent_comment_id <> id);

create index community_comments_post_id_idx on public.community_comments (post_id);
create index community_comments_parent_comment_id_idx on public.community_comments (parent_comment_id);
create index community_comments_user_id_idx on public.community_comments (user_id);

alter table public.community_comments enable row level security;

create policy "community_comments_select"
  on public.community_comments for select
  using (public.is_admin());

revoke all on table public.community_comments from anon, authenticated;
grant select on table public.community_comments to authenticated;

create or replace function public.list_my_community_comments()
returns setof public.community_comments
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select *
  from public.community_comments
  where user_id = auth.uid()
  order by created_at desc;
$$;

revoke execute on function public.list_my_community_comments from public;
revoke execute on function public.list_my_community_comments from anon;
grant execute on function public.list_my_community_comments to authenticated;

create view public.community_comments_public as
select
  cc.id,
  cc.post_id,
  cc.parent_comment_id,
  cc.body,
  cc.created_at,
  cc.updated_at,
  cc.edited_at,
  coalesce(pr.display_name, 'Community member') as display_name
from public.community_comments cc
join public.community_posts cp on cp.id = cc.post_id and cp.status = 'published'
left join public.community_comments parent on parent.id = cc.parent_comment_id
left join public.profiles pr on pr.id = cc.user_id
where cc.status = 'published'
  and (
    cc.parent_comment_id is null
    or (parent.status = 'published' and parent.parent_comment_id is null)
  );

revoke all on public.community_comments_public from anon, authenticated;
grant select on public.community_comments_public to anon, authenticated;

create or replace function public.create_community_comment(
  p_post_id uuid,
  p_body text
)
returns public.community_comments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  post_row public.community_posts;
  result_row public.community_comments;
begin
  if caller_id is null then
    raise exception 'Sign in required to comment.' using errcode = '42501';
  end if;

  if p_body is null or char_length(btrim(p_body)) = 0 then
    raise exception 'Comment text is required.' using errcode = '22023';
  end if;
  if char_length(p_body) > 1000 then
    raise exception 'Comment text must be 1,000 characters or fewer.' using errcode = '22023';
  end if;

  select * into post_row from public.community_posts where id = p_post_id;
  if post_row.id is null then
    raise exception 'Post not found.' using errcode = 'P0002';
  end if;
  if post_row.status <> 'published' then
    raise exception 'This post is no longer available for comments.' using errcode = '22023';
  end if;

  insert into public.community_comments (post_id, user_id, parent_comment_id, body, status)
  values (p_post_id, caller_id, null, btrim(p_body), 'published')
  returning * into result_row;

  return result_row;
end;
$$;

revoke execute on function public.create_community_comment from public;
revoke execute on function public.create_community_comment from anon;
grant execute on function public.create_community_comment to authenticated;

create or replace function public.create_community_reply(
  p_post_id uuid,
  p_parent_comment_id uuid,
  p_body text
)
returns public.community_comments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  post_row public.community_posts;
  parent_row public.community_comments;
  result_row public.community_comments;
begin
  if caller_id is null then
    raise exception 'Sign in required to reply.' using errcode = '42501';
  end if;

  if p_body is null or char_length(btrim(p_body)) = 0 then
    raise exception 'Reply text is required.' using errcode = '22023';
  end if;
  if char_length(p_body) > 1000 then
    raise exception 'Reply text must be 1,000 characters or fewer.' using errcode = '22023';
  end if;

  select * into post_row from public.community_posts where id = p_post_id;
  if post_row.id is null then
    raise exception 'Post not found.' using errcode = 'P0002';
  end if;
  if post_row.status <> 'published' then
    raise exception 'This post is no longer available for replies.' using errcode = '22023';
  end if;

  select * into parent_row from public.community_comments where id = p_parent_comment_id for update;
  if parent_row.id is null then
    raise exception 'Comment not found.' using errcode = 'P0002';
  end if;
  if parent_row.post_id <> p_post_id then
    raise exception 'That comment does not belong to this post.' using errcode = '22023';
  end if;
  if parent_row.parent_comment_id is not null then
    raise exception 'Replies can only be made to a top-level comment.' using errcode = '22023';
  end if;
  if parent_row.status <> 'published' then
    raise exception 'This comment is no longer available for replies.' using errcode = '22023';
  end if;

  insert into public.community_comments (post_id, user_id, parent_comment_id, body, status)
  values (p_post_id, caller_id, p_parent_comment_id, btrim(p_body), 'published')
  returning * into result_row;

  return result_row;
end;
$$;

revoke execute on function public.create_community_reply from public;
revoke execute on function public.create_community_reply from anon;
grant execute on function public.create_community_reply to authenticated;

create or replace function public.edit_community_comment(
  p_comment_id uuid,
  p_body text
)
returns public.community_comments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  current_row public.community_comments;
  result_row public.community_comments;
begin
  if caller_id is null then
    raise exception 'Sign in required to edit a comment.' using errcode = '42501';
  end if;

  select * into current_row from public.community_comments where id = p_comment_id for update;
  if current_row.id is null then
    raise exception 'Comment not found.' using errcode = 'P0002';
  end if;

  if current_row.user_id <> caller_id then
    raise exception 'You may only edit your own comment.' using errcode = '42501';
  end if;

  if current_row.status <> 'published' then
    raise exception 'A % comment cannot be edited.', current_row.status
      using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.community_posts
    where id = current_row.post_id and status = 'published'
  ) then
    raise exception 'The post this comment belongs to is no longer available.' using errcode = '22023';
  end if;

  if p_body is null or char_length(btrim(p_body)) = 0 then
    raise exception 'Comment text is required.' using errcode = '22023';
  end if;
  if char_length(p_body) > 1000 then
    raise exception 'Comment text must be 1,000 characters or fewer.' using errcode = '22023';
  end if;

  update public.community_comments
    set body = btrim(p_body), updated_at = now(), edited_at = now()
    where id = p_comment_id
    returning * into result_row;

  return result_row;
end;
$$;

revoke execute on function public.edit_community_comment from public;
revoke execute on function public.edit_community_comment from anon;
grant execute on function public.edit_community_comment to authenticated;

create or replace function public.moderate_community_comment(
  p_comment_id uuid,
  p_action text
)
returns public.community_comments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  admin_id uuid := auth.uid();
  current_row public.community_comments;
  result_row public.community_comments;
begin
  if admin_id is null or not public.is_admin() then
    raise exception 'Only an authenticated admin may moderate community comments.'
      using errcode = '42501';
  end if;

  select * into current_row from public.community_comments where id = p_comment_id for update;
  if current_row.id is null then
    raise exception 'Comment not found.' using errcode = 'P0002';
  end if;

  if p_action = 'hide' then
    if current_row.status <> 'published' then
      raise exception 'Only a published comment can be hidden (current status: %).', current_row.status
        using errcode = '22023';
    end if;
    update public.community_comments
      set status = 'hidden', moderated_at = now(), moderated_by = admin_id
      where id = p_comment_id
      returning * into result_row;

  elsif p_action = 'restore' then
    if current_row.status <> 'hidden' then
      raise exception 'Only a hidden comment can be restored (current status: %).', current_row.status
        using errcode = '22023';
    end if;
    update public.community_comments
      set status = 'published', moderated_at = now(), moderated_by = admin_id
      where id = p_comment_id
      returning * into result_row;

  elsif p_action = 'remove' then
    if current_row.status not in ('published', 'hidden') then
      raise exception 'A % comment cannot be removed.', current_row.status
        using errcode = '22023';
    end if;
    update public.community_comments
      set status = 'removed', moderated_at = now(), moderated_by = admin_id
      where id = p_comment_id
      returning * into result_row;

  else
    raise exception 'Unknown moderation action: %', p_action using errcode = '22023';
  end if;

  return result_row;
end;
$$;

revoke execute on function public.moderate_community_comment from public;
revoke execute on function public.moderate_community_comment from anon;
revoke execute on function public.moderate_community_comment from authenticated;
grant execute on function public.moderate_community_comment to authenticated;

create table public.community_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_user_id uuid not null references auth.users (id) on delete cascade,
  post_id uuid references public.community_posts (id) on delete cascade,
  comment_id uuid references public.community_comments (id) on delete cascade,
  reason text not null,
  details text,
  status text not null default 'open',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.admin_users (user_id)
);

alter table public.community_reports
  add constraint community_reports_exactly_one_target_check
  check ((post_id is not null and comment_id is null) or (post_id is null and comment_id is not null));

alter table public.community_reports
  add constraint community_reports_reason_check
  check (reason in ('harassment', 'hate_or_abuse', 'dangerous_content', 'spam', 'privacy', 'other'));

alter table public.community_reports
  add constraint community_reports_details_check
  check (details is null or char_length(details) <= 500);

alter table public.community_reports
  add constraint community_reports_status_check
  check (status in ('open', 'resolved', 'dismissed'));

create index community_reports_post_id_idx on public.community_reports (post_id);
create index community_reports_comment_id_idx on public.community_reports (comment_id);

alter table public.community_reports enable row level security;

create policy "community_reports_select"
  on public.community_reports for select
  using (public.is_admin());

revoke all on table public.community_reports from anon, authenticated;
grant select on table public.community_reports to authenticated;

create or replace function public.report_community_content(
  p_reason text,
  p_post_id uuid default null,
  p_comment_id uuid default null,
  p_details text default null
)
returns public.community_reports
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := auth.uid();
  result_row public.community_reports;
  existing_open_id uuid;
begin
  if caller_id is null then
    raise exception 'Sign in required to report content.' using errcode = '42501';
  end if;

  if (p_post_id is null) = (p_comment_id is null) then
    raise exception 'Exactly one of a post or a comment must be reported.' using errcode = '22023';
  end if;

  if p_reason not in ('harassment', 'hate_or_abuse', 'dangerous_content', 'spam', 'privacy', 'other') then
    raise exception 'Invalid report reason: %', p_reason using errcode = '22023';
  end if;

  if p_details is not null and char_length(p_details) > 500 then
    raise exception 'Report details must be 500 characters or fewer.' using errcode = '22023';
  end if;

  if p_post_id is not null then
    if not exists (select 1 from public.community_posts where id = p_post_id) then
      raise exception 'Post not found.' using errcode = 'P0002';
    end if;
  else
    if not exists (select 1 from public.community_comments where id = p_comment_id) then
      raise exception 'Comment not found.' using errcode = 'P0002';
    end if;
  end if;

  select id into existing_open_id
  from public.community_reports
  where reporter_user_id = caller_id
    and status = 'open'
    and (
      (p_post_id is not null and post_id = p_post_id)
      or (p_comment_id is not null and comment_id = p_comment_id)
    )
  limit 1;

  if existing_open_id is not null then
    raise exception 'You already have an open report for this content.' using errcode = '23505';
  end if;

  insert into public.community_reports (
    reporter_user_id, post_id, comment_id, reason, details, status
  ) values (
    caller_id, p_post_id, p_comment_id, p_reason,
    case when p_details is null then null else btrim(p_details) end,
    'open'
  )
  returning * into result_row;

  return result_row;
end;
$$;

revoke execute on function public.report_community_content from public;
revoke execute on function public.report_community_content from anon;
grant execute on function public.report_community_content to authenticated;

create or replace function public.moderate_community_report(
  p_report_id uuid,
  p_action text
)
returns public.community_reports
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  admin_id uuid := auth.uid();
  current_row public.community_reports;
  result_row public.community_reports;
begin
  if admin_id is null or not public.is_admin() then
    raise exception 'Only an authenticated admin may act on reports.' using errcode = '42501';
  end if;

  select * into current_row from public.community_reports where id = p_report_id for update;
  if current_row.id is null then
    raise exception 'Report not found.' using errcode = 'P0002';
  end if;

  if current_row.status <> 'open' then
    raise exception 'Only an open report can be resolved or dismissed (current status: %).', current_row.status
      using errcode = '22023';
  end if;

  if p_action = 'resolve' then
    update public.community_reports
      set status = 'resolved', reviewed_at = now(), reviewed_by = admin_id
      where id = p_report_id
      returning * into result_row;

  elsif p_action = 'dismiss' then
    update public.community_reports
      set status = 'dismissed', reviewed_at = now(), reviewed_by = admin_id
      where id = p_report_id
      returning * into result_row;

  else
    raise exception 'Unknown report action: %', p_action using errcode = '22023';
  end if;

  return result_row;
end;
$$;

revoke execute on function public.moderate_community_report from public;
revoke execute on function public.moderate_community_report from anon;
revoke execute on function public.moderate_community_report from authenticated;
grant execute on function public.moderate_community_report to authenticated;
