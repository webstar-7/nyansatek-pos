-- market_settings holds the markup and payment settings. Only the NYANSATEK team (/ops) reads it;
-- database functions read it as the owner. It is no longer readable with the public key.
drop policy if exists market_settings_read on public.market_settings;
