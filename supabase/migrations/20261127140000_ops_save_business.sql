-- The team adds and edits restaurants and shops from /ops (Shops & restaurants), without our software.
-- A new business starts unlisted ('pending') until its menu or products are ready; the team then presses List.
create or replace function public.ops_save_business(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_name text := upper(btrim(regexp_replace(coalesce(p ->> 'name', ''), '\s+', ' ', 'g')));
  v_type text := case when p ->> 'type' = 'shop' then 'shop' else 'food' end;
  v_phone text := public.norm_phone(p ->> 'phone');
  v_momo text := public.norm_phone(coalesce(nullif(p ->> 'momo', ''), p ->> 'phone'));
  v_addr text := nullif(left(btrim(coalesce(p ->> 'address', '')), 200), '');
  v_open time; v_close time;
begin
  if not public.is_market_ops() then raise exception 'Only the NYANSATEK team can do this'; end if;
  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'Enter the business name'; end if;
  if v_phone is null then raise exception 'Enter a valid phone number for the business'; end if;
  if v_momo is null then raise exception 'Enter a valid MoMo number for payouts'; end if;
  begin v_open := nullif(p ->> 'opens_at', '')::time; v_close := nullif(p ->> 'closes_at', '')::time;
  exception when others then raise exception 'Check the opening hours'; end;
  if (v_open is null) <> (v_close is null) or v_open >= v_close then raise exception 'Opening time must be before closing time (or leave both empty)'; end if;
  if exists (select 1 from public.organizations where upper(business_name) = v_name and id is distinct from v_id) then
    raise exception '% is already on the list', v_name; end if;

  if v_id is null then
    insert into public.organizations (business_name, vertical, is_active, subscription_status) values (v_name, v_type, true, 'active') returning id into v_id;
    insert into public.stores (org_id, name) values (v_id, 'Main Store');
    insert into public.shop_online_settings (org_id, addon_active, store_enabled, marketplace_status) values (v_id, true, false, 'pending')
      on conflict (org_id) do update set store_enabled = false, marketplace_status = 'pending';
  else
    update public.organizations set business_name = v_name where id = v_id;
    if not found then raise exception 'Business not found'; end if;
  end if;
  update public.shop_online_settings set store_name = v_name, shop_phone = v_phone, whatsapp_number = v_phone, momo_number = v_momo,
         shop_address = v_addr, opens_at = v_open, closes_at = v_close,
         closed_days = coalesce((select array_agg(x::int) from jsonb_array_elements_text(coalesce(p -> 'closed_days', '[]'::jsonb)) x), '{}'),
         updated_at = now()
   where org_id = v_id;
  return v_id;
end $$;
revoke all on function public.ops_save_business(jsonb) from public, anon;
grant execute on function public.ops_save_business(jsonb) to authenticated;
