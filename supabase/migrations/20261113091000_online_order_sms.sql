-- SMS updates for online orders: the shop on every new order, the customer at each step.
-- Sends through the online-order-sms edge function with a shared secret kept in Vault
-- (secret name 'order_sms_secret'; same value set as the function's ORDER_SMS_SECRET).
alter table public.market_settings
  add column if not exists store_base_url text not null default 'https://nyansatek.shop',
  add column if not exists market_base_url text not null default 'https://nyansatek.market',
  add column if not exists sms_enabled boolean not null default true;

create or replace function public._send_order_sms(p_to text, p_message text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret text; v_on boolean;
begin
  select sms_enabled into v_on from public.market_settings where id;
  if not coalesce(v_on, false) or p_to is null or p_message is null then return; end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'order_sms_secret' limit 1;
  if v_secret is null then return; end if;
  perform net.http_post(
    url := 'https://kqwqbohoeltlbwcopeug.supabase.co/functions/v1/online-order-sms',
    body := jsonb_build_object('to', p_to, 'message', p_message),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-order-sms-secret', v_secret),
    timeout_milliseconds := 15000);
end;
$$;
revoke all on function public._send_order_sms(text, text) from public, anon, authenticated;

create or replace function public._order_event_sms()
returns trigger language plpgsql security definer set search_path = '' as $$
declare o public.online_orders%rowtype; s public.shop_online_settings%rowtype; cfg public.market_settings%rowtype;
        v_shop text; v_link text; v_shop_phone text; v_items int; v_pp text; v_total text;
begin
  select * into o from public.online_orders where id = new.order_id;
  select * into s from public.shop_online_settings where org_id = o.org_id;
  select * into cfg from public.market_settings where id;
  select coalesce(s.store_name, business_name) into v_shop from public.organizations where id = o.org_id;
  v_link := case o.channel when 'market' then cfg.market_base_url else cfg.store_base_url end || '/t/' || o.track_token::text;
  v_shop_phone := coalesce(s.whatsapp_number, s.momo_number);
  v_total := 'GHS' || to_char(o.goods_total + o.delivery_fee, 'FM999999990.00');
  select coalesce(sum(qty), 0) into v_items from public.online_order_items where order_id = o.id;
  select name into v_pp from public.pickup_points where id = o.pickup_point_id;

  if new.status = 'placed' then
    perform public._send_order_sms(v_shop_phone, format('New %s order %s: %s items, %s, %s. Accept within %s min in NYANSATEK POS > Orders.',
      case o.channel when 'market' then 'nyansatek.market' else 'online shop' end, o.code, v_items, v_total,
      case o.payment_method when 'momo' then 'MoMo' else 'pay on delivery' end, cfg.accept_minutes));
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
drop trigger if exists online_order_events_sms on public.online_order_events;
create trigger online_order_events_sms after insert on public.online_order_events
  for each row execute function public._order_event_sms();
