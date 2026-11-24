-- Campaign tracking for QR codes (e.g. ?src=door-thu). Each phone gets a random device id in the browser;
-- we count, per source: phones that visited, phones that installed the app, and baskets placed / paid.
-- No names or phone numbers are stored here.
create table if not exists public.campaign_events (
  id bigserial primary key,
  src text not null check (src ~ '^[a-z0-9-]{1,30}$'),
  site text not null check (site in ('store', 'food')),
  event text not null check (event in ('visit', 'install')),
  device_id uuid not null,
  created_at timestamptz not null default now(),
  unique (device_id, src, event)
);
alter table public.campaign_events enable row level security;
drop policy if exists campaign_events_ops on public.campaign_events;
create policy campaign_events_ops on public.campaign_events for select using (public.is_market_ops());

create or replace function public.log_campaign_event(p_src text, p_site text, p_event text, p_device uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_src !~ '^[a-z0-9-]{1,30}$' or p_site not in ('store', 'food') or p_event not in ('visit', 'install') or p_device is null then return; end if;
  insert into public.campaign_events (src, site, event, device_id) values (p_src, p_site, p_event, p_device)
  on conflict (device_id, src, event) do nothing;
end $$;
grant execute on function public.log_campaign_event(text, text, text, uuid) to anon, authenticated;

-- The basket remembers which QR code first brought the customer.
alter table public.online_checkouts add column if not exists source text;
do $$
declare d text := pg_get_functiondef('public.place_checkout'::regproc);
  o text := $o$  insert into public.online_checkouts (code, customer_name, customer_phone, vertical)
  values ('NC' || nextval('public.online_checkout_seq')::text, v_name, v_phone, coalesce(v_vertical, 'shop'))$o$;
  n text := $n$  insert into public.online_checkouts (code, customer_name, customer_phone, vertical, source)
  values ('NC' || nextval('public.online_checkout_seq')::text, v_name, v_phone, coalesce(v_vertical, 'shop'),
          case when coalesce(p ->> 'source', '') ~ '^[a-z0-9-]{1,30}$' then p ->> 'source' end)$n$;
begin
  if position(n in d) > 0 then return; end if;
  if position(o in d) = 0 then raise exception 'place_checkout insert not found'; end if;
  execute replace(d, o, n);
end $$;

-- Summary for /ops (team only).
create or replace function public.ops_campaigns(p_days int default 30)
returns table (src text, site text, phones bigint, installs bigint, baskets bigint, paid_baskets bigint, paid_total numeric, first_seen timestamptz)
language sql stable security definer set search_path = '' as $$
  with s as (
    select e.src, e.site from public.campaign_events e where e.created_at > now() - make_interval(days => p_days)
    union select c.source, case when c.vertical = 'food' then 'food' else 'store' end from public.online_checkouts c
      where c.source is not null and c.created_at > now() - make_interval(days => p_days))
  select s.src, s.site,
    (select count(distinct device_id) from public.campaign_events e where e.src = s.src and e.site = s.site and e.event = 'visit'),
    (select count(distinct device_id) from public.campaign_events e where e.src = s.src and e.site = s.site and e.event = 'install'),
    (select count(*) from public.online_checkouts c where c.source = s.src and (case when c.vertical = 'food' then 'food' else 'store' end) = s.site),
    (select count(*) from public.online_checkouts c where c.source = s.src and (case when c.vertical = 'food' then 'food' else 'store' end) = s.site
       and exists (select 1 from public.online_orders o where o.checkout_id = c.id and o.payment_confirmed_at is not null)),
    (select coalesce(sum(c.total), 0) from public.online_checkouts c where c.source = s.src and (case when c.vertical = 'food' then 'food' else 'store' end) = s.site
       and exists (select 1 from public.online_orders o where o.checkout_id = c.id and o.payment_confirmed_at is not null)),
    (select min(e.created_at) from public.campaign_events e where e.src = s.src and e.site = s.site)
  from s where public.is_market_ops()
  order by 8 desc nulls last
$$;
grant execute on function public.ops_campaigns(int) to authenticated;
