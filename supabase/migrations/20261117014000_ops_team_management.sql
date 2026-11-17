-- Team accounts for the nyansatek.store team dashboard: only the master account manages them.
create or replace function public.ops_is_master() returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select role = 'master' and coalesce(is_active, true) from public.profiles where id = auth.uid()), false);
$$;
create or replace function public.ops_team_list() returns table(id uuid, full_name text, email text, is_active boolean, must_change_password boolean, created_at timestamptz, last_sign_in_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.ops_is_master() then raise exception 'Only the NYANSATEK master account can manage team members'; end if;
  return query select p.id, coalesce(p.full_name, p.display_name, u.email::text), u.email::text, coalesce(p.is_active, true), coalesce(p.must_change_password, false), u.created_at, u.last_sign_in_at
    from public.profiles p join auth.users u on u.id = p.id where p.role = 'market_ops' order by u.created_at;
end $$;
create or replace function public.ops_team_set_active(p_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.ops_is_master() then raise exception 'Only the NYANSATEK master account can manage team members'; end if;
  update public.profiles set is_active = p_active where id = p_id and role = 'market_ops';
  if not found then raise exception 'Team member not found'; end if;
end $$;
create or replace function public.ops_password_changed() returns void
language sql security definer set search_path = '' as $$
  update public.profiles set must_change_password = false where id = auth.uid() and role = 'market_ops';
$$;
revoke execute on function public.ops_is_master(), public.ops_team_list(), public.ops_team_set_active(uuid, boolean), public.ops_password_changed() from public, anon;
grant execute on function public.ops_is_master(), public.ops_team_list(), public.ops_team_set_active(uuid, boolean), public.ops_password_changed() to authenticated;
