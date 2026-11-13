-- online_orders <-> delivery_jobs policies referenced each other (infinite recursion).
-- Break the loop with security-definer lookups that read the other table without RLS.
create or replace function public._rider_has_order(p_order uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.delivery_jobs j where j.order_id = p_order and j.rider_id = auth.uid());
$$;
create or replace function public._order_in_my_org(p_order uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.online_orders o where o.id = p_order and o.org_id = public.current_org_id());
$$;
revoke all on function public._rider_has_order(uuid), public._order_in_my_org(uuid) from public, anon;
grant execute on function public._rider_has_order(uuid), public._order_in_my_org(uuid) to authenticated;

drop policy if exists online_orders_rider on public.online_orders;
create policy online_orders_rider on public.online_orders for select using (public._rider_has_order(id));
drop policy if exists delivery_jobs_shop on public.delivery_jobs;
create policy delivery_jobs_shop on public.delivery_jobs for select using (public._order_in_my_org(order_id));
