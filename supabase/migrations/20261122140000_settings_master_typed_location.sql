-- 1) Only the master login can change market settings (MoMo account, markups, alert phone).
--    Team members can still read them (the Orders tab needs the MoMo details).
drop policy if exists market_settings_ops on public.market_settings;
drop policy if exists market_settings_ops_read on public.market_settings;
drop policy if exists market_settings_master_write on public.market_settings;
create policy market_settings_ops_read on public.market_settings for select using (public.is_market_ops());
create policy market_settings_master_write on public.market_settings for all
  using (public.is_master()) with check (public.is_master());

-- 2) Customers type their delivery location instead of choosing a listed area.
--    The typed location is stored in online_orders.address (already shown to the team, the rider,
--    in SMS and on the tracking page). A listed zone is still accepted if one is sent.
do $$
declare d text;
  old_block text := $o$    begin v_zone := (p ->> 'zone_id')::uuid; exception when invalid_text_representation then v_zone := null; end;
    if v_zone is null or not exists (select 1 from public.delivery_zones where id = v_zone and active) then
      raise exception 'Choose your delivery area'; end if;
    v_addr := btrim(coalesce(p ->> 'address', ''));$o$;
  new_block text := $n$    begin v_zone := (p ->> 'zone_id')::uuid; exception when invalid_text_representation then v_zone := null; end;
    if v_zone is not null and not exists (select 1 from public.delivery_zones where id = v_zone and active) then v_zone := null; end if;
    v_addr := btrim(coalesce(p ->> 'address', ''));
    if v_zone is null and v_addr = '' then raise exception 'Enter your delivery location'; end if;$n$;
begin
  d := pg_get_functiondef('public.place_online_order'::regproc);
  if position(new_block in d) > 0 then return; end if;
  if position(old_block in d) = 0 then raise exception 'place_online_order zone block not found'; end if;
  execute replace(d, old_block, new_block);
end $$;

-- A delivery order needs a listed zone or a typed location.
alter table public.online_orders drop constraint if exists online_orders_check;
alter table public.online_orders add constraint online_orders_check check (
  (fulfilment = 'delivery' and address is not null and (zone_id is not null or btrim(address) <> ''))
  or (fulfilment = 'pickup' and pickup_point_id is not null));
