-- Phone numbers in SMS: show any stored format (233XXXXXXXXX or 0XXXXXXXXX) as 0XXXXXXXXX,
-- and store shop phone numbers in the usual 233 format.
create or replace function public._local_phone(p text)
returns text language sql immutable set search_path to '' as $$
  select case when p is null then null
              when p ~ '^233\d{9}$' then '0' || substr(p, 4)
              else p end;
$$;

update public.shop_online_settings set shop_phone = public.norm_phone(shop_phone)
 where shop_phone is not null and shop_phone !~ '^233\d{9}$' and public.norm_phone(shop_phone) is not null;
update public.shop_online_settings set whatsapp_number = public.norm_phone(whatsapp_number)
 where whatsapp_number is not null and whatsapp_number !~ '^233\d{9}$' and public.norm_phone(whatsapp_number) is not null;
update public.shop_online_settings set momo_number = public.norm_phone(momo_number)
 where momo_number is not null and momo_number !~ '^233\d{9}$' and public.norm_phone(momo_number) is not null;

create or replace function public._order_sms_text(p_order uuid, p_to text)
returns text language plpgsql stable security definer set search_path to '' as $$
declare o public.online_orders%rowtype; s public.shop_online_settings%rowtype; v_shop text; v_items text; v_zone text; v_courier text;
begin
  select * into o from public.online_orders where id = p_order;
  select * into s from public.shop_online_settings where org_id = o.org_id;
  select coalesce(s.store_name, business_name) into v_shop from public.organizations where id = o.org_id;
  select string_agg(i.qty || ' x ' || i.name_snapshot, ', ' order by i.name_snapshot) into v_items from public.online_order_items i where i.order_id = o.id;
  select name into v_zone from public.delivery_zones where id = o.zone_id;
  select c.name || ' ' || public._local_phone(c.phone) into v_courier from public.couriers c where c.id = o.courier_id;
  if p_to = 'shop' then
    return format('NYANSATEK order %s: %s. Paid. You receive GHS%s at your prices by close of business.%s',
      o.code, v_items, to_char(coalesce(o.base_total, o.goods_total), 'FM999999990.00'),
      case when o.fulfilment = 'delivery' then ' Rider: ' || coalesce(v_courier, 'we will send one') || '.' else ' Customer collects.' end);
  elsif p_to = 'courier' then
    return format('NYANSATEK delivery %s. Pick up at %s%s%s. Deliver to %s %s, %s%s%s. Collect your delivery fee from the customer.',
      o.code, v_shop, coalesce(', ' || s.shop_address, ''), coalesce(' (' || public._local_phone(coalesce(s.shop_phone, s.whatsapp_number)) || ')', ''),
      o.customer_name, public._local_phone(o.customer_phone), coalesce(o.address, ''), coalesce(', ' || o.landmark, ''), coalesce(' (' || v_zone || ')', ''));
  end if;
  return null;
end $$;
revoke all on function public._order_sms_text(uuid, text) from public, anon;
