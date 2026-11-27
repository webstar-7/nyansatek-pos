-- 1) Food items with no price yet ("Ask for price"): listed on nyansatek.food with price 0,
--    never sold through checkout (place_online_order still refuses them); customers order them by phone.
create or replace function public.customer_price(p_price numeric, p_vertical text)
returns numeric language sql stable security definer set search_path to '' as $$
  select case when p_price is null then null
              when p_price <= 0 then 0
              when p_vertical = 'food' then p_price + m.food_markup_per_item
              else round(p_price * (1 + m.store_markup_rate), 2) end
  from public.market_settings m where m.id;
$$;

-- 2) Paying is simpler: the customer pays with MoMoPay and taps "I've paid" (the transaction ID is optional).
--    The team is texted to check the merchant account, and the order gets 30 more minutes before it can expire.
create or replace function public._customer_says_paid(p_orders uuid[], p_code text, p_total numeric, p_phone text, p_payer text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_payer text := public.norm_phone(p_payer); v_note text; v_n int; cfg public.market_settings%rowtype;
begin
  v_note := 'SAYS PAID' || case when v_payer is not null and v_payer <> p_phone then ' from ' || public._local_phone(v_payer) else '' end;
  update public.online_orders set momo_txn_id = case when momo_txn_id is null or momo_txn_id like 'SAYS PAID%' then v_note else momo_txn_id end,
         accept_deadline = greatest(accept_deadline, now() + interval '30 minutes')
   where id = any(p_orders) and status = 'placed' and payment_confirmed_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'This order can no longer be changed'; end if;
  select * into cfg from public.market_settings limit 1;
  if cfg.team_alert_phone is not null then
    perform public._send_order_sms(cfg.team_alert_phone, format('%s says PAID GHS%s from %s. Check the merchant MoMo, then mark paid in /ops.',
      p_code, to_char(p_total, 'FM999999990.00'), public._local_phone(coalesce(v_payer, p_phone))));
  end if;
end $$;
revoke all on function public._customer_says_paid(uuid[], text, numeric, text, text) from public, anon, authenticated;

create or replace function public.checkout_says_paid(p_token uuid, p_payer text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.online_checkouts%rowtype; v_ids uuid[]; v_total numeric;
begin
  select * into c from public.online_checkouts where track_token = p_token;
  if c.id is null then raise exception 'Order not found'; end if;
  select array_agg(id), sum(goods_total) into v_ids, v_total from public.online_orders where checkout_id = c.id and status <> 'cancelled';
  perform public._customer_says_paid(v_ids, c.code, v_total, c.customer_phone, p_payer);
end $$;
grant execute on function public.checkout_says_paid(uuid, text) to anon, authenticated;

create or replace function public.order_says_paid(p_token uuid, p_payer text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare o public.online_orders%rowtype;
begin
  select * into o from public.online_orders where track_token = p_token;
  if o.id is null then raise exception 'Order not found'; end if;
  perform public._customer_says_paid(array[o.id], o.code, o.goods_total, o.customer_phone, p_payer);
end $$;
grant execute on function public.order_says_paid(uuid, text) to anon, authenticated;

do $$
declare
  pats text[][] := array[
    array['food_listings', 'where p.list_on_market and p.price > 0', 'where p.list_on_market and p.price >= 0'],
    array['food_restaurants', 'p.list_on_market and p.price > 0', 'p.list_on_market and p.price >= 0'],
    array['market_product', 'where p.id = p_id and p.list_on_market and p.price > 0', 'where p.id = p_id and p.list_on_market and (p.price > 0 or o.vertical = ''food'')'],
    array['place_online_order', 'raise exception ''% is not for sale online'', v_prod.name', 'raise exception ''% has no price yet. Tap Order by phone and we will confirm the price.'', v_prod.name'],
    array['place_checkout', 'then enter the transaction ID on your tracking page.', 'then tap I''''ve paid on your tracking page.'],
    array['_order_event_sms', 'then enter the transaction ID on your tracking page.', 'then tap I''''ve paid on your tracking page.']
  ];
  i int; d text;
begin
  for i in 1 .. array_length(pats, 1) loop
    select pg_get_functiondef(p.oid) into d from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = pats[i][1];
    if position(pats[i][2] in d) = 0 then
      if position(pats[i][3] in d) > 0 then continue; end if;
      raise exception 'pattern not found in %: %', pats[i][1], pats[i][2];
    end if;
    execute replace(d, pats[i][2], pats[i][3]);
  end loop;
end $$;
