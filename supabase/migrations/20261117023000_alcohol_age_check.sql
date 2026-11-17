-- Orders that include alcohol (Beer, wine & spirits) need the customer's 18+ confirmation; riders see an ID-check notice.
create or replace function public._is_alcohol_product(p_id uuid) returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.products p join public.market_categories c on c.id = p.market_category_id
                 left join public.market_categories pc on pc.id = c.parent_id
                 where p.id = p_id and 'beer-wine-spirits' in (c.slug, pc.slug));
$$;
create or replace function public._order_has_alcohol(p_order uuid) returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.online_order_items i where i.order_id = p_order and public._is_alcohol_product(i.product_id));
$$;
revoke execute on function public._is_alcohol_product(uuid), public._order_has_alcohol(uuid) from public, anon, authenticated;
alter table public.online_orders add column if not exists age_confirmed boolean not null default false;
create or replace function public._check_alcohol_age() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if public._is_alcohol_product(new.product_id)
     and not coalesce((select age_confirmed from public.online_orders where id = new.order_id), false) then
    raise exception 'This order has alcohol. Please confirm you are 18 or older.';
  end if;
  return new;
end $$;
drop trigger if exists check_alcohol_age on public.online_order_items;
create trigger check_alcohol_age before insert on public.online_order_items for each row execute function public._check_alcohol_age();
-- Applied live by text patches:
--  place_online_order: inserts age_confirmed = (p->>'age_confirmed' = 'true')
--  store_catalog: each product carries 'age_restricted' = _is_alcohol_product(id)
--  _job_view: adds 'age_check' = _order_has_alcohol(order)
