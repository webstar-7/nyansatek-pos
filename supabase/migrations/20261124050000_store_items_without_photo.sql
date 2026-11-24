-- nyansatek.store lists products without a photo too (shown with the placeholder tile), as food already does.
-- Products with a photo are listed first.
do $$
declare
  pats text[][] := array[
    array['market_listings', 'where p.list_on_market and p.photo_url is not null and p.price > 0', 'where p.list_on_market and p.price > 0'],
    array['market_listings', 'order by (p.stock > 0) desc, p.updated_at desc nulls last, p.name', 'order by (p.stock > 0) desc, (p.photo_url is not null) desc, p.updated_at desc nulls last, p.name'],
    array['market_product', 'and (p.photo_url is not null or o.vertical = ''food'')', 'and true'],
    array['place_online_order', 'and (v_prod.photo_url is not null or v_vertical = ''food'')', 'and true']
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
