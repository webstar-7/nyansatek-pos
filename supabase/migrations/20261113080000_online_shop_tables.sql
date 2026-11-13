-- =====================================================================
-- Online Shop add-on + nyansatek.market — tables and access rules
-- Additive only: nothing here changes how the till works today.
-- Every shop starts switched off (shop_online_settings row absent / addon_active = false).
-- =====================================================================

-- ---------- helpers -------------------------------------------------
-- NYANSATEK team: full master, or the narrower marketplace operations role
create or replace function public.is_market_ops()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select role in ('master','market_ops') and coalesce(is_active, true)
                   from public.profiles where id = auth.uid()), false);
$$;

-- shop owner / admin of the caller's shop
create or replace function public.is_shop_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select role = 'admin' and coalesce(is_active, true) and org_id is not null
                   from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.vehicle_rank(v text)
returns int language sql immutable set search_path = '' as $$
  select case v when 'motorbike' then 1 when 'car' then 2 when 'van' then 3 when 'truck' then 4 end;
$$;

-- ---------- marketplace-wide settings (one row) ---------------------
create table if not exists public.market_settings (
  id boolean primary key default true check (id),
  commission_rate numeric(5,4) not null default 0.05,
  accept_minutes int not null default 10,
  pickup_hold_hours int not null default 24,
  overdue_grace_days int not null default 3,
  max_open_orders_per_phone int not null default 5,
  updated_at timestamptz not null default now()
);
insert into public.market_settings (id) values (true) on conflict do nothing;

-- ---------- per-shop online settings --------------------------------
create table if not exists public.shop_online_settings (
  org_id uuid primary key references public.organizations(id) on delete cascade,
  addon_active boolean not null default false,          -- set by billing / NYANSATEK only
  addon_paid_through date,
  store_slug text unique check (store_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(store_slug) between 3 and 60),
  store_name text,
  store_tagline text,
  logo_url text,
  momo_number text,
  momo_name text,
  whatsapp_number text,
  store_enabled boolean not null default true,           -- shop can pause its own store
  marketplace_status text not null default 'none'
    check (marketplace_status in ('none','pending','approved','suspended')),
  listings_hidden_reason text,                           -- e.g. 'commission_overdue'
  approved_at timestamptz,
  approved_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- product listing fields ----------------------------------
alter table public.products
  add column if not exists show_online boolean not null default false,
  add column if not exists list_on_market boolean not null default false,
  add column if not exists market_category_id uuid,
  add column if not exists delivery_size text not null default 'motorbike',
  add column if not exists description text;
do $$ begin
  alter table public.products add constraint products_delivery_size_check
    check (delivery_size in ('motorbike','car','van','truck'));
exception when duplicate_object then null; end $$;

-- ---------- marketplace categories ----------------------------------
create table if not exists public.market_categories (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references public.market_categories(id) on delete restrict,
  name text not null,
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  sort int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
do $$ begin
  alter table public.products add constraint products_market_category_fk
    foreign key (market_category_id) references public.market_categories(id) on delete set null;
exception when duplicate_object then null; end $$;

-- ---------- delivery zones, fees, pickup points ---------------------
create table if not exists public.delivery_zones (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text,
  active boolean not null default true,
  sort int not null default 0,
  created_at timestamptz not null default now()
);
create table if not exists public.delivery_zone_fees (
  zone_id uuid not null references public.delivery_zones(id) on delete cascade,
  vehicle text not null check (vehicle in ('motorbike','car','van','truck')),
  fee numeric(10,2) not null check (fee >= 0),
  primary key (zone_id, vehicle)
);
create table if not exists public.pickup_points (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text not null,
  landmark text,
  zone_id uuid references public.delivery_zones(id),
  phone text,
  hours text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- customers -----------------------------------------------
create table if not exists public.market_customers (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique,
  phone text not null unique,
  name text,
  created_at timestamptz not null default now()
);

-- ---------- orders ---------------------------------------------------
create sequence if not exists public.online_order_seq start 1001;

create table if not exists public.online_orders (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  org_id uuid not null references public.organizations(id),
  channel text not null check (channel in ('store','market')),
  customer_id uuid references public.market_customers(id),
  customer_name text not null,
  customer_phone text not null,
  fulfilment text not null check (fulfilment in ('delivery','pickup')),
  zone_id uuid references public.delivery_zones(id),
  address text,
  landmark text,
  pickup_point_id uuid references public.pickup_points(id),
  vehicle text not null check (vehicle in ('motorbike','car','van','truck')),
  payment_method text not null check (payment_method in ('momo','pod')),
  momo_txn_id text,
  payment_confirmed_at timestamptz,
  status text not null default 'placed' check (status in
    ('placed','accepted','ready','in_transit','at_pickup_point','delivered','collected',
     'completed','cancelled','returning','returned')),
  cash_status text not null default 'none' check (cash_status in ('none','with_rider','with_pickup_point','handed_to_shop')),
  goods_total numeric(12,2) not null,
  delivery_fee numeric(10,2) not null default 0,
  commission_rate numeric(5,4) not null default 0,
  commission_amount numeric(12,2) not null default 0,
  delivery_code text not null,
  track_token uuid not null unique default gen_random_uuid(),
  customer_note text,
  accept_deadline timestamptz not null,
  accepted_at timestamptz,
  ready_at timestamptz,
  at_pickup_at timestamptz,
  pickup_deadline timestamptz,
  delivered_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  sale_id uuid references public.sales(id),
  statement_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((fulfilment = 'delivery' and zone_id is not null and address is not null)
      or (fulfilment = 'pickup' and pickup_point_id is not null)),
  check (not (payment_method = 'pod' and vehicle = 'truck'))
);
create index if not exists online_orders_org_idx on public.online_orders (org_id, created_at desc);
create index if not exists online_orders_status_idx on public.online_orders (status, accept_deadline);
create index if not exists online_orders_phone_idx on public.online_orders (customer_phone);

create table if not exists public.online_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.online_orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  name_snapshot text not null,
  price_snapshot numeric(12,2) not null,
  cost_price_snapshot numeric(12,2),
  qty int not null check (qty between 1 and 999),
  line_total numeric(12,2) not null,
  delivery_size text not null
);
create index if not exists online_order_items_order_idx on public.online_order_items (order_id);

create table if not exists public.online_order_events (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.online_orders(id) on delete cascade,
  status text not null,
  actor_kind text not null check (actor_kind in ('customer','shop','rider','team','system')),
  actor_id uuid,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists online_order_events_order_idx on public.online_order_events (order_id, created_at);

-- ---------- riders and delivery jobs --------------------------------
create table if not exists public.riders (
  id uuid primary key,                          -- = auth user id
  full_name text not null,
  phone text not null unique,
  vehicle text not null check (vehicle in ('motorbike','car','van','truck')),
  plate_number text,
  zone_ids uuid[] not null default '{}',
  active boolean not null default true,
  online boolean not null default false,
  last_seen_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.delivery_jobs (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.online_orders(id) on delete cascade,
  kind text not null check (kind in ('to_customer','to_pickup_point','return_to_shop')),
  vehicle text not null check (vehicle in ('motorbike','car','van','truck')),
  zone_id uuid references public.delivery_zones(id),
  rider_id uuid references public.riders(id),
  status text not null default 'open' check (status in ('open','assigned','at_shop','picked_up','done','cancelled')),
  fee numeric(10,2) not null default 0,
  assigned_at timestamptz,
  picked_up_at timestamptz,
  done_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists delivery_jobs_open_idx on public.delivery_jobs (status, vehicle);
create unique index if not exists delivery_jobs_one_active_per_kind
  on public.delivery_jobs (order_id, kind) where status <> 'cancelled';

-- ---------- cash ledger ----------------------------------------------
create table if not exists public.cash_ledger (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.online_orders(id),
  org_id uuid not null references public.organizations(id),
  entry text not null check (entry in ('collected','handed_to_shop')),
  holder_kind text not null check (holder_kind in ('rider','pickup_point')),
  rider_id uuid references public.riders(id),
  pickup_point_id uuid references public.pickup_points(id),
  amount numeric(12,2) not null check (amount >= 0),
  recorded_by uuid,
  shop_confirmed_by uuid,
  shop_confirmed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists cash_ledger_order_idx on public.cash_ledger (order_id);

-- ---------- commission statements -----------------------------------
create table if not exists public.commission_statements (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id),
  period_month date not null check (extract(day from period_month) = 1),
  orders_count int not null default 0,
  goods_total numeric(12,2) not null default 0,
  commission_amount numeric(12,2) not null default 0,
  status text not null default 'open' check (status in ('open','issued','paid','overdue','void')),
  issued_at timestamptz,
  due_date date,
  paid_at timestamptz,
  payment_ref text,
  payment_method text,
  created_at timestamptz not null default now(),
  unique (org_id, period_month)
);
do $$ begin
  alter table public.online_orders add constraint online_orders_statement_fk
    foreign key (statement_id) references public.commission_statements(id);
exception when duplicate_object then null; end $$;

-- ---------- updated_at touches --------------------------------------
drop trigger if exists shop_online_settings_touch on public.shop_online_settings;
create trigger shop_online_settings_touch before update on public.shop_online_settings
  for each row execute function public.touch_updated_at();
drop trigger if exists online_orders_touch on public.online_orders;
create trigger online_orders_touch before update on public.online_orders
  for each row execute function public.touch_updated_at();

-- ---------- row level security ---------------------------------------
alter table public.market_settings        enable row level security;
alter table public.shop_online_settings   enable row level security;
alter table public.market_categories      enable row level security;
alter table public.delivery_zones         enable row level security;
alter table public.delivery_zone_fees     enable row level security;
alter table public.pickup_points          enable row level security;
alter table public.market_customers       enable row level security;
alter table public.online_orders          enable row level security;
alter table public.online_order_items     enable row level security;
alter table public.online_order_events    enable row level security;
alter table public.riders                 enable row level security;
alter table public.delivery_jobs          enable row level security;
alter table public.cash_ledger            enable row level security;
alter table public.commission_statements  enable row level security;

-- reference data everyone may read; only the team writes
create policy market_settings_read on public.market_settings for select using (true);
create policy market_settings_ops on public.market_settings for all using (public.is_market_ops()) with check (public.is_market_ops());
create policy market_categories_read on public.market_categories for select using (active or public.is_market_ops());
create policy market_categories_ops on public.market_categories for all using (public.is_market_ops()) with check (public.is_market_ops());
create policy delivery_zones_read on public.delivery_zones for select using (active or public.is_market_ops());
create policy delivery_zones_ops on public.delivery_zones for all using (public.is_market_ops()) with check (public.is_market_ops());
create policy delivery_zone_fees_read on public.delivery_zone_fees for select using (true);
create policy delivery_zone_fees_ops on public.delivery_zone_fees for all using (public.is_market_ops()) with check (public.is_market_ops());
create policy pickup_points_read on public.pickup_points for select using (active or public.is_market_ops());
create policy pickup_points_ops on public.pickup_points for all using (public.is_market_ops()) with check (public.is_market_ops());

-- shop settings: shop members read their own; changes go through save_online_settings(); team does everything
create policy shop_online_settings_own on public.shop_online_settings for select using (org_id = public.current_org_id());
create policy shop_online_settings_ops on public.shop_online_settings for all using (public.is_market_ops()) with check (public.is_market_ops());

-- customers: themselves + team
create policy market_customers_self on public.market_customers for select using (auth_user_id = auth.uid());
create policy market_customers_ops on public.market_customers for all using (public.is_market_ops()) with check (public.is_market_ops());

-- orders: the shop, the customer, the rider on the job, the team. Writes only through functions.
create policy online_orders_shop on public.online_orders for select using (org_id = public.current_org_id());
create policy online_orders_customer on public.online_orders for select using (
  customer_id in (select c.id from public.market_customers c where c.auth_user_id = auth.uid()));
create policy online_orders_rider on public.online_orders for select using (
  exists (select 1 from public.delivery_jobs j where j.order_id = online_orders.id and j.rider_id = auth.uid()));
create policy online_orders_ops on public.online_orders for all using (public.is_market_ops()) with check (public.is_market_ops());

create policy online_order_items_read on public.online_order_items for select using (
  exists (select 1 from public.online_orders o where o.id = online_order_items.order_id));   -- inherits the order's visibility
create policy online_order_items_ops on public.online_order_items for all using (public.is_market_ops()) with check (public.is_market_ops());
create policy online_order_events_read on public.online_order_events for select using (
  exists (select 1 from public.online_orders o where o.id = online_order_events.order_id));
create policy online_order_events_ops on public.online_order_events for all using (public.is_market_ops()) with check (public.is_market_ops());

-- riders: themselves + team
create policy riders_self on public.riders for select using (id = auth.uid());
create policy riders_ops on public.riders for all using (public.is_market_ops()) with check (public.is_market_ops());

-- delivery jobs: the assigned rider, the shop (for its orders), the team. Open jobs are listed through rider_open_jobs().
create policy delivery_jobs_rider on public.delivery_jobs for select using (rider_id = auth.uid());
create policy delivery_jobs_shop on public.delivery_jobs for select using (
  exists (select 1 from public.online_orders o where o.id = delivery_jobs.order_id and o.org_id = public.current_org_id()));
create policy delivery_jobs_ops on public.delivery_jobs for all using (public.is_market_ops()) with check (public.is_market_ops());

-- cash ledger: the rider's own entries, the shop's entries, the team
create policy cash_ledger_rider on public.cash_ledger for select using (rider_id = auth.uid());
create policy cash_ledger_shop on public.cash_ledger for select using (org_id = public.current_org_id());
create policy cash_ledger_ops on public.cash_ledger for all using (public.is_market_ops()) with check (public.is_market_ops());

-- commission statements: the shop reads its own, the team does everything
create policy commission_statements_shop on public.commission_statements for select using (org_id = public.current_org_id());
create policy commission_statements_ops on public.commission_statements for all using (public.is_market_ops()) with check (public.is_market_ops());

-- table privileges: browsers never write these tables directly
revoke all on public.market_settings, public.shop_online_settings, public.market_categories, public.delivery_zones,
  public.delivery_zone_fees, public.pickup_points, public.market_customers, public.online_orders, public.online_order_items,
  public.online_order_events, public.riders, public.delivery_jobs, public.cash_ledger, public.commission_statements
  from anon, authenticated;
grant select on public.market_settings, public.market_categories, public.delivery_zones, public.delivery_zone_fees,
  public.pickup_points to anon, authenticated;
grant select on public.shop_online_settings, public.market_customers, public.online_orders, public.online_order_items,
  public.online_order_events, public.riders, public.delivery_jobs, public.cash_ledger, public.commission_statements
  to authenticated;
-- the team edits reference data and settings directly (RLS limits it to is_market_ops())
grant insert, update, delete on public.market_settings, public.market_categories, public.delivery_zones,
  public.delivery_zone_fees, public.pickup_points, public.shop_online_settings, public.riders to authenticated;

-- ---------- logins for riders and marketplace customers get no till profile ----------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.raw_user_meta_data ->> 'app', '') in ('market', 'rider') then
    return new;   -- marketplace customers and riders are not till users
  end if;
  insert into public.profiles (id, role) values (new.id, 'cashier');
  return new;
end;
$$;
