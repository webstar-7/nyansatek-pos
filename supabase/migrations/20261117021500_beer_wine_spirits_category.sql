-- Marketplace category for alcoholic drinks (RITPACK SUPERMARKET's products listed here, 17 Nov 2026).
insert into public.market_categories (name, slug, sort, vertical)
select 'Beer, wine & spirits', 'beer-wine-spirits', coalesce((select sort from public.market_categories where slug='groceries'),0) + 1, 'shop'
where not exists (select 1 from public.market_categories where slug='beer-wine-spirits');
