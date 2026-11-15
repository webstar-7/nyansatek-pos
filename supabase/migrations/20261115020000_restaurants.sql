-- Restaurants on the shared database: nyansatek.rest (the restaurant's system, a sibling of
-- nyansatek.shop) and nyansatek.food (the ordering site, a sibling of nyansatek.store).
-- Everything here is additive. Existing shops, products, sales and orders keep their meaning:
-- every new column has a default that describes a shop.

-- ---------- which kind of business is this? --------------------------
alter table public.organizations
  add column if not exists vertical text not null default 'shop';
do $$ begin
  alter table public.organizations add constraint organizations_vertical_check check (vertical in ('shop', 'food'));
exception when duplicate_object then null; end $$;
comment on column public.organizations.vertical is
  'shop = uses nyansatek.shop and lists on nyansatek.store; food = restaurant/eatery, uses nyansatek.rest and lists on nyansatek.food';

-- ---------- categories belong to one site or the other ----------------
alter table public.market_categories
  add column if not exists vertical text not null default 'shop';
do $$ begin
  alter table public.market_categories add constraint market_categories_vertical_check check (vertical in ('shop', 'food'));
exception when duplicate_object then null; end $$;

-- ---------- where the food sites live (used in SMS links) -------------
alter table public.market_settings
  add column if not exists food_base_url text not null default 'https://nyansatek.food',
  add column if not exists rest_base_url text not null default 'https://nyansatek.rest';

-- ---------- till orders: eat-in / takeaway / delivery, table, kitchen --
-- All null for a shop sale. A restaurant sale starts at kitchen_status 'new'.
alter table public.sales
  add column if not exists order_type text,
  add column if not exists table_label text,
  add column if not exists order_note text,
  add column if not exists kitchen_status text,
  add column if not exists kitchen_updated_at timestamptz;
do $$ begin
  alter table public.sales add constraint sales_order_type_check check (order_type in ('eat_in', 'takeaway', 'delivery'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.sales add constraint sales_kitchen_status_check check (kitchen_status in ('new', 'preparing', 'ready', 'served'));
exception when duplicate_object then null; end $$;
create index if not exists sales_kitchen_open_idx on public.sales (org_id, created_at)
  where kitchen_status in ('new', 'preparing', 'ready');

-- ---------- dishes made to order ---------------------------------------
-- A dish cooked to order has no stock to count. The restaurant app shows a simple
-- Available / Sold out switch for it instead. So that every existing rule keeps working
-- unchanged ("stock > 0 means it can be sold", stock is taken off on each sale), the switch
-- is stored in the stock column: Sold out = 0, Available = 100000. The app tops it back up
-- to 100000 whenever the dish is switched on, and never shows the number.
alter table public.products
  add column if not exists made_to_order boolean not null default false;

-- ---------- listings: each site shows only its own kind ----------------
-- nyansatek.store: same function as before, now limited to shop categories.
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
  join public.market_categories c on c.id = p.market_category_id and c.active and c.vertical = 'shop'
  where p.list_on_market and p.photo_url is not null and p.price > 0
    and public.shop_market_live(p.org_id)
    and (p_category is null or p.market_category_id in (select public.market_category_tree(p_category)))
    and (p_org is null or p.org_id = p_org)
    and (p_q is null or btrim(p_q) = '' or p.name ilike '%' || btrim(p_q) || '%' or p.description ilike '%' || btrim(p_q) || '%')
  order by (p.stock > 0) desc, p.updated_at desc nulls last, p.name
  limit least(greatest(coalesce(p_limit, 40), 1), 100) offset greatest(coalesce(p_offset, 0), 0);
$$;

-- nyansatek.food: the same listing rules, for food categories.
create or replace function public.food_listings(p_category uuid default null, p_q text default null,
  p_org uuid default null, p_limit int default 40, p_offset int default 0)
returns table (id uuid, name text, price numeric, photo_url text, description text, in_stock boolean,
               delivery_size text, category_id uuid, category_name text, org_id uuid, shop_name text, shop_slug text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.name, p.price, p.photo_url, p.description, p.stock > 0, p.delivery_size,
         c.id, c.name, p.org_id, coalesce(s.store_name, o.business_name), s.store_slug
  from public.products p
  join public.shop_online_settings s on s.org_id = p.org_id
  join public.organizations o on o.id = p.org_id
  join public.market_categories c on c.id = p.market_category_id and c.active and c.vertical = 'food'
  where p.list_on_market and p.photo_url is not null and p.price > 0
    and public.shop_market_live(p.org_id)
    and (p_category is null or p.market_category_id in (select public.market_category_tree(p_category)))
    and (p_org is null or p.org_id = p_org)
    and (p_q is null or btrim(p_q) = '' or p.name ilike '%' || btrim(p_q) || '%' or p.description ilike '%' || btrim(p_q) || '%')
  order by (p.stock > 0) desc, p.updated_at desc nulls last, p.name
  limit least(greatest(coalesce(p_limit, 40), 1), 100) offset greatest(coalesce(p_offset, 0), 0);
$$;
grant execute on function public.food_listings(uuid, text, uuid, int, int) to anon, authenticated;

-- restaurants that are live on nyansatek.food, for the "Restaurants" row on its home page
create or replace function public.food_restaurants()
returns table (org_id uuid, name text, slug text, tagline text, logo_url text, dishes bigint)
language sql stable security definer set search_path = '' as $$
  select s.org_id, coalesce(s.store_name, o.business_name), s.store_slug, s.store_tagline, s.logo_url,
         (select count(*) from public.products p
            join public.market_categories c on c.id = p.market_category_id and c.active and c.vertical = 'food'
           where p.org_id = s.org_id and p.list_on_market and p.photo_url is not null and p.price > 0)
  from public.shop_online_settings s
  join public.organizations o on o.id = s.org_id
  where o.vertical = 'food' and public.shop_market_live(s.org_id)
  order by 2;
$$;
grant execute on function public.food_restaurants() to anon, authenticated;

-- ---------- order bookkeeping: name the right site ---------------------
create or replace function public._complete_order(p_order uuid, p_kind text, p_actor uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.online_orders%rowtype; v_sale uuid; v_food boolean;
begin
  select * into o from public.online_orders where id = p_order for update;
  if o.status = 'completed' then return; end if;
  select vertical = 'food' into v_food from public.organizations where id = o.org_id;
  insert into public.sales (org_id, invoice_id, cashier_id, payment_method, total, amount_tendered, change_due, cashier_name_snapshot, client_ref)
  values (o.org_id, o.code, null, case o.payment_method when 'momo' then 'Mobile Money' else 'Cash' end,
          o.goods_total, o.goods_total, 0,
          case when o.channel = 'market' and coalesce(v_food, false) then 'nyansatek.food order'
               when o.channel = 'market' then 'nyansatek.store order'
               when coalesce(v_food, false) then 'Online menu order'
               else 'Online shop order' end,
          'online:' || o.id::text)
  on conflict (client_ref) do nothing
  returning id into v_sale;
  if v_sale is not null then
    insert into public.sale_items (sale_id, product_id, name_snapshot, price_snapshot, qty, line_total, cost_price_snapshot)
    select v_sale, product_id, name_snapshot, price_snapshot, qty, line_total, coalesce(cost_price_snapshot, 0)
    from public.online_order_items where order_id = p_order;
  end if;
  update public.online_orders set status = 'completed', completed_at = now(), sale_id = coalesce(v_sale, sale_id) where id = p_order;
  perform public._order_event(p_order, 'completed', p_kind, p_actor, null);
end;
$$;

create or replace function public._order_event_sms()
returns trigger language plpgsql security definer set search_path = '' as $$
declare o public.online_orders%rowtype; s public.shop_online_settings%rowtype; cfg public.market_settings%rowtype;
        v_shop text; v_link text; v_shop_phone text; v_items int; v_pp text; v_total text; v_food boolean;
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
  v_shop_phone := coalesce(s.whatsapp_number, s.momo_number);
  v_total := 'GHS' || to_char(o.goods_total + o.delivery_fee, 'FM999999990.00');
  select coalesce(sum(qty), 0) into v_items from public.online_order_items where order_id = o.id;
  select name into v_pp from public.pickup_points where id = o.pickup_point_id;

  if new.status = 'placed' then
    perform public._send_order_sms(v_shop_phone, format('New %s order %s: %s items, %s, %s. Accept within %s min in %s > Orders.',
      case when o.channel = 'market' and v_food then 'nyansatek.food'
           when o.channel = 'market' then 'nyansatek.store'
           when v_food then 'online menu' else 'online shop' end, o.code, v_items, v_total,
      case o.payment_method when 'momo' then 'MoMo' else 'pay on delivery' end, cfg.accept_minutes,
      case when v_food then 'NYANSATEK Restaurant' else 'NYANSATEK POS' end));
    perform public._send_order_sms(o.customer_phone, format('Order %s placed with %s. %sTrack it: %s',
      o.code, v_shop, case o.payment_method when 'momo' then 'Pay ' || v_total || ' by MoMo to ' || coalesce('0' || substr(s.momo_number, 4), 'the shop') || '. ' else '' end, v_link));
  elsif new.status = 'accepted' then
    perform public._send_order_sms(o.customer_phone, format('%s confirmed order %s. We will text you when it is on the way. %s', v_shop, o.code, v_link));
  elsif new.status = 'in_transit' and o.fulfilment = 'delivery' then
    perform public._send_order_sms(o.customer_phone, format('Order %s is on the way. Give the rider code %s when you receive it. %s', o.code, o.delivery_code, v_link));
  elsif new.status = 'at_pickup_point' then
    perform public._send_order_sms(o.customer_phone, format('Order %s is ready to collect at %s. Code %s. Collect by %s or it returns to the shop.',
      o.code, coalesce(v_pp, 'the pickup point'), o.delivery_code, to_char(o.pickup_deadline at time zone 'Africa/Accra', 'DD Mon HH24:MI')));
  elsif new.status in ('delivered', 'collected') then
    perform public._send_order_sms(o.customer_phone, format('Thank you! Order %s from %s is complete.', o.code, v_shop));
  elsif new.status = 'cancelled' then
    perform public._send_order_sms(o.customer_phone, format('Order %s with %s was cancelled: %s.%s', o.code, v_shop, coalesce(o.cancel_reason, 'cancelled'),
      case when o.payment_method = 'momo' and o.payment_confirmed_at is not null then ' The shop will refund your MoMo payment.' else '' end));
  end if;
  return null;
end;
$$;
