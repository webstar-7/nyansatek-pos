-- Orders through NYANSATEK (agreed 20 Nov 2026 after the restaurant visits)
--
-- * Every online order (nyansatek.store, nyansatek.food, a shop's or restaurant's own page) is paid by MoMo
--   to NYANSATEK's number, never to the shop, and never on delivery. It waits as "placed" until the team marks
--   the payment as received; unpaid orders are cancelled after market_settings.accept_minutes.
-- * The team places the order with the shop or restaurant by phone, then calls a courier from its own list.
--   No SMS goes to a shop or courier on its own: the team sends one from /ops when it is worth the credit.
-- * Pricing: no commission. Customers see the shop's price plus a markup (GH₵5 per dish on food, 5% on shop
--   products). The shop is paid its own prices by close of business each day; payouts are recorded here.
-- * Delivery: the courier charges the customer on delivery and keeps it, so orders carry no delivery fee.
-- * The online shop / online menu is free and switched on for every business; NYANSATEK lists them from /ops.
-- * Restaurants that do not use NYANSATEK Restaurant (for example ROYAL KAMAY RESTAURANT) can be listed with
--   dishes that have no photo yet.

-- ---------------------------------------------------------------- settings
alter table public.market_settings
  add column if not exists food_markup_per_item numeric not null default 5 check (food_markup_per_item >= 0),
  add column if not exists store_markup_rate numeric not null default 0.05 check (store_markup_rate >= 0 and store_markup_rate < 1);
update public.market_settings set commission_rate = 0, accept_minutes = 30, addon_price_monthly = 0, addon_price_yearly = 0;

-- Price a customer pays online for a shop price, by vertical.
create or replace function public.customer_price(p_price numeric, p_vertical text)
returns numeric language sql stable security definer set search_path to '' as $$
  select case when p_price is null then null
              when p_vertical = 'food' then p_price + m.food_markup_per_item
              else round(p_price * (1 + m.store_markup_rate), 2) end
  from public.market_settings m where m.id;
$$;
grant execute on function public.customer_price(numeric, text) to anon, authenticated;

-- ---------------------------------------------------------------- couriers (outside delivery people the team calls)
create table if not exists public.couriers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 2 and 80),
  company text,
  phone text not null,
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.couriers enable row level security;
drop policy if exists couriers_ops on public.couriers;
create policy couriers_ops on public.couriers for all using (public.is_market_ops()) with check (public.is_market_ops());

-- ---------------------------------------------------------------- payouts (shop paid its own prices, daily)
create table if not exists public.org_payouts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  pay_date date not null,
  amount numeric not null check (amount >= 0),
  orders_count int not null default 0,
  momo_ref text,
  note text,
  paid_at timestamptz not null default now(),
  paid_by uuid
);
alter table public.org_payouts enable row level security;
drop policy if exists org_payouts_ops on public.org_payouts;
create policy org_payouts_ops on public.org_payouts for all using (public.is_market_ops()) with check (public.is_market_ops());
drop policy if exists org_payouts_shop on public.org_payouts;
create policy org_payouts_shop on public.org_payouts for select using (org_id = public.current_org_id());

-- ---------------------------------------------------------------- order columns
alter table public.online_order_items add column if not exists base_price_snapshot numeric;
alter table public.online_orders
  add column if not exists base_total numeric,
  add column if not exists markup_total numeric not null default 0,
  add column if not exists courier_id uuid references public.couriers(id) on delete set null,
  add column if not exists courier_assigned_at timestamptz,
  add column if not exists payout_id uuid references public.org_payouts(id) on delete set null;
update public.online_order_items set base_price_snapshot = price_snapshot where base_price_snapshot is null;
update public.online_orders set base_total = goods_total where base_total is null;

-- ---------------------------------------------------------------- free online shop for everyone
update public.shop_online_settings set addon_active = true where not addon_active;
update public.shop_online_settings s set store_slug = 'ritpack-supermarket'
 where s.store_slug is null and s.org_id = '516096ae-ea38-4a09-bf58-a9ee01d1c6a8'
   and not exists (select 1 from public.shop_online_settings x where x.store_slug = 'ritpack-supermarket');

create or replace function public._slug_for(p_name text)
returns text language plpgsql stable security definer set search_path to '' as $$
declare v text; v_try text; n int := 1;
begin
  v := trim(both '-' from regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '-', 'g'));
  if length(v) < 3 then v := 'shop-' || v; end if;
  v := left(trim(both '-' from v), 54);
  v_try := v;
  while exists (select 1 from public.shop_online_settings where store_slug = v_try) loop
    n := n + 1; v_try := v || '-' || n;
  end loop;
  return v_try;
end $$;

create or replace function public._org_online_settings()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  insert into public.shop_online_settings (org_id, addon_active, store_slug, store_name, store_enabled)
  values (new.id, true, public._slug_for(new.business_name), new.business_name, true)
  on conflict (org_id) do nothing;
  return new;
end $$;
drop trigger if exists org_online_settings on public.organizations;
create trigger org_online_settings after insert on public.organizations
  for each row execute function public._org_online_settings();

insert into public.shop_online_settings (org_id, addon_active, store_slug, store_name, store_enabled)
select o.id, true, public._slug_for(o.business_name), o.business_name, true
from public.organizations o where not exists (select 1 from public.shop_online_settings s where s.org_id = o.id);

-- Commission and add-on billing stop: void open statements, unhide anything hidden for them, never switch the add-on off.
update public.commission_statements set status = 'void' where status in ('open', 'issued', 'overdue');
update public.shop_online_settings set listings_hidden_reason = null where listings_hidden_reason = 'commission_overdue';
create or replace function public.billing_daily()
returns void language plpgsql security definer set search_path to '' as $$
begin
  -- Commission statements and add-on fees were retired on 20 Nov 2026. Kept as a no-op so the cron job stays harmless.
  return;
end $$;

-- ---------------------------------------------------------------- listings: customer prices; food dishes may have no photo yet
create or replace function public.food_listings(p_category uuid default null, p_q text default null, p_org uuid default null, p_limit integer default 40, p_offset integer default 0)
returns table(id uuid, name text, price numeric, photo_url text, description text, in_stock boolean, delivery_size text, category_id uuid, category_name text, org_id uuid, shop_name text, shop_slug text)
language sql stable security definer set search_path to '' as $$
  select p.id, p.name, public.customer_price(p.price, 'food'), p.photo_url, p.description, p.stock > 0, p.delivery_size,
         c.id, c.name, p.org_id, coalesce(s.store_name, o.business_name), s.store_slug
  from public.products p
  join public.shop_online_settings s on s.org_id = p.org_id
  join public.organizations o on o.id = p.org_id and o.vertical = 'food'
  join public.market_categories c on c.id = p.market_category_id and c.active and c.vertical = 'food'
  where p.list_on_market and p.price > 0
    and public.shop_market_live(p.org_id)
    and (p_category is null or p.market_category_id in (select public.market_category_tree(p_category)))
    and (p_org is null or p.org_id = p_org)
    and (p_q is null or btrim(p_q) = '' or p.name ilike '%' || btrim(p_q) || '%' or p.description ilike '%' || btrim(p_q) || '%')
  order by (p.stock > 0) desc, (p.photo_url is not null) desc, p.updated_at desc nulls last, p.name
  limit least(greatest(coalesce(p_limit, 40), 1), 100) offset greatest(coalesce(p_offset, 0), 0);
$$;

create or replace function public.food_restaurants()
returns table(org_id uuid, name text, slug text, tagline text, logo_url text, dishes bigint)
language sql stable security definer set search_path to '' as $$
  select s.org_id, coalesce(s.store_name, o.business_name), s.store_slug, s.store_tagline, s.logo_url,
         (select count(*) from public.products p
            join public.market_categories c on c.id = p.market_category_id and c.active and c.vertical = 'food'
           where p.org_id = s.org_id and p.list_on_market and p.price > 0)
  from public.shop_online_settings s
  join public.organizations o on o.id = s.org_id
  where o.vertical = 'food' and public.shop_market_live(s.org_id)
  order by 2;
$$;

create or replace function public.market_listings(p_category uuid default null, p_q text default null, p_org uuid default null, p_limit integer default 40, p_offset integer default 0)
returns table(id uuid, name text, price numeric, photo_url text, description text, in_stock boolean, delivery_size text, category_id uuid, category_name text, org_id uuid, shop_name text, shop_slug text)
language sql stable security definer set search_path to '' as $$
  select p.id, p.name, public.customer_price(p.price, 'shop'), p.photo_url, p.description, p.stock > 0, p.delivery_size,
         c.id, c.name, p.org_id, coalesce(s.store_name, o.business_name), s.store_slug
  from public.products p
  join public.shop_online_settings s on s.org_id = p.org_id
  join public.organizations o on o.id = p.org_id
  join public.market_categories c on c.id = p.market_category_id and c.active and c.vertical = 'shop'
  where p.list_on_market and p.photo_url is not null and p.price > 0
    and public.shop_market_live(p.org_id)
    and (p_category is null or p.market_category_id in (select public.market_category_tree(p_category)))
    and (p_org is null or p.org_id = p_org)
    and (p_q is null or btrim(p_q) = '' or p.name ilike '%' || btrim(p_q) || '%' or p.description ilike '%' || btrim(p_q) || '%')
  order by (p.stock > 0) desc, p.updated_at desc nulls last, p.name
  limit least(greatest(coalesce(p_limit, 40), 1), 100) offset greatest(coalesce(p_offset, 0), 0);
$$;

create or replace function public.market_product(p_id uuid)
returns table(id uuid, name text, price numeric, photo_url text, description text, in_stock boolean, delivery_size text, category_id uuid, category_name text, org_id uuid, shop_name text, shop_slug text)
language sql stable security definer set search_path to '' as $$
  select p.id, p.name, public.customer_price(p.price, o.vertical), p.photo_url, p.description, p.stock > 0, p.delivery_size,
         c.id, c.name, p.org_id, coalesce(s.store_name, o.business_name), s.store_slug
  from public.products p
  join public.shop_online_settings s on s.org_id = p.org_id
  join public.organizations o on o.id = p.org_id
  join public.market_categories c on c.id = p.market_category_id and c.active
  where p.id = p_id and p.list_on_market and p.price > 0
    and (p.photo_url is not null or o.vertical = 'food')
    and public.shop_market_live(p.org_id);
$$;

create or replace function public.store_catalog(p_slug text)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare s public.shop_online_settings%rowtype; v_shop jsonb; v_products jsonb; v_vertical text;
begin
  select * into s from public.shop_online_settings where store_slug = lower(btrim(p_slug));
  if not found or not public.shop_store_live(s.org_id) then return null; end if;
  select vertical into v_vertical from public.organizations where id = s.org_id;
  select jsonb_build_object('org_id', s.org_id, 'slug', s.store_slug,
           'name', coalesce(s.store_name, o.business_name), 'tagline', s.store_tagline, 'logo_url', s.logo_url,
           'whatsapp', s.whatsapp_number, 'on_market', public.shop_market_live(s.org_id))
    into v_shop from public.organizations o where o.id = s.org_id;
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'price', public.customer_price(p.price, v_vertical),
           'photo_url', p.photo_url, 'description', p.description, 'category', p.category, 'in_stock', p.stock > 0,
           'delivery_size', p.delivery_size, 'age_restricted', public._is_alcohol_product(p.id)) order by p.category nulls last, p.name), '[]'::jsonb)
    into v_products from public.products p where p.org_id = s.org_id and p.show_online and p.price > 0;
  return jsonb_build_object('shop', v_shop, 'products', v_products);
end $$;

-- ---------------------------------------------------------------- placing an order: MoMo to NYANSATEK, markup, no delivery fee
create or replace function public.place_online_order(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare
  cfg public.market_settings%rowtype;
  s public.shop_online_settings%rowtype;
  v_channel text := p ->> 'channel';
  v_phone text := public.norm_phone(p -> 'customer' ->> 'phone');
  v_name text := btrim(coalesce(p -> 'customer' ->> 'name', ''));
  v_fulfil text := p ->> 'fulfilment';
  v_zone uuid; v_point uuid; v_addr text; v_landmark text;
  v_rank int := 0; v_vehicle text; v_vertical text;
  v_total numeric := 0; v_base numeric := 0; v_price numeric;
  v_lines jsonb := '[]'::jsonb; v_line jsonb;
  r record; v_prod public.products%rowtype;
  v_order uuid; v_code text; v_dcode text; v_token uuid; v_customer uuid; v_open int;
begin
  select * into cfg from public.market_settings where id;
  if v_channel is null or v_channel not in ('store', 'market') then raise exception 'Unknown order channel'; end if;

  if v_channel = 'store' then
    select * into s from public.shop_online_settings where store_slug = lower(btrim(p ->> 'store_slug'));
    if not found or not public.shop_store_live(s.org_id) then raise exception 'This shop is not taking online orders right now'; end if;
  else
    begin
      select * into s from public.shop_online_settings where org_id = (p ->> 'org_id')::uuid;
    exception when invalid_text_representation then raise exception 'Shop not found'; end;
    if not found or not public.shop_market_live(s.org_id) then raise exception 'This shop is not taking marketplace orders right now'; end if;
  end if;
  select vertical into v_vertical from public.organizations where id = s.org_id;

  if v_phone is null then raise exception 'Enter a valid Ghana phone number'; end if;
  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'Enter your name'; end if;
  select count(*) into v_open from public.online_orders
   where customer_phone = v_phone and status in ('placed','accepted','ready','in_transit','at_pickup_point');
  if v_open >= cfg.max_open_orders_per_phone then
    raise exception 'You already have % open orders. Please wait for them to finish.', v_open;
  end if;

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
       or (v_channel = 'market' and not (v_prod.list_on_market and v_prod.market_category_id is not null
                                          and (v_prod.photo_url is not null or v_vertical = 'food'))) then
      raise exception 'A product in your cart is no longer available';
    end if;
    if v_prod.price is null or v_prod.price <= 0 then raise exception '% is not for sale online', v_prod.name; end if;
    if coalesce(v_prod.stock, 0) < r.qty then
      raise exception 'Only % of % left', greatest(coalesce(v_prod.stock, 0), 0), v_prod.name; end if;
    v_price := public.customer_price(v_prod.price, v_vertical);
    v_total := v_total + v_price * r.qty;
    v_base := v_base + v_prod.price * r.qty;
    if public.vehicle_rank(v_prod.delivery_size) > v_rank then v_rank := public.vehicle_rank(v_prod.delivery_size); v_vehicle := v_prod.delivery_size; end if;
    v_lines := v_lines || jsonb_build_object('id', v_prod.id, 'name', v_prod.name, 'price', v_price, 'base', v_prod.price,
      'cost', v_prod.cost_price, 'qty', r.qty, 'size', v_prod.delivery_size, 'stock', v_prod.stock);
  end loop;

  if v_fulfil = 'delivery' then
    begin v_zone := (p ->> 'zone_id')::uuid; exception when invalid_text_representation then v_zone := null; end;
    if v_zone is null or not exists (select 1 from public.delivery_zones where id = v_zone and active) then
      raise exception 'Choose your delivery area'; end if;
    v_addr := btrim(coalesce(p ->> 'address', ''));
    v_landmark := nullif(btrim(coalesce(p ->> 'landmark', '')), '');
    if length(v_addr) < 5 or length(v_addr) > 300 then raise exception 'Enter your delivery address'; end if;
  elsif v_fulfil = 'pickup' then
    begin v_point := (p ->> 'pickup_point_id')::uuid; exception when invalid_text_representation then v_point := null; end;
    if v_point is null or not exists (select 1 from public.pickup_points where id = v_point and active) then
      raise exception 'Choose a pickup point'; end if;
  else
    raise exception 'Choose delivery or pickup';
  end if;

  if cfg.nyansatek_momo_number is null then raise exception 'Online payments are not set up yet'; end if;

  insert into public.market_customers (phone, name) values (v_phone, v_name)
  on conflict (phone) do update set name = excluded.name
  returning id into v_customer;
  if auth.uid() is not null then
    update public.market_customers set auth_user_id = auth.uid()
    where id = v_customer and auth_user_id is null
      and exists (select 1 from auth.users u where u.id = auth.uid() and coalesce(u.raw_user_meta_data ->> 'app', '') = 'market');
  end if;

  v_code := 'NS' || nextval('public.online_order_seq')::text;
  v_dcode := lpad((floor(random() * 10000))::int::text, 4, '0');

  insert into public.online_orders (code, org_id, channel, customer_id, customer_name, customer_phone, fulfilment,
      zone_id, address, landmark, pickup_point_id, vehicle, payment_method, momo_txn_id, goods_total, delivery_fee,
      commission_rate, commission_amount, base_total, markup_total, delivery_code, customer_note, accept_deadline, age_confirmed)
  values (v_code, s.org_id, v_channel, v_customer, v_name, v_phone, v_fulfil, v_zone, v_addr, v_landmark, v_point,
      v_vehicle, 'momo', nullif(btrim(coalesce(p ->> 'momo_txn_id', '')), ''), v_total, 0,
      0, 0, v_base, v_total - v_base, v_dcode, nullif(left(btrim(coalesce(p ->> 'note', '')), 300), ''),
      now() + make_interval(mins => cfg.accept_minutes), coalesce(p ->> 'age_confirmed', '') = 'true')
  returning id, track_token into v_order, v_token;

  for v_line in select * from jsonb_array_elements(v_lines) loop
    insert into public.online_order_items (order_id, product_id, name_snapshot, price_snapshot, base_price_snapshot, cost_price_snapshot, qty, line_total, delivery_size)
    values (v_order, (v_line ->> 'id')::uuid, v_line ->> 'name', (v_line ->> 'price')::numeric, (v_line ->> 'base')::numeric,
            (v_line ->> 'cost')::numeric, (v_line ->> 'qty')::int, (v_line ->> 'price')::numeric * (v_line ->> 'qty')::int, v_line ->> 'size');
    update public.products set stock = stock - (v_line ->> 'qty')::int where id = (v_line ->> 'id')::uuid;
    insert into public.inventory_log (org_id, product_id, product_name_snapshot, qty_added, stock_before, stock_after, note)
    values (s.org_id, (v_line ->> 'id')::uuid, v_line ->> 'name', -(v_line ->> 'qty')::int, (v_line ->> 'stock')::int,
            (v_line ->> 'stock')::int - (v_line ->> 'qty')::int, 'Online order ' || v_code || ' reserved');
  end loop;

  perform public._order_event(v_order, 'placed', 'customer', auth.uid(), null);

  return jsonb_build_object('order_id', v_order, 'code', v_code, 'track_token', v_token, 'status', 'placed',
    'goods_total', v_total, 'delivery_fee', 0, 'total', v_total, 'vehicle', v_vehicle, 'payment_method', 'momo',
    'momo_number', cfg.nyansatek_momo_number, 'momo_name', cfg.nyansatek_momo_name,
    'accept_deadline', now() + make_interval(mins => cfg.accept_minutes));
end $$;

create or replace function public.get_online_order(p_token uuid)
returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object(
    'code', o.code, 'status', o.status, 'channel', o.channel, 'created_at', o.created_at,
    'accept_deadline', o.accept_deadline, 'fulfilment', o.fulfilment, 'payment_method', o.payment_method,
    'payment_confirmed', o.payment_confirmed_at is not null, 'momo_txn_id', o.momo_txn_id,
    'goods_total', o.goods_total, 'delivery_fee', o.delivery_fee, 'total', o.goods_total + o.delivery_fee,
    'vehicle', o.vehicle, 'address', o.address, 'landmark', o.landmark, 'delivery_code', o.delivery_code,
    'pickup_deadline', o.pickup_deadline, 'cancel_reason', o.cancel_reason, 'customer_name', o.customer_name,
    'pay_to', jsonb_build_object('momo_number', m.nyansatek_momo_number, 'momo_name', m.nyansatek_momo_name),
    'courier', (select jsonb_build_object('name', c.name, 'phone', c.phone) from public.couriers c where c.id = o.courier_id),
    'shop', jsonb_build_object('name', coalesce(s.store_name, org.business_name), 'slug', s.store_slug,
                               'momo_number', m.nyansatek_momo_number, 'momo_name', m.nyansatek_momo_name, 'whatsapp', s.whatsapp_number),
    'zone', (select z.name from public.delivery_zones z where z.id = o.zone_id),
    'pickup_point', (select jsonb_build_object('name', pp.name, 'address', pp.address, 'landmark', pp.landmark,
                       'phone', pp.phone, 'hours', pp.hours) from public.pickup_points pp where pp.id = o.pickup_point_id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name_snapshot, 'price', i.price_snapshot,
                'qty', i.qty, 'line_total', i.line_total) order by i.name_snapshot), '[]'::jsonb)
              from public.online_order_items i where i.order_id = o.id),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('status', e.status, 'at', e.created_at) order by e.created_at), '[]'::jsonb)
               from public.online_order_events e where e.order_id = o.id and e.status not like '%\_ref\_%' and e.status not like 'sms\_%'))
  from public.online_orders o
  join public.organizations org on org.id = o.org_id
  left join public.shop_online_settings s on s.org_id = o.org_id
  cross join public.market_settings m
  where o.track_token = p_token and m.id;
$$;

-- Unpaid orders are cancelled once the payment window passes. Paid orders are never cancelled automatically.
create or replace function public.expire_unaccepted_orders()
returns integer language plpgsql security definer set search_path to '' as $$
declare r record; n int := 0;
begin
  for r in select id from public.online_orders
           where status = 'placed' and payment_confirmed_at is null and accept_deadline < now() for update skip locked loop
    perform public._cancel_order(r.id, 'Payment was not received in time', 'system', null);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Shops and restaurants on NYANSATEK software can still follow an order; they confirm only once NYANSATEK has the money.
create or replace function public.shop_order_action(p_order uuid, p_action text, p_note text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare o public.online_orders%rowtype; v_me uuid := auth.uid();
begin
  select * into o from public.online_orders where id = p_order for update;
  if not found or o.org_id is distinct from public.current_org_id()
     or not exists (select 1 from public.profiles where id = v_me and coalesce(is_active, true)) then
    raise exception 'Order not found'; end if;

  if p_action = 'accept' then
    if o.status <> 'placed' then raise exception 'This order is already %', o.status; end if;
    if o.payment_confirmed_at is null then raise exception 'NYANSATEK has not received the payment for this order yet'; end if;
    update public.online_orders set status = 'accepted', accepted_at = now() where id = o.id;
    perform public._order_event(o.id, 'accepted', 'shop', v_me, null);
  elsif p_action = 'reject' then
    if o.status <> 'placed' then raise exception 'This order is already %', o.status; end if;
    perform public._cancel_order(o.id, coalesce(nullif(btrim(p_note), ''), 'Rejected by the shop'), 'shop', v_me);
  elsif p_action = 'ready' then
    if o.status <> 'accepted' then raise exception 'Only accepted orders can be marked ready'; end if;
    update public.online_orders set status = 'ready', ready_at = now() where id = o.id;
    perform public._order_event(o.id, 'ready', 'shop', v_me, null);
  elsif p_action = 'cancel' then
    if o.status not in ('accepted', 'ready') then raise exception 'This order can no longer be cancelled by the shop'; end if;
    perform public._cancel_order(o.id, coalesce(nullif(btrim(p_note), ''), 'Cancelled by the shop'), 'shop', v_me);
  else
    raise exception 'Unknown action';
  end if;
  select * into o from public.online_orders where id = p_order;
  return jsonb_build_object('status', o.status, 'cash_status', o.cash_status);
end $$;

-- The sale recorded in the shop's books is at the shop's own prices.
create or replace function public._complete_order(p_order uuid, p_kind text, p_actor uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare o public.online_orders%rowtype; v_sale uuid; v_food boolean; v_total numeric;
begin
  select * into o from public.online_orders where id = p_order for update;
  if o.status = 'completed' then return; end if;
  select vertical = 'food' into v_food from public.organizations where id = o.org_id;
  v_total := coalesce(o.base_total, o.goods_total);
  insert into public.sales (org_id, invoice_id, cashier_id, payment_method, total, amount_tendered, change_due, cashier_name_snapshot, client_ref)
  values (o.org_id, o.code, null, 'Mobile Money', v_total, v_total, 0,
          case when o.channel = 'market' and coalesce(v_food, false) then 'nyansatek.food order'
               when o.channel = 'market' then 'nyansatek.store order'
               when coalesce(v_food, false) then 'Online menu order'
               else 'Online shop order' end,
          'online:' || o.id::text)
  on conflict (client_ref) do nothing
  returning id into v_sale;
  if v_sale is not null then
    insert into public.sale_items (sale_id, product_id, name_snapshot, price_snapshot, qty, line_total, cost_price_snapshot)
    select v_sale, product_id, name_snapshot, coalesce(base_price_snapshot, price_snapshot), qty,
           coalesce(base_price_snapshot, price_snapshot) * qty, coalesce(cost_price_snapshot, 0)
    from public.online_order_items where order_id = p_order;
  end if;
  update public.online_orders set status = 'completed', completed_at = now(), sale_id = coalesce(v_sale, sale_id) where id = p_order;
  perform public._order_event(p_order, 'completed', p_kind, p_actor, null);
end $$;

-- ---------------------------------------------------------------- automatic SMS: customers only
create or replace function public._order_event_sms()
returns trigger language plpgsql security definer set search_path to '' as $$
declare o public.online_orders%rowtype; s public.shop_online_settings%rowtype; cfg public.market_settings%rowtype;
        v_shop text; v_link text; v_total text; v_food boolean; v_pp text; v_courier text;
begin
  select * into o from public.online_orders where id = new.order_id;
  select * into s from public.shop_online_settings where org_id = o.org_id;
  select * into cfg from public.market_settings where id;
  select coalesce(s.store_name, business_name), vertical = 'food' into v_shop, v_food from public.organizations where id = o.org_id;
  v_food := coalesce(v_food, false);
  v_link := case when o.channel = 'market' and v_food then cfg.food_base_url || '/#/t/'
                 when o.channel = 'market' then cfg.market_base_url || '/#/t/'
                 when v_food then cfg.rest_base_url || '/menu/?t='
                 else cfg.store_base_url || '/shop/?t=' end || o.track_token::text;
  v_total := 'GHS' || to_char(o.goods_total + o.delivery_fee, 'FM999999990.00');
  select name into v_pp from public.pickup_points where id = o.pickup_point_id;
  select c.name || ' (0' || substr(c.phone, 4) || ')' into v_courier from public.couriers c where c.id = o.courier_id;

  if new.status = 'placed' then
    perform public._send_order_sms(o.customer_phone, format('Order %s with %s: pay %s by MoMo to 0%s (%s), then enter the transaction ID on your tracking page. We start your order once payment is confirmed. %s',
      o.code, v_shop, v_total, substr(cfg.nyansatek_momo_number, 4), cfg.nyansatek_momo_name, v_link));
  elsif new.status = 'paid' then
    perform public._send_order_sms(o.customer_phone, format('Payment received for order %s. We are placing it with %s now. %s', o.code, v_shop, v_link));
  elsif new.status = 'accepted' then
    perform public._send_order_sms(o.customer_phone, format('%s confirmed order %s. We will text you when it is on the way. %s', v_shop, o.code, v_link));
  elsif new.status = 'in_transit' and o.fulfilment = 'delivery' then
    perform public._send_order_sms(o.customer_phone, format('Order %s is on the way%s. The rider will call you. Pay the rider''s delivery fee when you receive it. %s',
      o.code, coalesce(' with ' || v_courier, ''), v_link));
  elsif new.status = 'at_pickup_point' then
    perform public._send_order_sms(o.customer_phone, format('Order %s is ready to collect at %s. Code %s. Collect by %s.',
      o.code, coalesce(v_pp, 'the pickup point'), o.delivery_code, to_char(o.pickup_deadline at time zone 'Africa/Accra', 'DD Mon HH24:MI')));
  elsif new.status in ('delivered', 'collected') then
    perform public._send_order_sms(o.customer_phone, format('Thank you! Order %s from %s is complete.', o.code, v_shop));
  elsif new.status = 'cancelled' then
    perform public._send_order_sms(o.customer_phone, format('Order %s with %s was cancelled: %s.%s', o.code, v_shop, coalesce(o.cancel_reason, 'cancelled'),
      case when o.payment_confirmed_at is not null then ' NYANSATEK will refund your MoMo payment.' else '' end));
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------- team actions (/ops)
create or replace function public.ops_order_action(p_order uuid, p_action text, p_note text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare o public.online_orders%rowtype; v_me uuid := auth.uid(); cfg public.market_settings%rowtype;
begin
  if not public.is_market_ops() then raise exception 'Team members only'; end if;
  select * into cfg from public.market_settings where id;
  select * into o from public.online_orders where id = p_order for update;
  if not found then raise exception 'Order not found'; end if;

  if p_action = 'paid' then
    if o.status <> 'placed' then raise exception 'This order is already %', o.status; end if;
    if o.payment_confirmed_at is not null then raise exception 'Payment is already marked as received'; end if;
    update public.online_orders set payment_confirmed_at = now(),
           momo_txn_id = coalesce(nullif(btrim(coalesce(p_note, '')), ''), momo_txn_id) where id = o.id;
    perform public._order_event(o.id, 'paid', 'team', v_me, nullif(btrim(coalesce(p_note, '')), ''));
  elsif p_action = 'confirmed' then
    if o.status <> 'placed' then raise exception 'This order is already %', o.status; end if;
    if o.payment_confirmed_at is null then raise exception 'Mark the payment as received first'; end if;
    update public.online_orders set status = 'accepted', accepted_at = now() where id = o.id;
    perform public._order_event(o.id, 'accepted', 'team', v_me, 'Placed with the shop by phone');
  elsif p_action = 'ready' then
    if o.status <> 'accepted' then raise exception 'Only confirmed orders can be marked ready'; end if;
    update public.online_orders set status = 'ready', ready_at = now() where id = o.id;
    perform public._order_event(o.id, 'ready', 'team', v_me, null);
  elsif p_action = 'on_the_way' then
    if o.status not in ('accepted', 'ready') then raise exception 'This order is not ready to go out'; end if;
    if o.fulfilment = 'delivery' and o.courier_id is null then raise exception 'Choose the courier first'; end if;
    if o.fulfilment = 'pickup' then
      update public.online_orders set status = 'at_pickup_point', at_pickup_at = now(),
             pickup_deadline = now() + make_interval(hours => cfg.pickup_hold_hours) where id = o.id;
      perform public._order_event(o.id, 'at_pickup_point', 'team', v_me, null);
    else
      update public.online_orders set status = 'in_transit' where id = o.id;
      perform public._order_event(o.id, 'in_transit', 'team', v_me, null);
    end if;
  elsif p_action = 'delivered' then
    if o.status not in ('accepted', 'ready', 'in_transit', 'at_pickup_point') then raise exception 'This order is already %', o.status; end if;
    if o.payment_confirmed_at is null then raise exception 'This order has not been paid'; end if;
    update public.online_orders set status = case when o.fulfilment = 'pickup' then 'collected' else 'delivered' end,
           delivered_at = now() where id = o.id;
    perform public._order_event(o.id, case when o.fulfilment = 'pickup' then 'collected' else 'delivered' end, 'team', v_me, null);
    perform public._complete_order(o.id, 'team', v_me);
  else
    raise exception 'Unknown action';
  end if;
  select * into o from public.online_orders where id = p_order;
  return jsonb_build_object('status', o.status, 'paid', o.payment_confirmed_at is not null);
end $$;

create or replace function public.ops_assign_courier(p_order uuid, p_courier uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare o public.online_orders%rowtype;
begin
  if not public.is_market_ops() then raise exception 'Team members only'; end if;
  select * into o from public.online_orders where id = p_order for update;
  if not found or o.status in ('completed', 'cancelled', 'returned', 'delivered', 'collected') then raise exception 'This order is closed'; end if;
  if p_courier is not null and not exists (select 1 from public.couriers where id = p_courier and active) then raise exception 'Courier not found'; end if;
  update public.online_orders set courier_id = p_courier, courier_assigned_at = case when p_courier is null then null else now() end where id = o.id;
  perform public._order_event(o.id, 'courier_' || case when p_courier is null then 'removed' else 'assigned' end, 'team', auth.uid(), null);
end $$;

-- The text of the SMS the team can send to the shop or the courier for an order (also used to preview it).
create or replace function public._order_sms_text(p_order uuid, p_to text)
returns text language plpgsql stable security definer set search_path to '' as $$
declare o public.online_orders%rowtype; s public.shop_online_settings%rowtype; v_shop text; v_items text; v_zone text; v_courier text;
begin
  select * into o from public.online_orders where id = p_order;
  select * into s from public.shop_online_settings where org_id = o.org_id;
  select coalesce(s.store_name, business_name) into v_shop from public.organizations where id = o.org_id;
  select string_agg(i.qty || ' x ' || i.name_snapshot, ', ' order by i.name_snapshot) into v_items from public.online_order_items i where i.order_id = o.id;
  select name into v_zone from public.delivery_zones where id = o.zone_id;
  select c.name || ' 0' || substr(c.phone, 4) into v_courier from public.couriers c where c.id = o.courier_id;
  if p_to = 'shop' then
    return format('NYANSATEK order %s: %s. Paid. You receive GHS%s at your prices by close of business.%s',
      o.code, v_items, to_char(coalesce(o.base_total, o.goods_total), 'FM999999990.00'),
      case when o.fulfilment = 'delivery' then ' Rider: ' || coalesce(v_courier, 'we will send one') || '.' else ' Customer collects.' end);
  elsif p_to = 'courier' then
    return format('NYANSATEK delivery %s. Pick up at %s%s%s. Deliver to %s 0%s, %s%s%s. Collect your delivery fee from the customer.',
      o.code, v_shop, coalesce(', ' || s.shop_address, ''), coalesce(' (0' || substr(coalesce(s.shop_phone, s.whatsapp_number), 4) || ')', ''),
      o.customer_name, substr(o.customer_phone, 4), coalesce(o.address, ''), coalesce(', ' || o.landmark, ''), coalesce(' (' || v_zone || ')', ''));
  end if;
  return null;
end $$;

create or replace function public.ops_order_sms(p_order uuid, p_to text, p_send boolean default true)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare o public.online_orders%rowtype; s public.shop_online_settings%rowtype; v_phone text; v_text text;
begin
  if not public.is_market_ops() then raise exception 'Team members only'; end if;
  select * into o from public.online_orders where id = p_order;
  if not found then raise exception 'Order not found'; end if;
  select * into s from public.shop_online_settings where org_id = o.org_id;
  if p_to = 'shop' then v_phone := coalesce(s.shop_phone, s.whatsapp_number, s.momo_number);
  elsif p_to = 'courier' then select phone into v_phone from public.couriers where id = o.courier_id;
  else raise exception 'Send to shop or courier'; end if;
  if v_phone is null then raise exception 'There is no phone number to send to'; end if;
  v_text := public._order_sms_text(p_order, p_to);
  if p_send then
    perform public._send_order_sms(v_phone, v_text);
    perform public._order_event(o.id, 'sms_' || p_to, 'team', auth.uid(), v_text);
  end if;
  return jsonb_build_object('to', v_phone, 'text', v_text, 'sent', p_send);
end $$;

-- What each shop is owed: delivered or collected, paid, not yet paid out. Grouped by business and day (Accra time).
create or replace function public.ops_payouts_due()
returns table(org_id uuid, name text, phone text, day date, orders_count bigint, amount numeric)
language sql stable security definer set search_path to '' as $$
  select o.org_id, coalesce(s.store_name, g.business_name), coalesce(s.momo_number, s.shop_phone, s.whatsapp_number),
         (coalesce(o.delivered_at, o.completed_at) at time zone 'Africa/Accra')::date, count(*), sum(coalesce(o.base_total, o.goods_total))
  from public.online_orders o
  join public.organizations g on g.id = o.org_id
  left join public.shop_online_settings s on s.org_id = o.org_id
  where public.is_market_ops() and o.payout_id is null and o.payment_confirmed_at is not null
    and o.status in ('delivered', 'collected', 'completed')
  group by 1, 2, 3, 4 order by 4, 2;
$$;

create or replace function public.ops_mark_payout(p_org uuid, p_day date, p_ref text, p_note text default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_id uuid; v_amount numeric; v_n int;
begin
  if not public.is_market_ops() then raise exception 'Team members only'; end if;
  select sum(coalesce(base_total, goods_total)), count(*) into v_amount, v_n from public.online_orders
   where org_id = p_org and payout_id is null and payment_confirmed_at is not null and status in ('delivered', 'collected', 'completed')
     and (coalesce(delivered_at, completed_at) at time zone 'Africa/Accra')::date = p_day;
  if coalesce(v_n, 0) = 0 then raise exception 'Nothing is owed for that day'; end if;
  insert into public.org_payouts (org_id, pay_date, amount, orders_count, momo_ref, note, paid_by)
  values (p_org, p_day, v_amount, v_n, nullif(btrim(coalesce(p_ref, '')), ''), nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;
  update public.online_orders set payout_id = v_id
   where org_id = p_org and payout_id is null and payment_confirmed_at is not null and status in ('delivered', 'collected', 'completed')
     and (coalesce(delivered_at, completed_at) at time zone 'Africa/Accra')::date = p_day;
  return jsonb_build_object('id', v_id, 'amount', v_amount, 'orders', v_n);
end $$;

revoke all on function public.ops_order_action(uuid, text, text), public.ops_assign_courier(uuid, uuid),
  public.ops_order_sms(uuid, text, boolean), public.ops_payouts_due(), public.ops_mark_payout(uuid, date, text, text),
  public._order_sms_text(uuid, text), public._slug_for(text), public._org_online_settings() from public, anon;
grant execute on function public.ops_order_action(uuid, text, text), public.ops_assign_courier(uuid, uuid),
  public.ops_order_sms(uuid, text, boolean), public.ops_payouts_due(), public.ops_mark_payout(uuid, date, text, text) to authenticated;

-- ---------------------------------------------------------------- couriers from the flyers collected in Obuasi on 19 Nov 2026
insert into public.couriers (name, company, phone, notes)
select v.name, v.company, public.norm_phone(v.phone), v.notes
from (values
  ('Adansi Delivery Service', 'Adansi Delivery Service', '0557208549', 'Also 0265 422 724 / 0203 385 985. Pickup, delivery, errands. ETS Fagumu, Obuasi. Motto: Move it fast.'),
  ('Classic Delivery Service', 'Classic Delivery Service', '0241385997', 'Calls and WhatsApp. Obuasi Anotobuasi, opposite Red Tardis. Food delivery and errands.'),
  ('Rider 1', 'Anytime Anywhere Delivery', '0539608474', 'Obuasi only. Complaints: 055 329 3090 / 050 919 6472.'),
  ('Rider 2', 'Anytime Anywhere Delivery', '0539742346', 'Obuasi only. Complaints: 055 329 3090 / 050 919 6472.'),
  ('Rider 3', 'Anytime Anywhere Delivery', '0539678622', 'Obuasi only. Complaints: 055 329 3090 / 050 919 6472.'),
  ('Rider 4', 'Anytime Anywhere Delivery', '0539682691', 'Obuasi only. Complaints: 055 329 3090 / 050 919 6472.')
) as v(name, company, phone, notes)
where not exists (select 1 from public.couriers c where c.phone = public.norm_phone(v.phone));
