-- The restaurant / shop page on nyansatek.food and nyansatek.store only needs the business to be listed
-- on the marketplace. It no longer depends on the business also having its own online shop switched on
-- (restaurants listed without our software, like Royal Kamay, have that switched off).
create or replace function public.market_shop(p_slug text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('org_id', s.org_id, 'slug', s.store_slug, 'name', coalesce(s.store_name, o.business_name),
           'tagline', s.store_tagline, 'logo_url', s.logo_url, 'on_market', true,
           'is_open', public.shop_is_open(s.org_id), 'opens_at', to_char(s.opens_at, 'HH24:MI'))
  from public.shop_online_settings s join public.organizations o on o.id = s.org_id
  where s.store_slug = lower(btrim(p_slug)) and public.shop_market_live(s.org_id)
$$;
grant execute on function public.market_shop(text) to anon, authenticated;
