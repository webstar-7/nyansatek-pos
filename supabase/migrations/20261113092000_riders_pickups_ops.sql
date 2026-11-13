-- =====================================================================
-- Riders, pickup points and the NYANSATEK team: delivery jobs from shop to customer / pickup point,
-- collection at pickup points, 24-hour returns, rider assignment, shop approval.
-- =====================================================================

-- where riders collect from: the shop's address and phone (set by the shop in Settings > Online Shop)
alter table public.shop_online_settings
  add column if not exists shop_address text,
  add column if not exists shop_phone text;

-- extend save_online_settings with the pickup address and phone
create or replace function public.save_online_settings(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.current_org_id(); v_slug text; v_momo text; v_wa text; v_ph text; v_row public.shop_online_settings%rowtype;
begin
  if v_org is null or not public.is_shop_admin() then raise exception 'Only the shop admin can change online shop settings'; end if;
  v_slug := nullif(lower(btrim(coalesce(p ->> 'store_slug', ''))), '');
  if v_slug is not null and (v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or length(v_slug) not between 3 and 60) then
    raise exception 'Web address: 3-60 letters, numbers and dashes'; end if;
  if v_slug is not null and exists (select 1 from public.shop_online_settings where store_slug = v_slug and org_id <> v_org) then
    raise exception 'That web address is taken'; end if;
  v_momo := case when nullif(btrim(coalesce(p ->> 'momo_number', '')), '') is null then null else public.norm_phone(p ->> 'momo_number') end;
  if nullif(btrim(coalesce(p ->> 'momo_number', '')), '') is not null and v_momo is null then raise exception 'Enter a valid MoMo number'; end if;
  v_wa := case when nullif(btrim(coalesce(p ->> 'whatsapp_number', '')), '') is null then null else public.norm_phone(p ->> 'whatsapp_number') end;
  if nullif(btrim(coalesce(p ->> 'whatsapp_number', '')), '') is not null and v_wa is null then raise exception 'Enter a valid WhatsApp number'; end if;
  v_ph := case when nullif(btrim(coalesce(p ->> 'shop_phone', '')), '') is null then null else public.norm_phone(p ->> 'shop_phone') end;
  if nullif(btrim(coalesce(p ->> 'shop_phone', '')), '') is not null and v_ph is null then raise exception 'Enter a valid shop phone number'; end if;

  insert into public.shop_online_settings as t (org_id, store_slug, store_name, store_tagline, logo_url, momo_number, momo_name,
         whatsapp_number, store_enabled, shop_address, shop_phone)
  values (v_org, v_slug, nullif(left(btrim(coalesce(p ->> 'store_name', '')), 80), ''),
          nullif(left(btrim(coalesce(p ->> 'store_tagline', '')), 140), ''), nullif(btrim(coalesce(p ->> 'logo_url', '')), ''),
          v_momo, nullif(left(btrim(coalesce(p ->> 'momo_name', '')), 80), ''), v_wa, coalesce((p ->> 'store_enabled')::boolean, true),
          nullif(left(btrim(coalesce(p ->> 'shop_address', '')), 300), ''), v_ph)
  on conflict (org_id) do update set store_slug = excluded.store_slug, store_name = excluded.store_name,
         store_tagline = excluded.store_tagline, logo_url = excluded.logo_url, momo_number = excluded.momo_number,
         momo_name = excluded.momo_name, whatsapp_number = excluded.whatsapp_number, store_enabled = excluded.store_enabled,
         shop_address = excluded.shop_address, shop_phone = excluded.shop_phone
  returning * into v_row;
  if coalesce((p ->> 'request_marketplace')::boolean, false) and v_row.marketplace_status = 'none' then
    update public.shop_online_settings set marketplace_status = 'pending' where org_id = v_org returning * into v_row;
  end if;
  return to_jsonb(v_row);
end;
$$;

-- ---------- helpers ----------
create or replace function public.is_rider()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.riders where id = auth.uid() and active);
$$;

-- a job's pickup and drop-off details, as a rider sees them
-- p_full = false (open jobs not yet accepted): area and shop only, no customer phone or address
create or replace function public._job_view(j public.delivery_jobs, p_full boolean default true)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'job_id', j.id, 'kind', j.kind, 'status', j.status, 'vehicle', j.vehicle, 'fee', j.fee, 'created_at', j.created_at,
    'order_id', o.id, 'code', o.code, 'order_status', o.status, 'payment_method', o.payment_method,
    'collect_cash', case when o.payment_method = 'pod' and j.kind = 'to_customer' then o.goods_total + o.delivery_fee else 0 end,
    'goods_total', o.goods_total, 'items', (select coalesce(sum(qty), 0) from public.online_order_items where order_id = o.id),
    'from', case when j.kind = 'return_to_shop'
              then jsonb_build_object('name', pp.name, 'address', pp.address, 'landmark', pp.landmark, 'phone', pp.phone)
              else jsonb_build_object('name', coalesce(s.store_name, org.business_name), 'address', s.shop_address, 'phone', s.shop_phone) end,
    'to', case when j.kind = 'to_customer'
              then case when p_full
                   then jsonb_build_object('name', o.customer_name, 'address', o.address, 'landmark', o.landmark, 'phone', o.customer_phone,
                                           'zone', (select name from public.delivery_zones where id = o.zone_id))
                   else jsonb_build_object('zone', (select name from public.delivery_zones where id = o.zone_id)) end
            when j.kind = 'to_pickup_point'
              then jsonb_build_object('name', pp.name, 'address', pp.address, 'landmark', pp.landmark, 'phone', pp.phone)
            else jsonb_build_object('name', coalesce(s.store_name, org.business_name), 'address', s.shop_address, 'phone', s.shop_phone) end)
  from public.online_orders o
  join public.organizations org on org.id = o.org_id
  left join public.shop_online_settings s on s.org_id = o.org_id
  left join public.pickup_points pp on pp.id = o.pickup_point_id
  where o.id = j.order_id;
$$;
revoke all on function public._job_view(public.delivery_jobs, boolean) from public, anon, authenticated;

-- ---------- rider: profile, online, jobs ----------
create or replace function public.rider_me()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.riders%rowtype; v_cash numeric; v_fees numeric;
begin
  select * into r from public.riders where id = auth.uid();
  if not found then return null; end if;
  select coalesce(sum(case entry when 'collected' then amount else -amount end), 0) into v_cash
    from public.cash_ledger where rider_id = r.id and holder_kind = 'rider';
  select coalesce(sum(fee), 0) into v_fees from public.delivery_jobs
    where rider_id = r.id and status = 'done' and done_at >= date_trunc('day', now() at time zone 'Africa/Accra') at time zone 'Africa/Accra';
  return jsonb_build_object('id', r.id, 'name', r.full_name, 'phone', r.phone, 'vehicle', r.vehicle, 'plate', r.plate_number,
    'active', r.active, 'online', r.online, 'cash_on_hand', v_cash, 'fees_today', v_fees,
    'zones', (select coalesce(jsonb_agg(name order by name), '[]'::jsonb) from public.delivery_zones where id = any(r.zone_ids)));
end;
$$;

create or replace function public.rider_set_online(p_online boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_rider() then raise exception 'Not a rider account'; end if;
  update public.riders set online = p_online, last_seen_at = now() where id = auth.uid();
end;
$$;

-- open jobs this rider can take: vehicle big enough, in one of their zones (no zones = anywhere)
create or replace function public.rider_jobs()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.riders%rowtype;
begin
  select * into r from public.riders where id = auth.uid() and active;
  if not found then raise exception 'Not a rider account'; end if;
  update public.riders set last_seen_at = now() where id = r.id;
  return jsonb_build_object(
    'mine', (select coalesce(jsonb_agg(public._job_view(j) order by j.assigned_at), '[]'::jsonb)
             from public.delivery_jobs j where j.rider_id = r.id and j.status in ('assigned','at_shop','picked_up')),
    'open', case when r.online then (select coalesce(jsonb_agg(public._job_view(j, false) order by j.created_at), '[]'::jsonb)
             from public.delivery_jobs j
             where j.status = 'open' and public.vehicle_rank(j.vehicle) <= public.vehicle_rank(r.vehicle)
               and (cardinality(r.zone_ids) = 0 or j.zone_id is null or j.zone_id = any(r.zone_ids))) else '[]'::jsonb end,
    'done_today', (select coalesce(jsonb_agg(public._job_view(j) order by j.done_at desc), '[]'::jsonb)
             from public.delivery_jobs j where j.rider_id = r.id and j.status = 'done'
               and j.done_at >= date_trunc('day', now() at time zone 'Africa/Accra') at time zone 'Africa/Accra'));
end;
$$;

create or replace function public.rider_accept_job(p_job uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.riders%rowtype; j public.delivery_jobs%rowtype; v_busy int;
begin
  select * into r from public.riders where id = auth.uid() and active;
  if not found then raise exception 'Not a rider account'; end if;
  if not r.online then raise exception 'Go online to accept jobs'; end if;
  select * into j from public.delivery_jobs where id = p_job for update;
  if not found or j.status <> 'open' then raise exception 'This job has already been taken'; end if;
  if public.vehicle_rank(j.vehicle) > public.vehicle_rank(r.vehicle) then raise exception 'This job needs a bigger vehicle'; end if;
  select count(*) into v_busy from public.delivery_jobs where rider_id = r.id and status in ('assigned','at_shop','picked_up');
  if v_busy >= 3 then raise exception 'Finish your current jobs first (3 at a time)'; end if;
  update public.delivery_jobs set rider_id = r.id, status = 'assigned', assigned_at = now() where id = j.id returning * into j;
  perform public._order_event(j.order_id, 'rider_assigned', 'rider', r.id, r.full_name);
  return public._job_view(j);
end;
$$;

-- p_action: 'at_shop' | 'picked_up' | 'delivered' (needs the customer's code) | 'dropped' (at pickup point) | 'returned' (back at shop)
create or replace function public.rider_job_action(p_job uuid, p_action text, p_code text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.riders%rowtype; j public.delivery_jobs%rowtype; o public.online_orders%rowtype; cfg public.market_settings%rowtype;
begin
  select * into r from public.riders where id = auth.uid() and active;
  if not found then raise exception 'Not a rider account'; end if;
  select * into j from public.delivery_jobs where id = p_job and rider_id = r.id for update;
  if not found or j.status in ('done','cancelled') then raise exception 'Job not found'; end if;
  select * into o from public.online_orders where id = j.order_id for update;
  select * into cfg from public.market_settings where id;
  if o.status = 'cancelled' then raise exception 'This order was cancelled. Do not collect it.'; end if;

  if p_action = 'at_shop' then
    update public.delivery_jobs set status = 'at_shop' where id = j.id;
  elsif p_action = 'picked_up' then
    if j.kind <> 'return_to_shop' and o.status <> 'ready' then raise exception 'The shop has not marked this order ready yet'; end if;
    update public.delivery_jobs set status = 'picked_up', picked_up_at = now() where id = j.id;
    if j.kind <> 'return_to_shop' then
      update public.online_orders set status = 'in_transit' where id = o.id;
      perform public._order_event(o.id, 'in_transit', 'rider', r.id, null);
    end if;
  elsif p_action = 'delivered' then
    if j.kind <> 'to_customer' or j.status <> 'picked_up' then raise exception 'Pick up the order first'; end if;
    if btrim(coalesce(p_code, '')) <> o.delivery_code then raise exception 'Wrong code. Ask the customer for the 4-digit code from their SMS.'; end if;
    update public.delivery_jobs set status = 'done', done_at = now() where id = j.id;
    update public.online_orders set status = 'delivered', delivered_at = now(),
           cash_status = case when payment_method = 'pod' then 'with_rider' else cash_status end where id = o.id;
    perform public._order_event(o.id, 'delivered', 'rider', r.id, null);
    if o.payment_method = 'pod' then
      -- the rider keeps the delivery fee; the goods money is owed to the shop
      insert into public.cash_ledger (order_id, org_id, entry, holder_kind, rider_id, amount, recorded_by)
      values (o.id, o.org_id, 'collected', 'rider', r.id, o.goods_total, r.id);
    else
      perform public._complete_order(o.id, 'rider', r.id);
    end if;
  elsif p_action = 'dropped' then
    if j.kind <> 'to_pickup_point' or j.status <> 'picked_up' then raise exception 'Pick up the order first'; end if;
    update public.delivery_jobs set status = 'done', done_at = now() where id = j.id;
    update public.online_orders set status = 'at_pickup_point', at_pickup_at = now(),
           pickup_deadline = now() + make_interval(hours => cfg.pickup_hold_hours) where id = o.id;
    perform public._order_event(o.id, 'at_pickup_point', 'rider', r.id, null);
  elsif p_action = 'returned' then
    if j.kind <> 'return_to_shop' or j.status <> 'picked_up' then raise exception 'Pick up the order first'; end if;
    update public.delivery_jobs set status = 'done', done_at = now() where id = j.id;
    update public.online_orders set status = 'returned' where id = o.id;
    perform public._release_order_stock(o.id, 'returned to the shop: stock returned');
    perform public._order_event(o.id, 'returned', 'rider', r.id, null);
  else
    raise exception 'Unknown action';
  end if;
  select * into j from public.delivery_jobs where id = j.id;
  return public._job_view(j);
end;
$$;

-- ---------- pickup point desk (NYANSATEK team) ----------
-- p_action: 'collected' (needs the customer's code; records cash for pay-on-delivery)
create or replace function public.ops_pickup_action(p_code text, p_collection_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o public.online_orders%rowtype;
begin
  if not public.is_market_ops() then raise exception 'Team members only'; end if;
  select * into o from public.online_orders where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'Order not found'; end if;
  if o.status <> 'at_pickup_point' then raise exception 'This order is %', o.status; end if;
  if btrim(coalesce(p_collection_code, '')) <> o.delivery_code then raise exception 'Wrong collection code'; end if;
  update public.online_orders set status = 'collected', delivered_at = now(),
         cash_status = case when payment_method = 'pod' then 'with_pickup_point' else cash_status end where id = o.id;
  perform public._order_event(o.id, 'collected', 'team', auth.uid(), null);
  if o.payment_method = 'pod' then
    insert into public.cash_ledger (order_id, org_id, entry, holder_kind, pickup_point_id, amount, recorded_by)
    values (o.id, o.org_id, 'collected', 'pickup_point', o.pickup_point_id, o.goods_total, auth.uid());
  else
    perform public._complete_order(o.id, 'team', auth.uid());
  end if;
  return jsonb_build_object('code', o.code, 'status', 'collected', 'collect_cash', case when o.payment_method = 'pod' then o.goods_total else 0 end);
end;
$$;

-- ---------- team: assign / release a job, cancel an order ----------
create or replace function public.ops_assign_job(p_job uuid, p_rider uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare j public.delivery_jobs%rowtype; r public.riders%rowtype;
begin
  if not public.is_market_ops() then raise exception 'Team members only'; end if;
  select * into j from public.delivery_jobs where id = p_job for update;
  if not found or j.status not in ('open','assigned','at_shop') then raise exception 'This job can no longer be reassigned'; end if;
  if p_rider is null then
    update public.delivery_jobs set rider_id = null, status = 'open', assigned_at = null where id = j.id;
    return;
  end if;
  select * into r from public.riders where id = p_rider and active;
  if not found then raise exception 'Rider not found'; end if;
  if public.vehicle_rank(j.vehicle) > public.vehicle_rank(r.vehicle) then raise exception 'That rider''s vehicle is too small for this job'; end if;
  update public.delivery_jobs set rider_id = r.id, status = 'assigned', assigned_at = now() where id = j.id;
  perform public._order_event(j.order_id, 'rider_assigned', 'team', auth.uid(), r.full_name);
end;
$$;

create or replace function public.ops_cancel_order(p_order uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.online_orders%rowtype;
begin
  if not public.is_market_ops() then raise exception 'Team members only'; end if;
  select * into o from public.online_orders where id = p_order for update;
  if not found or o.status in ('completed','cancelled','returned','delivered','collected') then raise exception 'This order can no longer be cancelled'; end if;
  if exists (select 1 from public.delivery_jobs where order_id = o.id and status = 'picked_up') then
    raise exception 'A rider is carrying this order. Ask them to return it to the shop first.'; end if;
  perform public._cancel_order(o.id, coalesce(nullif(btrim(p_reason), ''), 'Cancelled by NYANSATEK'), 'team', auth.uid());
end;
$$;

-- ---------- 24-hour pickup hold: uncollected orders go back to the shop ----------
create or replace function public.expire_uncollected_pickups()
returns int language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0; v_zone uuid; v_fee numeric;
begin
  for r in select * from public.online_orders where status = 'at_pickup_point' and pickup_deadline < now() for update skip locked loop
    update public.online_orders set status = 'returning', cancel_reason = 'Not collected within the pickup time' where id = r.id;
    select zone_id into v_zone from public.pickup_points where id = r.pickup_point_id;
    select fee into v_fee from public.delivery_zone_fees where zone_id = v_zone and vehicle = r.vehicle;
    insert into public.delivery_jobs (order_id, kind, vehicle, zone_id, fee)
    values (r.id, 'return_to_shop', r.vehicle, v_zone, coalesce(v_fee, 0));
    perform public._order_event(r.id, 'returning', 'system', null, 'Not collected within the pickup time');
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public.expire_uncollected_pickups() from public, anon, authenticated;
select cron.schedule('expire-uncollected-pickups', '*/10 * * * *', $$select public.expire_uncollected_pickups()$$);

-- customers get an SMS when an uncollected order is sent back
create or replace function public._order_event_sms_returning()
returns trigger language plpgsql security definer set search_path = '' as $$
declare o public.online_orders%rowtype; v_shop text;
begin
  if new.status <> 'returning' then return null; end if;
  select * into o from public.online_orders where id = new.order_id;
  select coalesce(s.store_name, g.business_name) into v_shop from public.organizations g left join public.shop_online_settings s on s.org_id = g.id where g.id = o.org_id;
  perform public._send_order_sms(o.customer_phone, format('Order %s was not collected in time and is going back to %s. Contact the shop to arrange another collection.', o.code, v_shop));
  return null;
end;
$$;
drop trigger if exists online_order_events_sms_returning on public.online_order_events;
create trigger online_order_events_sms_returning after insert on public.online_order_events
  for each row execute function public._order_event_sms_returning();

-- ---------- who may call what ----------
revoke all on function public.rider_me(), public.rider_set_online(boolean), public.rider_jobs(), public.rider_accept_job(uuid),
  public.rider_job_action(uuid, text, text), public.ops_pickup_action(text, text), public.ops_assign_job(uuid, uuid),
  public.ops_cancel_order(uuid, text), public.is_rider() from public, anon;
grant execute on function public.rider_me(), public.rider_set_online(boolean), public.rider_jobs(), public.rider_accept_job(uuid),
  public.rider_job_action(uuid, text, text), public.ops_pickup_action(text, text), public.ops_assign_job(uuid, uuid),
  public.ops_cancel_order(uuid, text), public.is_rider() to authenticated;

-- the team dashboard needs shop names (organizations was readable only by master accounts and each shop itself)
drop policy if exists org_market_ops_read on public.organizations;
create policy org_market_ops_read on public.organizations for select using (public.is_market_ops());
