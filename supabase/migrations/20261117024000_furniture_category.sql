-- Marketplace category for furniture (INSHA ALLAH RABEE's center tables and chair sets, 17 Nov 2026).
insert into public.market_categories (name, slug, sort, vertical)
select 'Furniture', 'furniture', coalesce((select sort from public.market_categories where slug='home-kitchen'),0) + 1, 'shop'
where not exists (select 1 from public.market_categories where slug='furniture');
