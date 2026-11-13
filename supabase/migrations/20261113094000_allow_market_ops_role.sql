-- Team accounts for nyansatek.market (created by ops-accounts) use the market_ops role.
alter table public.profiles drop constraint profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role = any (array['master','admin','cashier','market_ops']));
