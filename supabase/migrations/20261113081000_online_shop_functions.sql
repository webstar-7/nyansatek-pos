-- =====================================================================
-- Online Shop + nyansatek.market — server-side functions
-- Browsers never write order tables directly; every change goes through these,
-- which check who is asking, what state the order is in, prices and stock.
-- =====================================================================

-- Ghana phone numbers to 233XXXXXXXXX; null when not a plausible number
create or replace function public.norm_phone(p text)
returns text language sql immutable set search_path = '' as $$
  select case
    when d ~ '^233[0-9]{9}$' then d
    when d ~ '^0[0-9]{9}$' then '233' || substr(d, 2)
    when d ~ '^[0-9]{9}$' then '233' || d
    else null end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) x;
$$;

-- is this shop's own online store live?
create or replace function public.shop_store_live(p_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.shop_online_settings s join public.organizations o on o.id = s.org_id
                 where s.org_id = p_org and s.addon_active and s.store_enabled and s.store_slug is not null
                   and coalesce(o.is_active, true));
$$;

-- is this shop live on nyansatek.market?
create or replace function public.shop_market_live(p_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.shop_online_settings s join public.organizations o on o.id = s.org_id
                 where s.org_id = p_org and s.addon_active and s.marketplace_status = 'approved'
                   and s.listings_hidden_reason is null and coalesce(o.is_active, true));
$$;

-- ---------- order bookkeeping helpers (not callable from browsers) ----
create or replace function public._order_event(p_order uuid, p_status text, p_kind text, p_actor uuid, p_note text default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.online_order_events (order_id, status, actor_kind, actor_id, note)
  values (p_order, p_status, p_kind, p_actor, p_note);
$$;

create or replace function public._release_order_stock(p_order uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare r record; v_before int; v_code text;
begin
  select code into v_code from public.online_orders where id = p_order;
  for r in select i.product_id, i.qty, i.name_snapshot, o.org_id
           from public.online_order_items i join public.online_orders o on o.id = i.order_id
           where i.order_id = p_order and i.product_id is not null loop
    update public.products set stock = stock + r.qty where id = r.product_id returning stock - r.qty into v_before;
    if found then
      insert into public.inventory_log (org_id, product_id, product_name_snapshot, qty_added, stock_before, stock_after, note)
      values (r.org_id, r.product_id, r.name_snapshot, r.qty, v_before, v_before + r.qty, 'Online order ' || v_code || ' ' || p_reason);
    end if;
  end loop;
end;
$$;

create or replace function public._cancel_order(p_order uuid, p_reason text, p_kind text, p_actor uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.online_orders set status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason where id = p_order;
  update public.delivery_jobs set status = 'cancelled' where order_id = p_order and status in ('open','assigned','at_shop');
  perform public._release_order_stock(p_order, 'cancelled: stock returned');
  perform public._order_event(p_order, 'cancelled', p_kind, p_actor, p_reason);
end;
$$;

-- record the completed order as a normal sale so it shows in the shop's sales reports
create or replace function public._complete_order(p_order uuid, p_kind text, p_actor uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.online_orders%rowtype; v_sale uuid;
begin
  select * into o from public.online_orders where id = p_order for update;
  if o.status = 'completed' then return; end if;
  insert into public.sales (org_id, invoice_id, cashier_id, payment_method, total, amount_tendered, change_due,
                            cashier_name_snapshot, client_ref)
  values (o.org_id, o.code, null, case o.payment_method when 'momo' then 'Mobile Money' else 'Cash' end,
          o.goods_total, o.goods_total, 0,
          case o.channel when 'market' then 'nyansatek.market order' else 'Online shop order' end,
          'online:' || o.id::text)
  on conflict (client_ref) do nothing
  returning id into v_sale;
  if v_sale is not null then
    insert into public.sale_items (sale_id, product_id, name_snapshot, price_snapshot, qty, line_total, cost_price_snapshot)
    select v_sale, product_id, name_snapshot, price_snapshot, qty, line_total, coalesce(cost_price_snapshot, 0)
    from public.online_order_items where order_id = p_order;
  end if;
  update public.online_orders set status = 'completed', completed_at = now(), sale_id = coalesce(v_sale, sale_id)
  where id = p_order;
  perform public._order_event(p_order, 'completed', p_kind, p_actor, null);
end;
$$;

revoke all on function public._order_event(uuid, text, text, uuid, text), public._release_order_stock(uuid, text),
  public._cancel_order(uuid, text, text, uuid), public._complete_order(uuid, text, uuid) from public, anon, authenticated;

-- ---------- public catalogue -----------------------------------------
-- a shop's own store page: shop details + its published products
create or replace function public.store_catalog(p_slug text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare s public.shop_online_settings%rowtype; v_shop jsonb; v_products jsonb;
begin
  select * into s from public.shop_online_settings where store_slug = lower(btrim(p_slug));
  if not found or not public.shop_store_live(s.org_id) then return null; end if;
  select jsonb_build_object('org_id', s.org_id, 'slug', s.store_slug,
           'name', coalesce(s.store_name, o.business_name), 'tagline', s.store_tagline, 'logo_url', s.logo_url,
           'whatsapp', s.whatsapp_number, 'momo_number', s.momo_number, 'momo_name', s.momo_name,
           'on_market', public.shop_market_live(s.org_id))
    into v_shop from public.organizations o where o.id = s.org_id;
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'price', p.price, 'photo_url', p.photo_url,
           'description', p.description, 'category', p.category, 'in_stock', p.stock > 0,
           'delivery_size', p.delivery_size) order by p.category nulls last, p.name), '[]'::jsonb)
    into v_products from public.products p where p.org_id = s.org_id and p.show_online;
  return jsonb_build_object('shop', v_shop, 'products', v_products);
end;
$$;

-- category id plus all its sub-categories
create or replace function public.market_category_tree(p_category uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  with recursive t(id) as (
    select id from public.market_categories where id = p_category and active
    union all
    select c.id from public.market_categories c join t on c.parent_id = t.id where c.active)
  select id from t;
$$;

-- marketplace listings: only approved, paid-up shops; only products the shop listed, with a photo and a category
create or replace function public.market_listings(p_category uuid default null, p_q text default null,
  p_org uuid default null, p_limit int default 40, p_offset int default 0)
returns table (id uuid, name text, price numeric, photo_url text, description text, in_stock boolean,
               delivery_size text, category_id uuid, category_name text, org_id uuid, shop_name text, shop_slug text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.name, p.price, p.photo_url, p.description, p.stock > 0, p.delivery_size,
         c.id, c.name, p.org_id, coalesce(s.store_name, o.business_name), s.store_slug
  from public.products p
  join public.shop_online_settings s on s.org_id = p.org_id
  join public.organizations o on o.id = p.org_id
  join public.market_categories c on c.id = p.market_category_id and c.active
  where p.list_on_market and p.photo_url is not null and p.price > 0
    and public.shop_market_live(p.org_id)
    and (p_category is null or p.market_category_id in (select public.market_category_tree(p_category)))
    and (p_org is null or p.org_id = p_org)
    and (p_q is null or btrim(p_q) = '' or p.name ilike '%' || btrim(p_q) || '%' or p.description ilike '%' || btrim(p_q) || '%')
  order by (p.stock > 0) desc, p.updated_at desc nulls last, p.name
  limit least(greatest(coalesce(p_limit, 40), 1), 100) offset greatest(coalesce(p_offset, 0), 0);
$$;

-- ---------- placing an order ------------------------------------------
-- p = { channel: 'store'|'market', store_slug | org_id, items: [{product_id, qty}],
--       customer: {name, phone}, fulfilment: 'delivery'|'pickup', zone_id, address, landmark,
--       pickup_point_id, payment_method: 'momo'|'pod', momo_txn_id, note }
create or replace function public.place_online_order(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  cfg public.market_settings%rowtype;
  s public.shop_online_settings%rowtype;
  v_channel text := p ->> 'channel';
  v_phone text := public.norm_phone(p -> 'customer' ->> 'phone');
  v_name text := btrim(coalesce(p -> 'customer' ->> 'name', ''));
  v_fulfil text := p ->> 'fulfilment';
  v_pay text := p ->> 'payment_method';
  v_zone uuid; v_point uuid; v_addr text; v_landmark text;
  v_rank int := 0; v_vehicle text;
  v_total numeric := 0; v_fee numeric := 0;
  v_lines jsonb := '[]'::jsonb; v_line jsonb;
  r record; v_prod public.products%rowtype;
  v_order uuid; v_code text; v_dcode text; v_token uuid; v_customer uuid; v_open int; v_rate numeric := 0;
begin
  select * into cfg from public.market_settings where id;
  if v_channel is null or v_channel not in ('store', 'market') then raise exception 'Unknown order channel'; end if;

  -- which shop, and is it taking orders on this channel?
  if v_channel = 'store' then
    select * into s from public.shop_online_settings where store_slug = lower(btrim(p ->> 'store_slug'));
    if not found or not public.shop_store_live(s.org_id) then raise exception 'This shop is not taking online orders right now'; end if;
  else
    begin
      select * into s from public.shop_online_settings where org_id = (p ->> 'org_id')::uuid;
    exception when invalid_text_representation then raise exception 'Shop not found'; end;
    if not found or not public.shop_market_live(s.org_id) then raise exception 'This shop is not taking marketplace orders right now'; end if;
  end if;

  -- customer
  if v_phone is null then raise exception 'Enter a valid Ghana phone number'; end if;
  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'Enter your name'; end if;
  select count(*) into v_open from public.online_orders
   where customer_phone = v_phone and status in ('placed','accepted','ready','in_transit','at_pickup_point');
  if v_open >= cfg.max_open_orders_per_phone then
    raise exception 'You already have % open orders. Please wait for them to finish.', v_open;
  end if;

  -- items: merge duplicates, lock each product, check it is published and in stock, price it from the database
  if jsonb_typeof(p -> 'items') is distinct from 'array' or jsonb_array_length(p -> 'items') = 0 then
    raise exception 'Your cart is empty'; end if;
  if jsonb_array_length(p -> 'items') > 50 then raise exception 'Too many items in one order'; end if;
  for r in select x ->> 'product_id' as pid, sum((x ->> 'qty')::int) as qty
           from jsonb_array_elements(p -> 'items') x group by x ->> 'product_id' loop
    if r.qty is null or r.qty < 1 or r.qty > 999 then raise exception 'Invalid quantity'; end if;
    begin
      select * into v_prod from public.products where id = r.pid::uuid and org_id = s.org_id for update;
    exception when invalid_text_representation then raise exception 'Product not found'; end;
    if not found or (v_channel = 'store' and not v_prod.show_online)
       or (v_channel = 'market' and not (v_prod.list_on_market and v_prod.photo_url is not null and v_prod.market_category_id is not null)) then
      raise exception 'A product in your cart is no longer available';
    end if;
    if v_prod.price is null or v_prod.price <= 0 then raise exception '% is not for sale online', v_prod.name; end if;
    if coalesce(v_prod.stock, 0) < r.qty then
      raise exception 'Only % of % left', greatest(coalesce(v_prod.stock, 0), 0), v_prod.name; end if;
    v_total := v_total + v_prod.price * r.qty;
    if public.vehicle_rank(v_prod.delivery_size) > v_rank then v_rank := public.vehicle_rank(v_prod.delivery_size); v_vehicle := v_prod.delivery_size; end if;
    v_lines := v_lines || jsonb_build_object('id', v_prod.id, 'name', v_prod.name, 'price', v_prod.price,
      'cost', v_prod.cost_price, 'qty', r.qty, 'size', v_prod.delivery_size, 'stock', v_prod.stock);
  end loop;

  -- fulfilment
  if v_fulfil = 'delivery' then
    begin v_zone := (p ->> 'zone_id')::uuid; exception when invalid_text_representation then v_zone := null; end;
    if v_zone is null or not exists (select 1 from public.delivery_zones where id = v_zone and active) then
      raise exception 'Choose your delivery area'; end if;
    v_addr := btrim(coalesce(p ->> 'address', ''));
    v_landmark := nullif(btrim(coalesce(p ->> 'landmark', '')), '');
    if length(v_addr) < 5 or length(v_addr) > 300 then raise exception 'Enter your delivery address'; end if;
    select fee into v_fee from public.delivery_zone_fees where zone_id = v_zone and vehicle = v_vehicle;
    if v_fee is null then raise exception 'Delivery by % is not available in this area yet', v_vehicle; end if;
  elsif v_fulfil = 'pickup' then
    begin v_point := (p ->> 'pickup_point_id')::uuid; exception when invalid_text_representation then v_point := null; end;
    if v_point is null or not exists (select 1 from public.pickup_points where id = v_point and active) then
      raise exception 'Choose a pickup point'; end if;
    v_fee := 0;
  else
    raise exception 'Choose delivery or pickup';
  end if;

  -- payment
  if v_pay = 'pod' then
    if v_vehicle = 'truck' then raise exception 'Orders delivered by truck must be paid by MoMo first'; end if;
  elsif v_pay = 'momo' then
    if s.momo_number is null then raise exception 'This shop has not set up MoMo payments yet'; end if;
  else
    raise exception 'Choose how you will pay';
  end if;

  -- customer record (by phone)
  insert into public.market_customers (phone, name) values (v_phone, v_name)
  on conflict (phone) do update set name = excluded.name
  returning id into v_customer;
  if auth.uid() is not null then
    update public.market_customers set auth_user_id = auth.uid()
    where id = v_customer and auth_user_id is null
      and exists (select 1 from auth.users u where u.id = auth.uid() and coalesce(u.raw_user_meta_data ->> 'app', '') = 'market');
  end if;

  if v_channel = 'market' then v_rate := cfg.commission_rate; end if;
  v_code := 'NS' || nextval('public.online_order_seq')::text;
  v_dcode := lpad((floor(random() * 10000))::int::text, 4, '0');

  insert into public.online_orders (code, org_id, channel, customer_id, customer_name, customer_phone, fulfilment,
      zone_id, address, landmark, pickup_point_id, vehicle, payment_method, momo_txn_id, goods_total, delivery_fee,
      commission_rate, commission_amount, delivery_code, customer_note, accept_deadline)
  values (v_code, s.org_id, v_channel, v_customer, v_name, v_phone, v_fulfil, v_zone, v_addr, v_landmark, v_point,
      v_vehicle, v_pay, nullif(btrim(coalesce(p ->> 'momo_txn_id', '')), ''), v_total, v_fee,
      v_rate, round(v_total * v_rate, 2), v_dcode, nullif(left(btrim(coalesce(p ->> 'note', '')), 300), ''),
      now() + make_interval(mins => cfg.accept_minutes))
  returning id, track_token into v_order, v_token;

  -- items + reserve stock
  for v_line in select * from jsonb_array_elements(v_lines) loop
    insert into public.online_order_items (order_id, product_id, name_snapshot, price_snapshot, cost_price_snapshot, qty, line_total, delivery_size)
    values (v_order, (v_line ->> 'id')::uuid, v_line ->> 'name', (v_line ->> 'price')::numeric, (v_line ->> 'cost')::numeric,
            (v_line ->> 'qty')::int, (v_line ->> 'price')::numeric * (v_line ->> 'qty')::int, v_line ->> 'size');
    update public.products set stock = stock - (v_line ->> 'qty')::int where id = (v_line ->> 'id')::uuid;
    insert into public.inventory_log (org_id, product_id, product_name_snapshot, qty_added, stock_before, stock_after, note)
    values (s.org_id, (v_line ->> 'id')::uuid, v_line ->> 'name', -(v_line ->> 'qty')::int, (v_line ->> 'stock')::int,
            (v_line ->> 'stock')::int - (v_line ->> 'qty')::int, 'Online order ' || v_code || ' reserved');
  end loop;

  perform public._order_event(v_order, 'placed', 'customer', auth.uid(), null);

  return jsonb_build_object('order_id', v_order, 'code', v_code, 'track_token', v_token, 'status', 'placed',
    'goods_total', v_total, 'delivery_fee', v_fee, 'total', v_total + v_fee, 'vehicle', v_vehicle,
    'payment_method', v_pay, 'momo_number', case when v_pay = 'momo' then s.momo_number end,
    'momo_name', case when v_pay = 'momo' then s.momo_name end,
    'accept_deadline', now() + make_interval(mins => cfg.accept_minutes));
end;
$$;

-- customer adds the MoMo transaction ID after paying (only while the shop hasn't accepted yet)
create or replace function public.add_order_momo_ref(p_token uuid, p_txn text)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.online_orders%rowtype;
begin
  select * into o from public.online_orders where track_token = p_token for update;
  if not found then raise exception 'Order not found'; end if;
  if o.payment_method <> 'momo' or o.status <> 'placed' then raise exception 'This order can no longer be changed'; end if;
  if length(btrim(coalesce(p_txn, ''))) < 4 or length(p_txn) > 60 then raise exception 'Enter the MoMo transaction ID'; end if;
  update public.online_orders set momo_txn_id = btrim(p_txn) where id = o.id;
  perform public._order_event(o.id, 'momo_ref_added', 'customer', auth.uid(), null);
end;
$$;

-- order tracking page (whoever holds the private tracking link)
create or replace function public.get_online_order(p_token uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'code', o.code, 'status', o.status, 'channel', o.channel, 'created_at', o.created_at,
    'accept_deadline', o.accept_deadline, 'fulfilment', o.fulfilment, 'payment_method', o.payment_method,
    'payment_confirmed', o.payment_confirmed_at is not null, 'momo_txn_id', o.momo_txn_id,
    'goods_total', o.goods_total, 'delivery_fee', o.delivery_fee, 'total', o.goods_total + o.delivery_fee,
    'vehicle', o.vehicle, 'address', o.address, 'landmark', o.landmark, 'delivery_code', o.delivery_code,
    'pickup_deadline', o.pickup_deadline, 'cancel_reason', o.cancel_reason, 'customer_name', o.customer_name,
    'shop', jsonb_build_object('name', coalesce(s.store_name, org.business_name), 'slug', s.store_slug,
                               'momo_number', s.momo_number, 'momo_name', s.momo_name, 'whatsapp', s.whatsapp_number),
    'zone', (select z.name from public.delivery_zones z where z.id = o.zone_id),
    'pickup_point', (select jsonb_build_object('name', pp.name, 'address', pp.address, 'landmark', pp.landmark,
                       'phone', pp.phone, 'hours', pp.hours) from public.pickup_points pp where pp.id = o.pickup_point_id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name_snapshot, 'price', i.price_snapshot,
                'qty', i.qty, 'line_total', i.line_total) order by i.name_snapshot), '[]'::jsonb)
              from public.online_order_items i where i.order_id = o.id),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('status', e.status, 'at', e.created_at) order by e.created_at), '[]'::jsonb)
               from public.online_order_events e where e.order_id = o.id and e.status not like '%\_ref\_%'))
  from public.online_orders o
  join public.organizations org on org.id = o.org_id
  left join public.shop_online_settings s on s.org_id = o.org_id
  where o.track_token = p_token;
$$;

-- ---------- shop settings (shop admin) ------------------------------
-- shops can change their store details and ask to join the marketplace; never their add-on or approval
create or replace function public.save_online_settings(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.current_org_id(); v_slug text; v_momo text; v_wa text; v_row public.shop_online_settings%rowtype;
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

  insert into public.shop_online_settings as t (org_id, store_slug, store_name, store_tagline, logo_url, momo_number, momo_name,
         whatsapp_number, store_enabled)
  values (v_org, v_slug, nullif(left(btrim(coalesce(p ->> 'store_name', '')), 80), ''),
          nullif(left(btrim(coalesce(p ->> 'store_tagline', '')), 140), ''), nullif(btrim(coalesce(p ->> 'logo_url', '')), ''),
          v_momo, nullif(left(btrim(coalesce(p ->> 'momo_name', '')), 80), ''), v_wa, coalesce((p ->> 'store_enabled')::boolean, true))
  on conflict (org_id) do update set store_slug = excluded.store_slug, store_name = excluded.store_name,
         store_tagline = excluded.store_tagline, logo_url = excluded.logo_url, momo_number = excluded.momo_number,
         momo_name = excluded.momo_name, whatsapp_number = excluded.whatsapp_number, store_enabled = excluded.store_enabled
  returning * into v_row;

  if coalesce((p ->> 'request_marketplace')::boolean, false) and v_row.marketplace_status = 'none' then
    update public.shop_online_settings set marketplace_status = 'pending' where org_id = v_org returning * into v_row;
  end if;
  return to_jsonb(v_row);
end;
$$;

-- ---------- shop actions on an order --------------------------------
-- p_action: 'accept' | 'reject' | 'ready' | 'cancel' | 'confirm_cash'
create or replace function public.shop_order_action(p_order uuid, p_action text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o public.online_orders%rowtype; v_me uuid := auth.uid(); v_zone uuid; v_fee numeric; v_held numeric;
begin
  select * into o from public.online_orders where id = p_order for update;
  if not found or o.org_id is distinct from public.current_org_id()
     or not exists (select 1 from public.profiles where id = v_me and coalesce(is_active, true)) then
    raise exception 'Order not found'; end if;

  if p_action = 'accept' then
    if o.status <> 'placed' then raise exception 'This order is already %', o.status; end if;
    if now() > o.accept_deadline then
      perform public._cancel_order(o.id, 'Not accepted within the time limit', 'system', null);
      raise exception 'Too late: this order was not accepted in time and has been cancelled';
    end if;
    update public.online_orders set status = 'accepted', accepted_at = now(),
           payment_confirmed_at = case when payment_method = 'momo' then now() else payment_confirmed_at end
     where id = o.id;
    perform public._order_event(o.id, 'accepted', 'shop', v_me,
            case when o.payment_method = 'momo' then 'MoMo payment confirmed by the shop' end);
    -- open the delivery job (to the customer, or to the pickup point)
    if o.fulfilment = 'delivery' then
      insert into public.delivery_jobs (order_id, kind, vehicle, zone_id, fee)
      values (o.id, 'to_customer', o.vehicle, o.zone_id, o.delivery_fee);
    else
      select zone_id into v_zone from public.pickup_points where id = o.pickup_point_id;
      select fee into v_fee from public.delivery_zone_fees where zone_id = v_zone and vehicle = o.vehicle;
      insert into public.delivery_jobs (order_id, kind, vehicle, zone_id, fee)
      values (o.id, 'to_pickup_point', o.vehicle, v_zone, coalesce(v_fee, 0));
    end if;

  elsif p_action = 'reject' then
    if o.status <> 'placed' then raise exception 'This order is already %', o.status; end if;
    perform public._cancel_order(o.id, coalesce(nullif(btrim(p_note), ''), 'Rejected by the shop'), 'shop', v_me);

  elsif p_action = 'ready' then
    if o.status <> 'accepted' then raise exception 'Only accepted orders can be marked ready'; end if;
    update public.online_orders set status = 'ready', ready_at = now() where id = o.id;
    perform public._order_event(o.id, 'ready', 'shop', v_me, null);

  elsif p_action = 'cancel' then
    if o.status not in ('accepted', 'ready') or exists (select 1 from public.delivery_jobs j where j.order_id = o.id and j.status = 'picked_up') then
      raise exception 'This order can no longer be cancelled by the shop'; end if;
    perform public._cancel_order(o.id, coalesce(nullif(btrim(p_note), ''), 'Cancelled by the shop'), 'shop', v_me);

  elsif p_action = 'confirm_cash' then
    if o.payment_method <> 'pod' or o.status not in ('delivered', 'collected') or o.cash_status not in ('with_rider', 'with_pickup_point') then
      raise exception 'There is no cash waiting for this order'; end if;
    select coalesce(sum(amount), 0) into v_held from public.cash_ledger where order_id = o.id and entry = 'collected';
    insert into public.cash_ledger (order_id, org_id, entry, holder_kind, rider_id, pickup_point_id, amount, recorded_by, shop_confirmed_by, shop_confirmed_at)
    select o.id, o.org_id, 'handed_to_shop', c.holder_kind, c.rider_id, c.pickup_point_id, v_held, v_me, v_me, now()
    from public.cash_ledger c where c.order_id = o.id and c.entry = 'collected' order by c.id desc limit 1;
    update public.online_orders set cash_status = 'handed_to_shop' where id = o.id;
    perform public._order_event(o.id, 'cash_handed_to_shop', 'shop', v_me, null);
    perform public._complete_order(o.id, 'shop', v_me);

  else
    raise exception 'Unknown action';
  end if;

  select * into o from public.online_orders where id = p_order;
  return jsonb_build_object('status', o.status, 'cash_status', o.cash_status);
end;
$$;

-- ---------- automatic expiry: not accepted in time --------------------
create or replace function public.expire_unaccepted_orders()
returns int language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0;
begin
  for r in select id from public.online_orders where status = 'placed' and accept_deadline < now() for update skip locked loop
    perform public._cancel_order(r.id, 'Not accepted by the shop within the time limit', 'system', null);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public.expire_unaccepted_orders() from public, anon, authenticated;

-- ---------- who may call what ----------------------------------------
revoke all on function public.store_catalog(text), public.market_listings(uuid, text, uuid, int, int),
  public.market_category_tree(uuid), public.place_online_order(jsonb), public.add_order_momo_ref(uuid, text),
  public.get_online_order(uuid), public.save_online_settings(jsonb), public.shop_order_action(uuid, text, text),
  public.shop_store_live(uuid), public.shop_market_live(uuid) from public;
grant execute on function public.store_catalog(text), public.market_listings(uuid, text, uuid, int, int),
  public.market_category_tree(uuid), public.place_online_order(jsonb), public.add_order_momo_ref(uuid, text),
  public.get_online_order(uuid), public.shop_store_live(uuid), public.shop_market_live(uuid), public.norm_phone(text)
  to anon, authenticated;
grant execute on function public.save_online_settings(jsonb), public.shop_order_action(uuid, text, text),
  public.is_market_ops(), public.is_shop_admin(), public.vehicle_rank(text) to authenticated;

-- run the expiry every minute
select cron.schedule('expire-unaccepted-online-orders', '* * * * *', $$select public.expire_unaccepted_orders()$$);
