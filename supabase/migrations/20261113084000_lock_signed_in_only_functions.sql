-- Supabase grants EXECUTE on new public functions to anon by default.
-- These are for signed-in shop staff only (they also check the caller themselves).
-- Note: is_market_ops() must stay executable by anon: row-level policies on reference
-- tables (categories, zones, pickup points) call it for anonymous shoppers; it returns false for them.
revoke execute on function public.save_online_settings(jsonb), public.shop_order_action(uuid, text, text),
  public._rider_has_order(uuid), public._order_in_my_org(uuid)
  from anon;
