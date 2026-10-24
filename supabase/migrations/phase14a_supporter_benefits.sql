-- Read only the caller's access metadata, never private workbook answers.
begin;
create function public.get_my_supporter_benefits()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'Sign in required.' using errcode='42501';end if;
  return public.supporter_workbook_entitlement();
end;
$$;
revoke all on function public.get_my_supporter_benefits() from public,anon,authenticated;
grant execute on function public.get_my_supporter_benefits() to authenticated;
commit;
