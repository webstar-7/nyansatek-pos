-- One checkout for the customer (20 Nov 2026).
-- A customer's basket can hold dishes or products from several restaurants or shops. They check out once,
-- pay NYANSATEK once by MoMo and get one tracking link (code NC…). Behind it the basket is split into one
-- order per business (code NS…), so the team places, dispatches and pays out each business as before.
-- Paying for one part marks the whole checkout paid. The customer gets one SMS for "placed" and "paid".

create sequence if not exists public.online_checkout_seq start 1000;

create table if not exists public.online_checkouts (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  track_token uuid not null unique default gen_random_uuid(),
  customer_name text not null,
  customer_phone text not null,
  vertical text not null default 'shop',
  total numeric not null default 0,
  created_at timestamptz not null default now()
);
alter table public.online_checkouts enable row level security;
drop policy if exists online_checkouts_ops on public.online_checkouts;
create policy online_checkouts_ops on public.online_checkouts for all using (public.is_market_ops()) with check (public.is_market_ops());

-- a checkout of several shops counts as several open orders
update public.market_settings set max_open_orders_per_phone = greatest(max_open_orders_per_phone, 12);

alter table public.online_orders add column if not exists checkout_id uuid references public.online_checkouts(id) on delete set null;
create index if not exists online_orders_checkout_idx on public.online_orders (checkout_id);

-- place_online_order: accept the checkout it belongs to (only a checkout just made for the same phone).
do $do$
declare d text;
begin
  d := pg_get_functiondef('public.place_online_order(jsonb)'::regprocedure);
  if position('v_ck uuid' in d) > 0 then return; end if;
  d := replace(d, 'v_order uuid; v_code text; v_dcode text; v_token uuid; v_customer uuid; v_open int;',
                  'v_order uuid; v_code text; v_dcode text; v_token uuid; v_customer uuid; v_open int; v_ck uuid;');
  d := replace(d, $x$  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'Enter your name'; end if;$x$,
                  $x$  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'Enter your name'; end if;
  if p ? 'checkout_id' then
    begin v_ck := (p ->> 'checkout_id')::uuid; exception when invalid_text_representation then v_ck := null; end;
    if v_ck is null or not exists (select 1 from public.online_checkouts c where c.id = v_ck and c.customer_phone = v_phone
                                    and c.created_at > now() - interval '5 minutes') then
      raise exception 'Checkout not found'; end if;
  end if;$x$);
  d := replace(d, 'commission_rate, commission_amount, base_total, markup_total, delivery_code, customer_note, accept_deadline, age_confirmed)',
                  'commission_rate, commission_amount, base_total, markup_total, delivery_code, customer_note, accept_deadline, age_confirmed, checkout_id)');
  d := replace(d, $x$now() + make_interval(mins => cfg.accept_minutes), coalesce(p ->> 'age_confirmed', '') = 'true')
  returning id, track_token into v_order, v_token;$x$,
                  $x$now() + make_interval(mins => cfg.accept_minutes), coalesce(p ->> 'age_confirmed', '') = 'true', v_ck)
  returning id, track_token into v_order, v_token;$x$);
  if position('v_ck)' in d) = 0 or position('Checkout not found' in d) = 0 then raise exception 'place_online_order was not patched'; end if;
  execute d;
end $do$;

-- Customer SMS: a checkout sends one "placed" and one "paid" message itself, and one message if it expires unpaid.
do $do$
declare d text;
begin
  d := pg_get_functiondef('public._order_event_sms()'::regprocedure);
  if position('o.checkout_id' in d) > 0 then return; end if;
  d := replace(d, $x$  select * into o from public.online_orders where id = new.order_id;
$x$, $x$  select * into o from public.online_orders where id = new.order_id;
  if o.checkout_id is not null and (new.status in ('placed', 'paid') or (new.status = 'cancelled' and o.payment_confirmed_at is null)) then
    return null; end if;
$x$);
  if position('o.checkout_id' in d) = 0 then raise exception '_order_event_sms was not patched'; end if;
  execute d;
end $do$;

create or replace function public._checkout_link(p_checkout uuid)
returns text language sql stable security definer set search_path to '' as $$
  select case when c.vertical = 'food' then m.food_base_url else m.market_base_url end || '/#/k/' || c.track_token::text
  from public.online_checkouts c cross join public.market_settings m where c.id = p_checkout and m.id;
$$;

create or replace function public.place_checkout(p jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare cfg public.market_settings%rowtype; v_phone text := public.norm_phone(p -> 'customer' ->> 'phone');
        v_name text := btrim(coalesce(p -> 'customer' ->> 'name', '')); v_ck uuid; v_code text; v_token uuid;
        r record; v_res jsonb; v_total numeric := 0; v_orders jsonb := '[]'::jsonb; v_shops text; v_vertical text; v_n int := 0;
begin
  select * into cfg from public.market_settings where id;
  if v_phone is null then raise exception 'Enter a valid Ghana phone number'; end if;
  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'Enter your name'; end if;
  if jsonb_typeof(p -> 'items') is distinct from 'array' or jsonb_array_length(p -> 'items') = 0 then raise exception 'Your cart is empty'; end if;
  if jsonb_array_length(p -> 'items') > 60 then raise exception 'Too many items in one order'; end if;
  if (select count(distinct x ->> 'org_id') from jsonb_array_elements(p -> 'items') x) > 6 then
    raise exception 'Please order from at most 6 shops at a time'; end if;
  begin
    select o.vertical into v_vertical from public.organizations o where o.id = (p -> 'items' -> 0 ->> 'org_id')::uuid;
  exception when invalid_text_representation then raise exception 'Shop not found'; end;

  insert into public.online_checkouts (code, customer_name, customer_phone, vertical)
  values ('NC' || nextval('public.online_checkout_seq')::text, v_name, v_phone, coalesce(v_vertical, 'shop'))
  returning id, code, track_token into v_ck, v_code, v_token;

  for r in select x ->> 'org_id' as org, jsonb_agg(jsonb_build_object('product_id', x ->> 'product_id', 'qty', (x ->> 'qty')::int)) as items
           from jsonb_array_elements(p -> 'items') x group by x ->> 'org_id' order by min(x ->> 'org_id') loop
    v_res := public.place_online_order((p - 'items' - 'org_id' - 'store_slug' - 'checkout_id')
             || jsonb_build_object('channel', 'market', 'org_id', r.org, 'items', r.items, 'checkout_id', v_ck));
    v_total := v_total + (v_res ->> 'total')::numeric;
    v_orders := v_orders || jsonb_build_array(v_res ->> 'code');
    v_n := v_n + 1;
  end loop;
  update public.online_checkouts set total = v_total where id = v_ck;
  select string_agg(coalesce(s.store_name, g.business_name), ', ' order by o.code) into v_shops
    from public.online_orders o join public.organizations g on g.id = o.org_id left join public.shop_online_settings s on s.org_id = o.org_id
   where o.checkout_id = v_ck;

  perform public._send_order_sms(v_phone, format('Order %s (%s): pay GHS%s by MoMo to 0%s (%s), then enter the transaction ID on your tracking page. We start once payment is confirmed. %s',
    v_code, v_shops, to_char(v_total, 'FM999999990.00'), substr(cfg.nyansatek_momo_number, 4), cfg.nyansatek_momo_name, public._checkout_link(v_ck)));

  return jsonb_build_object('code', v_code, 'track_token', v_token, 'total', v_total, 'orders', v_orders,
    'momo_number', cfg.nyansatek_momo_number, 'momo_name', cfg.nyansatek_momo_name);
end $$;
grant execute on function public.place_checkout(jsonb) to anon, authenticated;

create or replace function public.get_checkout(p_token uuid)
returns jsonb language sql stable security definer set search_path to '' as $$
  select jsonb_build_object('code', c.code, 'created_at', c.created_at, 'total', c.total, 'customer_name', c.customer_name,
    'pay_to', jsonb_build_object('momo_number', m.nyansatek_momo_number, 'momo_name', m.nyansatek_momo_name),
    'payment_confirmed', not exists (select 1 from public.online_orders o where o.checkout_id = c.id and o.payment_confirmed_at is null and o.status <> 'cancelled')
                         and exists (select 1 from public.online_orders o where o.checkout_id = c.id and o.payment_confirmed_at is not null),
    'accept_deadline', (select min(o.accept_deadline) from public.online_orders o where o.checkout_id = c.id),
    'momo_txn_id', (select max(o.momo_txn_id) from public.online_orders o where o.checkout_id = c.id),
    'orders', (select coalesce(jsonb_agg(public.get_online_order(o.track_token) order by o.code), '[]'::jsonb)
               from public.online_orders o where o.checkout_id = c.id))
  from public.online_checkouts c cross join public.market_settings m
  where c.track_token = p_token and m.id;
$$;
grant execute on function public.get_checkout(uuid) to anon, authenticated;

create or replace function public.add_checkout_momo_ref(p_token uuid, p_txn text)
returns void language plpgsql security definer set search_path to '' as $$
declare v_ck uuid; v_n int;
begin
  select id into v_ck from public.online_checkouts where track_token = p_token;
  if v_ck is null then raise exception 'Order not found'; end if;
  if length(btrim(coalesce(p_txn, ''))) < 4 or length(p_txn) > 60 then raise exception 'Enter the MoMo transaction ID'; end if;
  update public.online_orders set momo_txn_id = btrim(p_txn) where checkout_id = v_ck and status = 'placed' and payment_confirmed_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'This order can no longer be changed'; end if;
end $$;
grant execute on function public.add_checkout_momo_ref(uuid, text) to anon, authenticated;

-- Marking a payment received: every unpaid part of the same checkout is paid by the same MoMo payment.
create or replace function public._mark_paid(p_order uuid, p_note text, p_actor uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare o public.online_orders%rowtype; r record; c public.online_checkouts%rowtype; v_shops text; v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select * into o from public.online_orders where id = p_order;
  for r in select id from public.online_orders
           where (id = p_order or (o.checkout_id is not null and checkout_id = o.checkout_id))
             and status = 'placed' and payment_confirmed_at is null for update loop
    update public.online_orders set payment_confirmed_at = now(), momo_txn_id = coalesce(v_note, momo_txn_id) where id = r.id;
    perform public._order_event(r.id, 'paid', 'team', p_actor, v_note);
  end loop;
  if o.checkout_id is not null then
    select * into c from public.online_checkouts where id = o.checkout_id;
    select string_agg(coalesce(s.store_name, g.business_name), ', ' order by x.code) into v_shops
      from public.online_orders x join public.organizations g on g.id = x.org_id left join public.shop_online_settings s on s.org_id = x.org_id
     where x.checkout_id = c.id and x.status <> 'cancelled';
    perform public._send_order_sms(c.customer_phone, format('Payment received for order %s. We are placing it with %s now. %s', c.code, v_shops, public._checkout_link(c.id)));
  end if;
end $$;
revoke all on function public._mark_paid(uuid, text, uuid), public._checkout_link(uuid) from public, anon;

do $do$
declare d text;
begin
  d := pg_get_functiondef('public.ops_order_action(uuid, text, text)'::regprocedure);
  if position('_mark_paid' in d) > 0 then return; end if;
  d := replace(d, $x$    update public.online_orders set payment_confirmed_at = now(),
           momo_txn_id = coalesce(nullif(btrim(coalesce(p_note, '')), ''), momo_txn_id) where id = o.id;
    perform public._order_event(o.id, 'paid', 'team', v_me, nullif(btrim(coalesce(p_note, '')), ''));$x$,
    $x$    perform public._mark_paid(o.id, p_note, v_me);$x$);
  if position('_mark_paid' in d) = 0 then raise exception 'ops_order_action was not patched'; end if;
  execute d;
end $do$;

-- Unpaid orders expire; a checkout that expires gets one SMS.
create or replace function public.expire_unaccepted_orders()
returns integer language plpgsql security definer set search_path to '' as $$
declare r record; n int := 0; v_cks uuid[] := '{}'; c public.online_checkouts%rowtype;
begin
  for r in select id, checkout_id from public.online_orders
           where status = 'placed' and payment_confirmed_at is null and accept_deadline < now() for update skip locked loop
    perform public._cancel_order(r.id, 'Payment was not received in time', 'system', null);
    if r.checkout_id is not null and not r.checkout_id = any(v_cks) then v_cks := v_cks || r.checkout_id; end if;
    n := n + 1;
  end loop;
  for c in select * from public.online_checkouts where id = any(v_cks) loop
    perform public._send_order_sms(c.customer_phone, format('Order %s was cancelled because payment was not received in time. You can order again any time.', c.code));
  end loop;
  return n;
end $$;

-- Checkout asks for the delivery area only (no street address): the rider calls the customer.
do $do$
declare d text;
begin
  d := pg_get_functiondef('public.place_online_order(jsonb)'::regprocedure);
  if position('Address is too long' in d) > 0 then return; end if;
  d := replace(d, $x$    if length(v_addr) < 5 or length(v_addr) > 300 then raise exception 'Enter your delivery address'; end if;$x$,
                  $x$    if length(v_addr) > 300 then raise exception 'Address is too long'; end if;$x$);
  if position('Address is too long' in d) = 0 then raise exception 'place_online_order address check was not patched'; end if;
  execute d;
end $do$;

-- Customer messages talk about their order, not about NYANSATEK placing it with the shop.
do $do$
declare d text;
begin
  d := pg_get_functiondef('public._order_event_sms()'::regprocedure);
  d := replace(d, $x$format('Payment received for order %s. We are placing it with %s now. %s', o.code, v_shop, v_link)$x$,
                  $x$format('Payment received for order %s. Your order is being prepared. %s', o.code, v_link)$x$);
  d := replace(d, $x$' NYANSATEK will refund your MoMo payment.'$x$, $x$' Your MoMo payment will be refunded.'$x$);
  if position('being prepared' in d) = 0 or position('will be refunded' in d) = 0 then raise exception '_order_event_sms wording was not patched'; end if;
  execute d;
end $do$;

create or replace function public._mark_paid(p_order uuid, p_note text, p_actor uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare o public.online_orders%rowtype; r record; c public.online_checkouts%rowtype; v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select * into o from public.online_orders where id = p_order;
  for r in select id from public.online_orders
           where (id = p_order or (o.checkout_id is not null and checkout_id = o.checkout_id))
             and status = 'placed' and payment_confirmed_at is null for update loop
    update public.online_orders set payment_confirmed_at = now(), momo_txn_id = coalesce(v_note, momo_txn_id) where id = r.id;
    perform public._order_event(r.id, 'paid', 'team', p_actor, v_note);
  end loop;
  if o.checkout_id is not null then
    select * into c from public.online_checkouts where id = o.checkout_id;
    perform public._send_order_sms(c.customer_phone, format('Payment received for order %s. Your order is being prepared. %s', c.code, public._checkout_link(c.id)));
  end if;
end $$;
revoke all on function public._mark_paid(uuid, text, uuid) from public, anon;

create or replace function public._order_sms_text(p_order uuid, p_to text)
returns text language plpgsql stable security definer set search_path to '' as $$
declare o public.online_orders%rowtype; s public.shop_online_settings%rowtype; v_shop text; v_items text; v_zone text; v_courier text;
begin
  select * into o from public.online_orders where id = p_order;
  select * into s from public.shop_online_settings where org_id = o.org_id;
  select coalesce(s.store_name, business_name) into v_shop from public.organizations where id = o.org_id;
  select string_agg(i.qty || ' x ' || i.name_snapshot, ', ' order by i.name_snapshot) into v_items from public.online_order_items i where i.order_id = o.id;
  select name into v_zone from public.delivery_zones where id = o.zone_id;
  select c.name || ' ' || public._local_phone(c.phone) into v_courier from public.couriers c where c.id = o.courier_id;
  if p_to = 'shop' then
    return format('NYANSATEK order %s: %s. Paid. You receive GHS%s at your prices by close of business.%s',
      o.code, v_items, to_char(coalesce(o.base_total, o.goods_total), 'FM999999990.00'),
      case when o.fulfilment = 'delivery' then ' Rider: ' || coalesce(v_courier, 'we will send one') || '.' else ' Customer collects.' end);
  elsif p_to = 'courier' then
    return format('NYANSATEK delivery %s. Pick up at %s. Deliver to %s. Call the customer for directions. Collect your delivery fee from the customer.',
      o.code, concat_ws(', ', v_shop, s.shop_address, public._local_phone(coalesce(s.shop_phone, s.whatsapp_number))),
      concat_ws(', ', o.customer_name || ' ' || public._local_phone(o.customer_phone), nullif(o.address, ''), o.landmark, v_zone));
  end if;
  return null;
end $$;
revoke all on function public._order_sms_text(uuid, text) from public, anon;
