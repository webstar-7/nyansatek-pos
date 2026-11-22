-- Online price follows the Promo price when a product has one.
-- Online base = promo_price if set (> 0), otherwise price (Retail). Our markup is added on top,
-- and the business is paid the base, so a promo item is paid out at its promo price.
-- Wholesale is never used online.
create or replace function public.online_base_price(p_price numeric, p_promo numeric)
returns numeric language sql immutable as $$
  select case when p_promo is not null and p_promo > 0 then p_promo else p_price end
$$;

do $$
declare
  fn text; def text; old_def text;
  pats text[][] := array[
    array['market_listings', 'public.customer_price(p.price, ''shop'')', 'public.customer_price(public.online_base_price(p.price, p.promo_price), ''shop'')'],
    array['food_listings',   'public.customer_price(p.price, ''food'')', 'public.customer_price(public.online_base_price(p.price, p.promo_price), ''food'')'],
    array['market_product',  'public.customer_price(p.price, o.vertical)', 'public.customer_price(public.online_base_price(p.price, p.promo_price), o.vertical)'],
    array['store_catalog',   'public.customer_price(p.price, v_vertical)', 'public.customer_price(public.online_base_price(p.price, p.promo_price), v_vertical)'],
    array['place_online_order', 'v_price := public.customer_price(v_prod.price, v_vertical);', 'v_price := public.customer_price(public.online_base_price(v_prod.price, v_prod.promo_price), v_vertical);'],
    array['place_online_order', 'v_base := v_base + v_prod.price * r.qty;', 'v_base := v_base + public.online_base_price(v_prod.price, v_prod.promo_price) * r.qty;'],
    array['place_online_order', '''base'', v_prod.price,', '''base'', public.online_base_price(v_prod.price, v_prod.promo_price),']
  ];
  i int;
begin
  for i in 1 .. array_length(pats, 1) loop
    select pg_get_functiondef(p.oid) into old_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = pats[i][1];
    if old_def is null then raise exception 'function % not found', pats[i][1]; end if;
    if position(pats[i][3] in old_def) > 0 then continue; end if;  -- already patched
    if position(pats[i][2] in old_def) = 0 then raise exception 'pattern not found in %: %', pats[i][1], pats[i][2]; end if;
    execute replace(old_def, pats[i][2], pats[i][3]);
  end loop;
end $$;
