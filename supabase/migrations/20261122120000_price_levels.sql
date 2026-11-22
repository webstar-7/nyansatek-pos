-- Price levels for Shop: Retail (products.price), Wholesale and Promo.
-- Wholesale/Promo are optional; empty means the till falls back to Retail.
alter table public.products add column if not exists wholesale_price numeric;
alter table public.products add column if not exists promo_price numeric;
do $$ begin
  if not exists (select 1 from pg_constraint where conname='products_tier_prices_nonneg') then
    alter table public.products add constraint products_tier_prices_nonneg
      check ((wholesale_price is null or wholesale_price >= 0) and (promo_price is null or promo_price >= 0));
  end if;
end $$;
-- Which level each line was sold at, so the owner can see wholesale/promo sales.
alter table public.sale_items add column if not exists price_level text not null default 'retail';
alter table public.credit_sale_items add column if not exists price_level text not null default 'retail';
