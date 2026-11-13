-- The marketplace domain is nyansatek.store (nyansatek.market was not available).
-- Applied live by rewriting the two functions whose text mentioned nyansatek.market
-- (_complete_order, _order_event_sms) with nyansatek.store, then:
update public.market_settings set market_base_url = 'https://nyansatek.store' where id;
