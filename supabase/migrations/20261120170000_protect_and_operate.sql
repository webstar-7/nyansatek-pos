-- Protecting the orders that come through NYANSATEK, and the tools the team needs to run them (20 Nov 2026).
-- 1. Customer details stay with NYANSATEK: shops read their online orders through shop_online_orders(), which
--    leaves out the customer's name, phone and address. They can no longer read online_orders directly.
-- 2. The restaurant's WhatsApp number is no longer given out by the public catalogue or order tracking.
-- 3. The team can edit any business's menu or products (and upload photos) from /ops.
-- 4. Opening hours and a pause switch per business: orders are refused while a business is closed.
-- 5. Refunds: a paid order that is cancelled is marked "refund due" until the team records the refund.
-- 6. An optional team phone gets an SMS for every new order.

-- 1 ---------------------------------------------------------------------------------------------
drop policy if exists online_orders_shop on public.online_orders;

create or replace function public.shop_online_orders(p_days int default 14)
returns jsonb language sql stable security definer set search_path to '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', o.id, 'code', o.code, 'status', o.status, 'channel', o.channel, 'created_at', o.created_at,
    'accept_deadline', o.accept_deadline, 'fulfilment', o.fulfilment, 'vehicle', o.vehicle,
    'zone', z.name, 'pickup_point', pp.name, 'payment_confirmed_at', o.payment_confirmed_at,
    'base_total', coalesce(o.base_total, o.goods_total), 'payout_id', o.payout_id, 'customer_note', o.customer_note,
    'cancel_reason', o.cancel_reason,
    'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name_snapshot, 'qty', i.qty,
                'price', coalesce(i.base_price_snapshot, i.price_snapshot)) order by i.name_snapshot), '[]'::jsonb)
              from public.online_order_items i where i.order_id = o.id)
  ) order by o.created_at desc), '[]'::jsonb)
  from public.online_orders o
  left join public.delivery_zones z on z.id = o.zone_id
  left join public.pickup_points pp on pp.id = o.pickup_point_id
  where public.current_org_id() is not null and o.org_id = public.current_org_id() and not public.is_kitchen()
    and exists (select 1 from public.profiles where id = auth.uid() and coalesce(is_active, true))
    and o.created_at > now() - make_interval(days => least(greatest(coalesce(p_days, 14), 1), 90));
$$;

create or replace function public.shop_payout_due()
returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('amount', coalesce(sum(coalesce(o.base_total, o.goods_total)), 0), 'orders', count(*))
  from public.online_orders o
  where public.current_org_id() is not null and o.org_id = public.current_org_id() and not public.is_kitchen()
    and o.payout_id is null and o.payment_confirmed_at is not null and o.status in ('delivered', 'collected', 'completed');
$$;
revoke all on function public.shop_online_orders(int), public.shop_payout_due() from public, anon;
grant execute on function public.shop_online_orders(int), public.shop_payout_due() to authenticated;

-- 2 ---------------------------------------------------------------------------------------------
create or replace function public.store_catalog(p_slug text)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare s public.shop_online_settings%rowtype; v_shop jsonb; v_products jsonb; v_vertical text;
begin
  select * into s from public.shop_online_settings where store_slug = lower(btrim(p_slug));
  if not found or not public.shop_store_live(s.org_id) then return null; end if;
  select vertical into v_vertical from public.organizations where id = s.org_id;
  select jsonb_build_object('org_id', s.org_id, 'slug', s.store_slug,
           'name', coalesce(s.store_name, o.business_name), 'tagline', s.store_tagline, 'logo_url', s.logo_url,
           'on_market', public.shop_market_live(s.org_id), 'is_open', public.shop_is_open(s.org_id),
           'opens_at', to_char(s.opens_at, 'HH24:MI'))
    into v_shop from public.organizations o where o.id = s.org_id;
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'price', public.customer_price(p.price, v_vertical),
           'photo_url', p.photo_url, 'description', p.description, 'category', p.category, 'in_stock', p.stock > 0,
           'delivery_size', p.delivery_size, 'age_restricted', public._is_alcohol_product(p.id)) order by p.category nulls last, p.name), '[]'::jsonb)
    into v_products from public.products p where p.org_id = s.org_id and p.show_online and p.price > 0;
  return jsonb_build_object('shop', v_shop, 'products', v_products);
end $$;

do $do$
declare d text;
begin
  d := pg_get_functiondef('public.get_online_order(uuid)'::regprocedure);
  d := replace(d, $x$, 'whatsapp', s.whatsapp_number)$x$, ')');
  if position('whatsapp' in d) > 0 then raise exception 'get_online_order still gives out WhatsApp'; end if;
  execute d;
end $do$;

-- 3 ---------------------------------------------------------------------------------------------
drop policy if exists products_ops on public.products;
create policy products_ops on public.products for all using (public.is_market_ops()) with check (public.is_market_ops());
drop policy if exists product_photos_ops_insert on storage.objects;
create policy product_photos_ops_insert on storage.objects for insert
  with check (bucket_id = 'product-photos' and public.is_market_ops());

-- 4 ---------------------------------------------------------------------------------------------
alter table public.shop_online_settings
  add column if not exists opens_at time,
  add column if not exists closes_at time,
  add column if not exists closed_days int[] not null default '{}',   -- ISO days: 1 Monday … 7 Sunday
  add column if not exists paused boolean not null default false;

create or replace function public.shop_is_open(p_org uuid)
returns boolean language sql stable security definer set search_path to '' as $$
  select coalesce((
    select case
      when s.paused then false
      when extract(isodow from now() at time zone 'Africa/Accra')::int = any(s.closed_days) then false
      when s.opens_at is null or s.closes_at is null then true
      when s.opens_at <= s.closes_at then (now() at time zone 'Africa/Accra')::time >= s.opens_at and (now() at time zone 'Africa/Accra')::time < s.closes_at
      else (now() at time zone 'Africa/Accra')::time >= s.opens_at or (now() at time zone 'Africa/Accra')::time < s.closes_at
    end
    from public.shop_online_settings s where s.org_id = p_org), true);
$$;

create or replace function public.shops_open_now()
returns table(org_id uuid, is_open boolean, opens_at text)
language sql stable security definer set search_path to '' as $$
  select s.org_id, public.shop_is_open(s.org_id), to_char(s.opens_at, 'HH24:MI')
  from public.shop_online_settings s
  where public.shop_market_live(s.org_id) or public.shop_store_live(s.org_id);
$$;
grant execute on function public.shop_is_open(uuid), public.shops_open_now() to anon, authenticated;

do $do$
declare d text;
begin
  d := pg_get_functiondef('public.place_online_order(jsonb)'::regprocedure);
  if position('shop_is_open' in d) > 0 then return; end if;
  d := replace(d, $x$  select vertical into v_vertical from public.organizations where id = s.org_id;
$x$, $x$  select vertical into v_vertical from public.organizations where id = s.org_id;
  if not public.shop_is_open(s.org_id) then
    raise exception '% is closed right now%', coalesce(s.store_name, 'This shop'), coalesce('. It opens at ' || to_char(s.opens_at, 'HH24:MI'), '');
  end if;
$x$);
  if position('shop_is_open' in d) = 0 then raise exception 'place_online_order was not patched for opening hours'; end if;
  execute d;
end $do$;

-- 5 ---------------------------------------------------------------------------------------------
alter table public.online_orders
  add column if not exists refund_status text not null default 'none' check (refund_status in ('none', 'due', 'refunded')),
  add column if not exists refund_ref text,
  add column if not exists refunded_at timestamptz;
update public.online_orders set refund_status = 'due'
 where status = 'cancelled' and payment_confirmed_at is not null and refund_status = 'none';

do $do$
declare d text;
begin
  d := pg_get_functiondef('public._cancel_order(uuid, text, text, uuid)'::regprocedure);
  if position('refund_status' in d) > 0 then return; end if;
  d := replace(d, $x$update public.online_orders set status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason where id = p_order;$x$,
                  $x$update public.online_orders set status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason,
         refund_status = case when payment_confirmed_at is not null then 'due' else refund_status end where id = p_order;$x$);
  if position('refund_status' in d) = 0 then raise exception '_cancel_order was not patched'; end if;
  execute d;
end $do$;

create or replace function public.ops_mark_refunded(p_order uuid, p_ref text)
returns void language plpgsql security definer set search_path to '' as $$
begin
  if not public.is_market_ops() then raise exception 'Team members only'; end if;
  update public.online_orders set refund_status = 'refunded', refund_ref = nullif(btrim(coalesce(p_ref, '')), ''), refunded_at = now()
   where id = p_order and refund_status = 'due';
  if not found then raise exception 'No refund is due on this order'; end if;
  perform public._order_event(p_order, 'refunded', 'team', auth.uid(), nullif(btrim(coalesce(p_ref, '')), ''));
end $$;
revoke all on function public.ops_mark_refunded(uuid, text) from public, anon;
grant execute on function public.ops_mark_refunded(uuid, text) to authenticated;

-- 6 ---------------------------------------------------------------------------------------------
alter table public.market_settings add column if not exists team_alert_phone text;

do $do$
declare d text;
begin
  d := pg_get_functiondef('public._order_event_sms()'::regprocedure);
  if position('team_alert_phone' in d) > 0 then return; end if;
  d := replace(d, $x$  if new.status = 'placed' then
$x$, $x$  if new.status = 'placed' and o.checkout_id is null and cfg.team_alert_phone is not null then
    perform public._send_order_sms(cfg.team_alert_phone, format('New order %s: %s, %s. Waiting for MoMo.', o.code, v_shop, v_total));
  end if;
  if new.status = 'placed' then
$x$);
  if position('team_alert_phone' in d) = 0 then raise exception '_order_event_sms was not patched for team alerts'; end if;
  execute d;
end $do$;

do $do$
declare d text;
begin
  d := pg_get_functiondef('public.place_checkout(jsonb)'::regprocedure);
  if position('team_alert_phone' in d) > 0 then return; end if;
  d := replace(d, $x$  return jsonb_build_object('code', v_code, 'track_token', v_token, 'total', v_total, 'orders', v_orders,$x$,
                  $x$  if cfg.team_alert_phone is not null then
    perform public._send_order_sms(cfg.team_alert_phone, format('New order %s: %s, GHS%s. Waiting for MoMo.', v_code, v_shops, to_char(v_total, 'FM999999990.00')));
  end if;
  return jsonb_build_object('code', v_code, 'track_token', v_token, 'total', v_total, 'orders', v_orders,$x$);
  if position('team_alert_phone' in d) = 0 then raise exception 'place_checkout was not patched for team alerts'; end if;
  execute d;
end $do$;

-- Royal Kamay does not use NYANSATEK software and does not share a link of its own: its own menu page is off.
update public.shop_online_settings s set store_enabled = false
  from public.organizations o where o.id = s.org_id and o.business_name = 'ROYAL KAMAY RESTAURANT';

-- 7. Customers pay the NYANSATEK VENTURES MoMo merchant account. They are shown the merchant ID (MoMoPay),
--    so they can see they are paying a registered business.
alter table public.market_settings add column if not exists nyansatek_momo_merchant_id text;
update public.market_settings set nyansatek_momo_number = '233591908151', nyansatek_momo_name = 'NYANSATEK VENTURES',
       nyansatek_momo_merchant_id = '316679';

do $do$
declare d text;
begin
  d := pg_get_functiondef('public.get_online_order(uuid)'::regprocedure);
  d := replace(d, $x$'pay_to', jsonb_build_object('momo_number', m.nyansatek_momo_number, 'momo_name', m.nyansatek_momo_name)$x$,
                  $x$'pay_to', jsonb_build_object('momo_number', m.nyansatek_momo_number, 'momo_name', m.nyansatek_momo_name, 'merchant_id', m.nyansatek_momo_merchant_id)$x$);
  if position('merchant_id' in d) = 0 then raise exception 'get_online_order was not patched for the merchant ID'; end if;
  execute d;
  d := pg_get_functiondef('public.get_checkout(uuid)'::regprocedure);
  d := replace(d, $x$'pay_to', jsonb_build_object('momo_number', m.nyansatek_momo_number, 'momo_name', m.nyansatek_momo_name)$x$,
                  $x$'pay_to', jsonb_build_object('momo_number', m.nyansatek_momo_number, 'momo_name', m.nyansatek_momo_name, 'merchant_id', m.nyansatek_momo_merchant_id)$x$);
  if position('merchant_id' in d) = 0 then raise exception 'get_checkout was not patched for the merchant ID'; end if;
  execute d;
  d := pg_get_functiondef('public._order_event_sms()'::regprocedure);
  d := replace(d, 'pay %s by MoMo to 0%s (%s), then enter', 'pay %s with MoMoPay to merchant ID %s (%s), then enter');
  d := replace(d, 'o.code, v_shop, v_total, substr(cfg.nyansatek_momo_number, 4), cfg.nyansatek_momo_name, v_link',
                  'o.code, v_shop, v_total, cfg.nyansatek_momo_merchant_id, cfg.nyansatek_momo_name, v_link');
  if position('merchant ID' in d) = 0 or position('cfg.nyansatek_momo_merchant_id' in d) = 0 then raise exception '_order_event_sms was not patched for the merchant ID'; end if;
  execute d;
  d := pg_get_functiondef('public.place_checkout(jsonb)'::regprocedure);
  d := replace(d, 'pay GHS%s by MoMo to 0%s (%s), then enter', 'pay GHS%s with MoMoPay to merchant ID %s (%s), then enter');
  d := replace(d, 'substr(cfg.nyansatek_momo_number, 4), cfg.nyansatek_momo_name, public._checkout_link(v_ck)',
                  'cfg.nyansatek_momo_merchant_id, cfg.nyansatek_momo_name, public._checkout_link(v_ck)');
  if position('merchant ID' in d) = 0 or position('cfg.nyansatek_momo_merchant_id' in d) = 0 then raise exception 'place_checkout was not patched for the merchant ID'; end if;
  execute d;
end $do$;
