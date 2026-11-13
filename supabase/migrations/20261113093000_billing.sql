-- =====================================================================
-- Billing for the Online Shop add-on and the 5% marketplace commission.
-- Shops pay NYANSATEK by MoMo and enter the transaction ID; the team confirms in the dashboard.
-- Monthly commission statements are issued on the 1st, due after commission_due_days;
-- 3 days (overdue_grace_days) after the due date the shop's marketplace listings are hidden until paid.
-- An add-on not renewed 3 days after its paid-until date switches off (store page and listings hidden).
-- =====================================================================

alter table public.market_settings
  add column if not exists commission_due_days int not null default 7,
  add column if not exists addon_price_monthly numeric(10,2),
  add column if not exists addon_price_yearly numeric(10,2),
  add column if not exists nyansatek_momo_number text,
  add column if not exists nyansatek_momo_name text;

alter table public.commission_statements
  add column if not exists payment_submitted_at timestamptz,
  add column if not exists confirmed_by uuid;

-- payments for the add-on, submitted by the shop and confirmed by the team
create table if not exists public.addon_payments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id),
  period text not null check (period in ('monthly','yearly')),
  amount numeric(10,2) not null,
  momo_txn_id text not null,
  status text not null default 'submitted' check (status in ('submitted','confirmed','rejected')),
  submitted_by uuid, submitted_at timestamptz not null default now(),
  confirmed_by uuid, confirmed_at timestamptz, note text
);
alter table public.addon_payments enable row level security;
create policy addon_payments_shop on public.addon_payments for select using (org_id = public.current_org_id());
create policy addon_payments_ops on public.addon_payments for all using (public.is_market_ops()) with check (public.is_market_ops());
revoke all on public.addon_payments from anon, authenticated;
grant select on public.addon_payments to authenticated;

-- ---------- statements ----------
-- builds (or tops up) last month's statements; safe to run more than once
create or replace function public.generate_commission_statements(p_month date default (date_trunc('month', now() at time zone 'Africa/Accra') - interval '1 month')::date)
returns int language plpgsql security definer set search_path = '' as $$
declare cfg public.market_settings%rowtype; r record; v_stmt uuid; n int := 0;
  v_start timestamptz := (date_trunc('month', p_month)::timestamp at time zone 'Africa/Accra');
  v_end timestamptz := ((date_trunc('month', p_month) + interval '1 month')::timestamp at time zone 'Africa/Accra');
begin
  select * into cfg from public.market_settings where id;
  for r in select org_id, count(*) c, sum(goods_total) g, sum(commission_amount) cm
           from public.online_orders
           where channel = 'market' and status = 'completed' and statement_id is null
             and completed_at >= v_start and completed_at < v_end
           group by org_id loop
    insert into public.commission_statements (org_id, period_month, orders_count, goods_total, commission_amount, status, issued_at, due_date)
    values (r.org_id, date_trunc('month', p_month)::date, r.c, r.g, r.cm, 'issued', now(),
            (date_trunc('month', p_month) + interval '1 month')::date + cfg.commission_due_days)
    on conflict (org_id, period_month) do update set
      orders_count = public.commission_statements.orders_count + excluded.orders_count,
      goods_total = public.commission_statements.goods_total + excluded.goods_total,
      commission_amount = public.commission_statements.commission_amount + excluded.commission_amount,
      status = case when public.commission_statements.status = 'paid' then 'issued' else public.commission_statements.status end
    returning id into v_stmt;
    update public.online_orders set statement_id = v_stmt
     where org_id = r.org_id and channel = 'market' and status = 'completed' and statement_id is null
       and completed_at >= v_start and completed_at < v_end;
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- overdue statements; hide / restore marketplace listings; switch off lapsed add-ons
create or replace function public.billing_daily()
returns void language plpgsql security definer set search_path = '' as $$
declare cfg public.market_settings%rowtype; v_today date := (now() at time zone 'Africa/Accra')::date;
begin
  select * into cfg from public.market_settings where id;
  if extract(day from v_today) = 1 then perform public.generate_commission_statements(); end if;
  update public.commission_statements set status = 'overdue'
   where status = 'issued' and due_date < v_today and commission_amount > 0;
  update public.shop_online_settings s set listings_hidden_reason = 'commission_overdue'
   where listings_hidden_reason is null and exists (select 1 from public.commission_statements c
     where c.org_id = s.org_id and c.status = 'overdue' and c.due_date + cfg.overdue_grace_days < v_today);
  update public.shop_online_settings s set listings_hidden_reason = null
   where listings_hidden_reason = 'commission_overdue' and not exists (select 1 from public.commission_statements c
     where c.org_id = s.org_id and c.status = 'overdue' and c.due_date + cfg.overdue_grace_days < v_today);
  update public.shop_online_settings set addon_active = false
   where addon_active and addon_paid_through is not null and addon_paid_through + cfg.overdue_grace_days < v_today;
end;
$$;
revoke all on function public.generate_commission_statements(date), public.billing_daily() from public, anon, authenticated;
select cron.schedule('online-billing-daily', '15 0 * * *', $$select public.billing_daily()$$);   -- 00:15 UTC = 00:15 Accra

-- ---------- shop: pay a statement or the add-on (MoMo transaction ID) ----------
create or replace function public.shop_submit_payment(p_kind text, p_ref uuid, p_txn text, p_period text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.current_org_id(); cfg public.market_settings%rowtype; v_amt numeric;
begin
  if v_org is null or not public.is_shop_admin() then raise exception 'Only the shop admin can record payments'; end if;
  if length(btrim(coalesce(p_txn, ''))) < 4 then raise exception 'Enter the MoMo transaction ID'; end if;
  select * into cfg from public.market_settings where id;
  if p_kind = 'commission' then
    update public.commission_statements set payment_ref = btrim(p_txn), payment_method = 'momo', payment_submitted_at = now()
     where id = p_ref and org_id = v_org and status in ('issued','overdue');
    if not found then raise exception 'Statement not found or already paid'; end if;
  elsif p_kind = 'addon' then
    if p_period not in ('monthly','yearly') then raise exception 'Choose monthly or yearly'; end if;
    v_amt := case p_period when 'monthly' then cfg.addon_price_monthly else cfg.addon_price_yearly end;
    if v_amt is null then raise exception 'The add-on price has not been set yet. Contact NYANSATEK.'; end if;
    insert into public.addon_payments (org_id, period, amount, momo_txn_id, submitted_by)
    values (v_org, p_period, v_amt, btrim(p_txn), auth.uid());
  else raise exception 'Unknown payment';
  end if;
end;
$$;

-- ---------- team: confirm payments ----------
create or replace function public.ops_confirm_statement(p_statement uuid, p_paid boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_market_ops() then raise exception 'Team members only'; end if;
  if p_paid then
    update public.commission_statements set status = 'paid', paid_at = now(), confirmed_by = auth.uid()
     where id = p_statement and status in ('issued','overdue');
  else  -- payment not found: clear the submitted reference so the shop can try again
    update public.commission_statements set payment_ref = null, payment_submitted_at = null where id = p_statement and status <> 'paid';
  end if;
  perform public.billing_daily();   -- restores listings straight away when nothing else is overdue
end;
$$;

create or replace function public.ops_confirm_addon_payment(p_payment uuid, p_ok boolean, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare a public.addon_payments%rowtype; v_from date;
begin
  if not public.is_market_ops() then raise exception 'Team members only'; end if;
  select * into a from public.addon_payments where id = p_payment and status = 'submitted' for update;
  if not found then raise exception 'Payment not found'; end if;
  update public.addon_payments set status = case when p_ok then 'confirmed' else 'rejected' end,
         confirmed_by = auth.uid(), confirmed_at = now(), note = p_note where id = a.id;
  if p_ok then
    select greatest(coalesce(addon_paid_through, current_date), current_date) into v_from from public.shop_online_settings where org_id = a.org_id;
    insert into public.shop_online_settings (org_id, addon_active, addon_paid_through)
    values (a.org_id, true, (coalesce(v_from, current_date) + case a.period when 'monthly' then interval '1 month' else interval '1 year' end)::date)
    on conflict (org_id) do update set addon_active = true,
      addon_paid_through = (greatest(coalesce(public.shop_online_settings.addon_paid_through, current_date), current_date)
                            + case a.period when 'monthly' then interval '1 month' else interval '1 year' end)::date;
  end if;
end;
$$;

revoke all on function public.shop_submit_payment(text, uuid, text, text), public.ops_confirm_statement(uuid, boolean),
  public.ops_confirm_addon_payment(uuid, boolean, text) from public, anon;
grant execute on function public.shop_submit_payment(text, uuid, text, text), public.ops_confirm_statement(uuid, boolean),
  public.ops_confirm_addon_payment(uuid, boolean, text) to authenticated;
