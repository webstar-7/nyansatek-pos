-- Order by phone: "Call to order", "Send your order as a voice note" and "Call me back"
-- on nyansatek.store and nyansatek.food. Calls and voice notes come to NYANSATEK, never the business.

-- 1) Numbers that take orders, and the hours someone answers (Africa/Accra = UTC).
alter table public.market_settings add column if not exists order_phones text[] not null default array['233536340578'];
alter table public.market_settings add column if not exists phone_opens_at time not null default '09:00';
alter table public.market_settings add column if not exists phone_closes_at time not null default '21:00';

-- Public, read-only view of just what the storefront needs (market_settings itself is not public).
create or replace function public.phone_ordering()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'phones', coalesce((select jsonb_agg(public._local_phone(x)) from unnest(s.order_phones) x), '[]'::jsonb),
    'opens_at', to_char(s.phone_opens_at, 'HH24:MI'),
    'closes_at', to_char(s.phone_closes_at, 'HH24:MI'),
    'open_now', (now() at time zone 'Africa/Accra')::time >= s.phone_opens_at
                and (now() at time zone 'Africa/Accra')::time < s.phone_closes_at)
  from public.market_settings s limit 1
$$;
grant execute on function public.phone_ordering() to anon, authenticated;

-- 2) Voice notes and call-back requests waiting for the team.
create table if not exists public.order_requests (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('voice', 'callback')),
  site text not null default 'store' check (site in ('store', 'food')),
  customer_name text,
  phone text not null,
  location text,
  cart jsonb not null default '[]'::jsonb,
  audio_path text,
  audio_seconds int,
  status text not null default 'new' check (status in ('new', 'no_answer', 'done', 'spam')),
  team_note text,
  handled_by uuid references auth.users(id),
  handled_at timestamptz,
  checkout_code text,
  created_at timestamptz not null default now()
);
create index if not exists order_requests_status_idx on public.order_requests (status, created_at desc);
alter table public.order_requests enable row level security;
drop policy if exists order_requests_ops on public.order_requests;
create policy order_requests_ops on public.order_requests for all using (public.is_market_ops()) with check (public.is_market_ops());

-- 3) Private bucket for the recordings: anyone may upload a short audio file under new/,
--    only the team can listen.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('voice-orders', 'voice-orders', false, 3145728,
        array['audio/webm', 'audio/ogg', 'audio/mp4', 'audio/mpeg', 'audio/aac', 'audio/x-m4a', 'audio/wav'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists voice_orders_upload on storage.objects;
create policy voice_orders_upload on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'voice-orders' and (storage.foldername(name))[1] = 'new');
drop policy if exists voice_orders_team on storage.objects;
create policy voice_orders_team on storage.objects for select to authenticated
  using (bucket_id = 'voice-orders' and public.is_market_ops());

-- 4) The storefront submits a request through this function (no direct table access).
create or replace function public.submit_order_request(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_kind text := p ->> 'kind';
  v_site text := case when p ->> 'site' = 'food' then 'food' else 'store' end;
  v_phone text := public.norm_phone(p ->> 'phone');
  v_name text := nullif(left(btrim(coalesce(p ->> 'name', '')), 80), '');
  v_loc text := nullif(left(btrim(coalesce(p ->> 'location', '')), 200), '');
  v_audio text := nullif(p ->> 'audio_path', '');
  v_cart jsonb := case when jsonb_typeof(p -> 'cart') = 'array' then p -> 'cart' else '[]'::jsonb end;
  v_id uuid; cfg public.market_settings%rowtype; v_open boolean;
begin
  if v_kind not in ('voice', 'callback') then raise exception 'Unknown request'; end if;
  if v_phone is null then raise exception 'Enter a valid Ghana phone number'; end if;
  if v_kind = 'voice' then
    if v_audio is null or v_audio !~ '^new/[0-9a-f-]{36}\.(webm|ogg|m4a|mp4|mp3|aac|wav)$' then raise exception 'Record your voice note first'; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'voice-orders' and name = v_audio) then raise exception 'The voice note did not upload. Try again.'; end if;
  else
    v_audio := null;
  end if;
  if jsonb_array_length(v_cart) > 60 then v_cart := '[]'::jsonb; end if;
  if (select count(*) from public.order_requests where phone = v_phone and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'We already have your requests. The team will call you shortly.';
  end if;
  insert into public.order_requests (kind, site, customer_name, phone, location, cart, audio_path, audio_seconds)
  values (v_kind, v_site, v_name, v_phone, v_loc, v_cart, v_audio, least(greatest((p ->> 'seconds')::int, 0), 600))
  returning id into v_id;

  select * into cfg from public.market_settings limit 1;
  v_open := (now() at time zone 'Africa/Accra')::time >= cfg.phone_opens_at and (now() at time zone 'Africa/Accra')::time < cfg.phone_closes_at;
  if cfg.team_alert_phone is not null then
    perform public._send_order_sms(cfg.team_alert_phone, format('New %s on nyansatek.%s from %s%s. Open /ops, Phone orders.',
      case when v_kind = 'voice' then 'voice note order' else 'call-back request' end, v_site,
      public._local_phone(v_phone), coalesce(' (' || v_name || ')', '')));
  end if;
  return jsonb_build_object('id', v_id, 'open_now', v_open,
    'opens_at', to_char(cfg.phone_opens_at, 'HH24:MI'), 'closes_at', to_char(cfg.phone_closes_at, 'HH24:MI'));
end $$;
grant execute on function public.submit_order_request(jsonb) to anon, authenticated;
