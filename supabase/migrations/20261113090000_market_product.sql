-- One marketplace listing by id (same visibility rules as market_listings)
create or replace function public.market_product(p_id uuid)
returns table (id uuid, name text, price numeric, photo_url text, description text, in_stock boolean,
               delivery_size text, category_id uuid, category_name text, org_id uuid, shop_name text, shop_slug text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.name, p.price, p.photo_url, p.description, p.stock > 0, p.delivery_size,
         c.id, c.name, p.org_id, coalesce(s.store_name, o.business_name), s.store_slug
  from public.products p
  join public.shop_online_settings s on s.org_id = p.org_id
  join public.organizations o on o.id = p.org_id
  join public.market_categories c on c.id = p.market_category_id and c.active
  where p.id = p_id and p.list_on_market and p.photo_url is not null and p.price > 0
    and public.shop_market_live(p.org_id);
$$;
revoke all on function public.market_product(uuid) from public;
grant execute on function public.market_product(uuid) to anon, authenticated;
