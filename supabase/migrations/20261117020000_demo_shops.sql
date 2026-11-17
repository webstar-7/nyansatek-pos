-- Demo shops (DEMO SHOP, DEMO RESTAURANT) can be browsed but never take real orders.
alter table public.shop_online_settings add column if not exists is_demo boolean not null default false;
create or replace function public._block_demo_orders() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.shop_online_settings where org_id = new.org_id and is_demo) then
    raise exception 'This is a demo shop for showing how ordering works, so it does not take real orders.';
  end if;
  return new;
end $$;
drop trigger if exists block_demo_orders on public.online_orders;
create trigger block_demo_orders before insert on public.online_orders for each row execute function public._block_demo_orders();
-- Applied live: is_demo set for DEMO (c27c451f…) and DEMO RESTAURANT (337be244…); DEMO's store set up as
-- demo-shop / "DEMO SHOP" with 12 products using the illustrations in /assets/demo/.
