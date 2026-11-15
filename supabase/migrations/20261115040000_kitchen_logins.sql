-- Kitchen logins for NYANSATEK Restaurant (nyansatek.rest).
-- A 'kitchen' login belongs to a restaurant like a cashier does, but is only for the kitchen screen:
-- it can read the restaurant's orders and move a ticket along (New -> Preparing -> Ready -> Served),
-- and nothing else. Shops are not affected: no shop login has this role.

-- ---------- the role ---------------------------------------------------
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('master', 'admin', 'cashier', 'market_ops', 'kitchen'));

create or replace function public.is_kitchen()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select role = 'kitchen' from public.profiles where id = auth.uid()), false);
$$;
grant execute on function public.is_kitchen() to authenticated;

-- ---------- nobody may change their own role or business --------------
-- The profiles update policy lets a signed-in person update their own row (the app uses it to clear
-- "must change password"). Without this guard that also allowed changing one's own role, which
-- would let a cashier or kitchen login promote itself. Roles now change only through the master
-- console, the service key (checkout, create-cashier) or set_staff_role() below.
create or replace function public.protect_profile_role()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (new.role, new.org_id) is distinct from (old.role, old.org_id)
     and coalesce(auth.role(), '') in ('authenticated', 'anon')
     and not public.is_master()
     and coalesce(current_setting('app.role_change_ok', true), '') <> '1' then
    raise exception 'Your role can only be changed by the business owner.';
  end if;
  return new;
end $$;
drop trigger if exists trg_protect_profile_role on public.profiles;
create trigger trg_protect_profile_role before update on public.profiles
  for each row execute function public.protect_profile_role();

-- ---------- the owner switches a staff login between Cashier and Kitchen
-- Logins are still created and deleted by the create-cashier / delete-cashier functions, which
-- only know 'cashier'. The app creates a cashier and then calls this to make it a kitchen login
-- (and switches it back just before deleting).
create or replace function public.set_staff_role(p_staff uuid, p_role text)
returns void language plpgsql security definer set search_path = '' as $$
declare me public.profiles%rowtype; them public.profiles%rowtype;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or me.role not in ('admin', 'master') then
    raise exception 'Only the business owner can change a staff login.';
  end if;
  if p_role not in ('cashier', 'kitchen') then
    raise exception 'A staff login is either cashier or kitchen.';
  end if;
  select * into them from public.profiles where id = p_staff;
  if them.id is null or them.role not in ('cashier', 'kitchen')
     or (me.role <> 'master' and them.org_id is distinct from me.org_id) then
    raise exception 'That staff login does not belong to your business.';
  end if;
  if p_role = 'kitchen' and not exists (select 1 from public.organizations o where o.id = them.org_id and o.vertical = 'food') then
    raise exception 'Kitchen logins are for restaurants.';
  end if;
  perform set_config('app.role_change_ok', '1', true);
  update public.profiles set role = p_role where id = p_staff;
  perform set_config('app.role_change_ok', '', true);
end $$;
revoke execute on function public.set_staff_role(uuid, text) from public, anon;
grant execute on function public.set_staff_role(uuid, text) to authenticated;

-- ---------- kitchen logins sign in with their staff username too ------
create or replace function public.resolve_login_email(p_login text)
returns text language plpgsql stable security definer set search_path = '' as $$
declare v text := lower(trim(coalesce(p_login, ''))); r text[];
begin
  if v = '' or length(v) > 120 then return null; end if;
  select array_agg(l.login_email) into r from public.login_lookup l where lower(trim(l.business_name)) = v;
  if coalesce(array_length(r, 1), 0) = 1 then return r[1]; end if;
  if coalesce(array_length(r, 1), 0) > 1 then return null; end if;
  select array_agg(u.email::text) into r
    from public.profiles p join auth.users u on u.id = p.id
   where p.role in ('cashier', 'kitchen') and p.is_active = true and lower(trim(p.login_username)) = v;
  if coalesce(array_length(r, 1), 0) = 1 then return r[1]; end if;
  return null;
end $$;

-- ---------- what a kitchen login may touch -----------------------------
-- Every tenant table already lets any login of the business read and write its rows. These
-- RESTRICTIVE policies sit on top and only ever say "not a kitchen login", so they change nothing
-- for owners, cashiers, the master console, marketplace customers or riders.
--   sales       read; update (the trigger below limits that to the kitchen status); no insert or delete
--   sale_items  read only
--   profiles, organizations, org_branding   left as they are (own profile, business name, logo)
--   everything else                         no access
do $$
declare t record;
begin
  for t in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
       and c.relname not in ('profiles', 'organizations', 'org_branding', 'sales', 'sale_items')
  loop
    execute format('drop policy if exists no_kitchen_access on public.%I', t.relname);
    execute format('create policy no_kitchen_access on public.%I as restrictive for all to authenticated using (not (select public.is_kitchen())) with check (not (select public.is_kitchen()))', t.relname);
  end loop;
end $$;

drop policy if exists no_kitchen_insert on public.sales;
create policy no_kitchen_insert on public.sales as restrictive for insert to authenticated with check (not (select public.is_kitchen()));
drop policy if exists no_kitchen_delete on public.sales;
create policy no_kitchen_delete on public.sales as restrictive for delete to authenticated using (not (select public.is_kitchen()));
drop policy if exists no_kitchen_insert on public.sale_items;
create policy no_kitchen_insert on public.sale_items as restrictive for insert to authenticated with check (not (select public.is_kitchen()));
drop policy if exists no_kitchen_update on public.sale_items;
create policy no_kitchen_update on public.sale_items as restrictive for update to authenticated using (not (select public.is_kitchen()));
drop policy if exists no_kitchen_delete on public.sale_items;
create policy no_kitchen_delete on public.sale_items as restrictive for delete to authenticated using (not (select public.is_kitchen()));

-- A kitchen login may move a ticket along, and change nothing else about an order.
create or replace function public.kitchen_updates_status_only()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if public.is_kitchen()
     and (to_jsonb(new) - 'kitchen_status' - 'kitchen_updated_at') is distinct from (to_jsonb(old) - 'kitchen_status' - 'kitchen_updated_at') then
    raise exception 'The kitchen screen can only move an order along.';
  end if;
  return new;
end $$;
drop trigger if exists trg_kitchen_status_only on public.sales;
create trigger trg_kitchen_status_only before update on public.sales
  for each row execute function public.kitchen_updates_status_only();
