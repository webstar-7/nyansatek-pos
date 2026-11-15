-- =====================================================================
-- Screening for riders (NYANSATEK approves) and for shop / restaurant staff (the owner records it).
--
-- Ghana Card: we keep the card NUMBER and the RESULT of a biometric check done with the NIA
-- (who checked, when, by which NIA method). We never store a photo or scan of the card:
-- L.I. 2523 (National Identity Register (Amendment) Regulations, 2026) forbids keeping copies.
--
-- Riders: apply in the rider app -> automatic checks -> identity check -> validation ->
-- decision by the team. Only an approved rider is active, and only an active rider can go online.
-- Staff: a record per login, kept by the shop admin. It does not block the login.
-- =====================================================================

-- ---------- riders: the application and the screening result ----------
alter table public.riders
  add column if not exists screening_status text not null default 'applied'
    check (screening_status in ('applied','more_info','approved','rejected','suspended')),
  add column if not exists date_of_birth date,
  add column if not exists ghana_card_number text,
  add column if not exists residential_address text,
  add column if not exists digital_address text,
  add column if not exists licence_number text,
  add column if not exists licence_class text,
  add column if not exists licence_expiry date,
  add column if not exists roadworthy_expiry date,
  add column if not exists insurance_expiry date,
  add column if not exists momo_number text,
  add column if not exists momo_name text,
  add column if not exists guarantor_name text,
  add column if not exists guarantor_phone text,
  add column if not exists guarantor_relationship text,
  add column if not exists emergency_name text,
  add column if not exists emergency_phone text,
  add column if not exists selfie_path text,
  add column if not exists consent_at timestamptz,
  add column if not exists applied_at timestamptz,
  add column if not exists phone_verified_at timestamptz,
  add column if not exists id_check_result text not null default 'pending'
    check (id_check_result in ('pending','passed','failed')),
  add column if not exists id_check_method text
    check (id_check_method in ('nia_app','nia_platform','nia_card_reader')),
  add column if not exists id_check_at timestamptz,
  add column if not exists id_check_by uuid,
  add column if not exists id_check_ref text,
  add column if not exists licence_checked_at timestamptz,
  add column if not exists vehicle_docs_checked_at timestamptz,
  add column if not exists guarantor_checked_at timestamptz,
  add column if not exists momo_name_checked_at timestamptz,
  add column if not exists decision_at timestamptz,
  add column if not exists decision_by uuid,
  add column if not exists decision_note text,
  add column if not exists next_review_at date,
  add column if not exists expiry_reminded_at date;

alter table public.riders alter column active set default false;
create unique index if not exists riders_card_key on public.riders (ghana_card_number) where ghana_card_number is not null;

create table if not exists public.rider_screening_events (
  id bigint generated always as identity primary key,
  rider_id uuid not null references public.riders(id) on delete cascade,
  at timestamptz not null default now(),
  actor uuid,
  action text not null,
  note text
);
create index if not exists rider_screening_events_rider on public.rider_screening_events (rider_id, at desc);
alter table public.rider_screening_events enable row level security;
drop policy if exists rider_events_ops on public.rider_screening_events;
create policy rider_events_ops on public.rider_screening_events for select using (public.is_market_ops());
drop policy if exists no_kitchen_access on public.rider_screening_events;
create policy no_kitchen_access on public.rider_screening_events as restrictive for all to authenticated
  using (not (select public.is_kitchen()));

-- phone codes for applications (one row per phone; the code itself is never stored)
create table if not exists public.rider_phone_codes (
  phone text primary key,
  code_hash text not null,
  expires_at timestamptz not null,
  attempts int not null default 0,
  sent_count int not null default 1,
  window_start timestamptz not null default now(),
  verified_at timestamptz
);
alter table public.rider_phone_codes enable row level security;  -- no policies: reached only through the functions below

-- ---------- helpers ----------
-- 'gha 123456789 0' / 'GHA1234567890' -> 'GHA-123456789-0'; null when it is not a Ghana Card number
create or replace function public.norm_ghana_card(p text)
returns text language sql immutable set search_path = '' as $$
  select case when c ~ '^[A-Z]{3}[0-9]{10}$' then substr(c, 1, 3) || '-' || substr(c, 4, 9) || '-' || substr(c, 13, 1) else null end
  from (select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) as c) x;
$$;

create or replace function public._rider_event(p_rider uuid, p_action text, p_note text default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.rider_screening_events (rider_id, actor, action, note) values (p_rider, auth.uid(), p_action, nullif(btrim(coalesce(p_note, '')), ''));
$$;
revoke all on function public._rider_event(uuid, text, text) from public, anon, authenticated;

-- the automatic and manual checks for one rider, as the team and the rider see them.
-- 'blocks' = approval is refused while this check fails.
create or replace function public._rider_checks(r public.riders)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_agg(jsonb_build_object('key', k, 'label', l, 'ok', ok, 'blocks', b, 'kind', kind) order by ord)
  from (values
    (1, 'phone', 'Phone number confirmed', r.phone_verified_at is not null, true, 'auto'),
    (2, 'card_format', 'Ghana Card number is in the right format', public.norm_ghana_card(r.ghana_card_number) is not null, true, 'auto'),
    (3, 'age', 'Aged 18 or over', r.date_of_birth is not null and r.date_of_birth <= (current_date - interval '18 years'), true, 'auto'),
    (4, 'consent', 'Agreed to the checks', r.consent_at is not null, true, 'auto'),
    (5, 'selfie', 'Selfie taken', r.selfie_path is not null, true, 'auto'),
    (6, 'licence_date', 'Licence not expired', r.licence_expiry is not null and r.licence_expiry >= current_date, true, 'auto'),
    (7, 'docs_date', 'Roadworthy and insurance not expired',
        coalesce(r.roadworthy_expiry >= current_date, true) and coalesce(r.insurance_expiry >= current_date, true), true, 'auto'),
    (8, 'guarantor_phone', 'Guarantor has a different phone number',
        r.guarantor_phone is not null and r.guarantor_phone <> r.phone and r.guarantor_phone is distinct from r.emergency_phone, true, 'auto'),
    (9, 'plate', 'No other rider uses this plate number',
        r.plate_number is null or not exists (select 1 from public.riders o where o.id <> r.id
          and upper(regexp_replace(o.plate_number, '[^A-Za-z0-9]', '', 'g')) = upper(regexp_replace(r.plate_number, '[^A-Za-z0-9]', '', 'g'))), false, 'auto'),
    (20, 'identity', 'Identity confirmed with the NIA', r.id_check_result = 'passed', true, 'identity'),
    (30, 'licence', 'Licence seen and matches the rider', r.licence_checked_at is not null, true, 'manual'),
    (31, 'vehicle_docs', 'Vehicle, roadworthy and insurance seen', r.vehicle_docs_checked_at is not null, true, 'manual'),
    (32, 'guarantor', 'Guarantor called and agrees', r.guarantor_checked_at is not null, true, 'manual'),
    (33, 'momo_name', 'MoMo name matches the verified name', r.momo_name_checked_at is not null, true, 'manual')
  ) as t(ord, k, l, ok, b, kind);
$$;
revoke all on function public._rider_checks(public.riders) from public, anon, authenticated;

create or replace function public._rider_blockers(r public.riders)
returns text language sql stable security definer set search_path = '' as $$
  select string_agg(c ->> 'label', '; ') from jsonb_array_elements(public._rider_checks(r)) c
  where (c ->> 'blocks')::boolean and not (c ->> 'ok')::boolean;
$$;
revoke all on function public._rider_blockers(public.riders) from public, anon, authenticated;

-- only an approved rider can be active; only an active rider can be online; approval needs every check
create or replace function public.riders_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  if new.screening_status = 'approved' and (tg_op = 'INSERT' or old.screening_status <> 'approved') then
    v := public._rider_blockers(new);
    if v is not null then raise exception 'Cannot approve yet. Still to do: %', v; end if;
  end if;
  if new.screening_status <> 'approved' then new.active := false; end if;
  if not new.active then new.online := false; end if;
  return new;
end;
$$;
drop trigger if exists riders_guard on public.riders;
create trigger riders_guard before insert or update on public.riders for each row execute function public.riders_guard();

-- validate an application (new or edited); returns the cleaned fields
create or replace function public._rider_clean(p jsonb, p_phone text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  t text; v_name text; v_dob date; v_card text; v_addr text; v_veh text; v_plate text; v_lic text; v_lic_exp date;
  v_road date; v_ins date; v_momo text; v_gname text; v_gphone text; v_grel text; v_ename text; v_ephone text;
  d constant text := '^[0-9]{4}-[0-9]{2}-[0-9]{2}$';
begin
  v_name := nullif(left(btrim(coalesce(p ->> 'full_name', '')), 120), '');
  if v_name is null or v_name !~ '\S+\s+\S+' then raise exception 'Enter your full name exactly as it is on your Ghana Card'; end if;
  t := coalesce(p ->> 'date_of_birth', '');
  if t !~ d then raise exception 'Enter your date of birth'; end if;
  v_dob := t::date;
  if v_dob > (current_date - interval '18 years') then raise exception 'You must be 18 or older to ride for NYANSATEK'; end if;
  if v_dob < date '1930-01-01' then raise exception 'Check your date of birth'; end if;
  v_card := public.norm_ghana_card(p ->> 'ghana_card_number');
  if v_card is null then raise exception 'Enter your Ghana Card number like GHA-123456789-0'; end if;
  v_addr := nullif(left(btrim(coalesce(p ->> 'residential_address', '')), 300), '');
  if v_addr is null then raise exception 'Enter where you live'; end if;
  v_veh := coalesce(p ->> 'vehicle', '');
  if v_veh not in ('motorbike','car','van','truck') then raise exception 'Choose your vehicle'; end if;
  v_plate := nullif(upper(left(btrim(coalesce(p ->> 'plate_number', '')), 20)), '');
  if v_plate is null then raise exception 'Enter the vehicle''s number plate'; end if;
  v_lic := nullif(upper(left(btrim(coalesce(p ->> 'licence_number', '')), 40)), '');
  if v_lic is null then raise exception 'Enter your driver''s licence number'; end if;
  t := coalesce(p ->> 'licence_expiry', '');
  if t !~ d then raise exception 'Enter the date your licence expires'; end if;
  v_lic_exp := t::date;
  if v_lic_exp < current_date then raise exception 'Your licence has expired. Renew it, then apply.'; end if;
  t := coalesce(p ->> 'roadworthy_expiry', ''); if t ~ d then v_road := t::date; end if;
  t := coalesce(p ->> 'insurance_expiry', ''); if t ~ d then v_ins := t::date; end if;
  v_momo := public.norm_phone(p ->> 'momo_number');
  if v_momo is null then raise exception 'Enter the MoMo number you want to be paid on'; end if;
  v_gname := nullif(left(btrim(coalesce(p ->> 'guarantor_name', '')), 120), '');
  v_gphone := public.norm_phone(p ->> 'guarantor_phone');
  v_grel := nullif(left(btrim(coalesce(p ->> 'guarantor_relationship', '')), 60), '');
  if v_gname is null or v_gphone is null or v_grel is null then raise exception 'Enter your guarantor''s name, phone number and how they know you'; end if;
  if v_gphone = p_phone then raise exception 'Your guarantor must be another person with their own phone number'; end if;
  v_ename := nullif(left(btrim(coalesce(p ->> 'emergency_name', '')), 120), '');
  v_ephone := public.norm_phone(p ->> 'emergency_phone');
  if v_ename is null or v_ephone is null then raise exception 'Enter someone we can call in an emergency'; end if;
  if v_ephone = p_phone then raise exception 'The emergency contact must be another person'; end if;
  return jsonb_build_object('full_name', v_name, 'date_of_birth', v_dob, 'ghana_card_number', v_card, 'residential_address', v_addr,
    'digital_address', nullif(upper(left(btrim(coalesce(p ->> 'digital_address', '')), 20)), ''),
    'vehicle', v_veh, 'plate_number', v_plate, 'licence_number', v_lic,
    'licence_class', nullif(upper(left(btrim(coalesce(p ->> 'licence_class', '')), 10)), ''), 'licence_expiry', v_lic_exp,
    'roadworthy_expiry', v_road, 'insurance_expiry', v_ins, 'momo_number', v_momo,
    'momo_name', nullif(left(btrim(coalesce(p ->> 'momo_name', '')), 120), ''),
    'guarantor_name', v_gname, 'guarantor_phone', v_gphone, 'guarantor_relationship', v_grel,
    'emergency_name', v_ename, 'emergency_phone', v_ephone);
end;
$$;
revoke all on function public._rider_clean(jsonb, text) from public, anon, authenticated;

-- ---------- applying ----------
-- step 1 (anyone): send a 6-digit code to the phone. 3 codes an hour per phone, 120 an hour overall.
create or replace function public.rider_request_phone_code(p_phone text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_phone text := public.norm_phone(p_phone); v_code text; c public.rider_phone_codes%rowtype; v_recent int;
begin
  if v_phone is null then raise exception 'Enter a valid phone number'; end if;
  if exists (select 1 from public.riders where phone = v_phone) then
    raise exception 'This phone number already has a rider account. Sign in instead.'; end if;
  select * into c from public.rider_phone_codes where phone = v_phone for update;
  if found and c.window_start > now() - interval '1 hour' and c.sent_count >= 3 then
    raise exception 'Too many codes sent to this number. Try again in an hour.'; end if;
  select coalesce(sum(sent_count), 0) into v_recent from public.rider_phone_codes where window_start > now() - interval '1 hour';
  if v_recent >= 120 then raise exception 'We are busy right now. Please try again a little later.'; end if;
  v_code := lpad((abs(('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
  insert into public.rider_phone_codes as t (phone, code_hash, expires_at, attempts, sent_count, window_start, verified_at)
  values (v_phone, encode(extensions.digest(v_phone || ':' || v_code, 'sha256'), 'hex'), now() + interval '10 minutes', 0, 1, now(), null)
  on conflict (phone) do update set code_hash = excluded.code_hash, expires_at = excluded.expires_at, attempts = 0, verified_at = null,
    sent_count = case when t.window_start > now() - interval '1 hour' then t.sent_count + 1 else 1 end,
    window_start = case when t.window_start > now() - interval '1 hour' then t.window_start else now() end;
  perform public._send_order_sms(v_phone, format('NYANSATEK Rider: your code is %s. It works for 10 minutes. Do not share it.', v_code));
  return jsonb_build_object('sent', true);
end;
$$;

-- step 2 (server only): check the code. 5 wrong tries and the code is dead.
create or replace function public._rider_check_phone_code(p_phone text, p_code text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_phone text := public.norm_phone(p_phone); c public.rider_phone_codes%rowtype;
begin
  select * into c from public.rider_phone_codes where phone = v_phone for update;
  if not found or c.expires_at < now() or c.attempts >= 5 then return false; end if;
  if c.code_hash <> encode(extensions.digest(v_phone || ':' || regexp_replace(coalesce(p_code, ''), '[^0-9]', '', 'g'), 'sha256'), 'hex') then
    update public.rider_phone_codes set attempts = attempts + 1 where phone = v_phone;
    return false;
  end if;
  update public.rider_phone_codes set verified_at = now() where phone = v_phone;
  return true;
end;
$$;
revoke all on function public._rider_check_phone_code(text, text) from public, anon, authenticated;

-- step 3 (server only, after the login is created): store the application
create or replace function public._rider_create_application(p_id uuid, p_phone text, p jsonb, p_selfie_path text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_phone text := public.norm_phone(p_phone); v jsonb;
begin
  if v_phone is null then raise exception 'Enter a valid phone number'; end if;
  if not exists (select 1 from public.rider_phone_codes where phone = v_phone and verified_at > now() - interval '30 minutes') then
    raise exception 'Confirm your phone number first'; end if;
  if coalesce((p ->> 'consent')::boolean, false) is not true then raise exception 'You need to agree to the checks to apply'; end if;
  if p_selfie_path is null then raise exception 'Take a selfie to apply'; end if;
  v := public._rider_clean(p, v_phone);
  if exists (select 1 from public.riders where ghana_card_number = v ->> 'ghana_card_number') then
    raise exception 'This Ghana Card number is already on a rider application. Contact NYANSATEK if that is not you.'; end if;
  insert into public.riders (id, full_name, phone, vehicle, plate_number, screening_status, date_of_birth, ghana_card_number,
    residential_address, digital_address, licence_number, licence_class, licence_expiry, roadworthy_expiry, insurance_expiry,
    momo_number, momo_name, guarantor_name, guarantor_phone, guarantor_relationship, emergency_name, emergency_phone,
    selfie_path, consent_at, applied_at, phone_verified_at)
  values (p_id, v ->> 'full_name', v_phone, v ->> 'vehicle', v ->> 'plate_number', 'applied', (v ->> 'date_of_birth')::date, v ->> 'ghana_card_number',
    v ->> 'residential_address', v ->> 'digital_address', v ->> 'licence_number', v ->> 'licence_class', (v ->> 'licence_expiry')::date,
    (v ->> 'roadworthy_expiry')::date, (v ->> 'insurance_expiry')::date, v ->> 'momo_number', v ->> 'momo_name',
    v ->> 'guarantor_name', v ->> 'guarantor_phone', v ->> 'guarantor_relationship', v ->> 'emergency_name', v ->> 'emergency_phone',
    p_selfie_path, now(), now(), now());
  delete from public.rider_phone_codes where phone = v_phone;
  insert into public.rider_screening_events (rider_id, actor, action) values (p_id, p_id, 'applied');
end;
$$;
revoke all on function public._rider_create_application(uuid, text, jsonb, text) from public, anon, authenticated;

-- the rider corrects their application (while it is waiting, or when the team asked for more)
create or replace function public.rider_update_application(p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.riders%rowtype; v jsonb;
begin
  select * into r from public.riders where id = auth.uid() for update;
  if not found then raise exception 'Not a rider account'; end if;
  if r.screening_status not in ('applied','more_info') then raise exception 'Your details can no longer be changed here. Contact NYANSATEK.'; end if;
  v := public._rider_clean(p, r.phone);
  if exists (select 1 from public.riders where ghana_card_number = v ->> 'ghana_card_number' and id <> r.id) then
    raise exception 'This Ghana Card number is already on another rider application.'; end if;
  update public.riders set
    full_name = v ->> 'full_name', vehicle = v ->> 'vehicle', plate_number = v ->> 'plate_number',
    date_of_birth = (v ->> 'date_of_birth')::date, ghana_card_number = v ->> 'ghana_card_number',
    residential_address = v ->> 'residential_address', digital_address = v ->> 'digital_address',
    licence_number = v ->> 'licence_number', licence_class = v ->> 'licence_class', licence_expiry = (v ->> 'licence_expiry')::date,
    roadworthy_expiry = (v ->> 'roadworthy_expiry')::date, insurance_expiry = (v ->> 'insurance_expiry')::date,
    momo_number = v ->> 'momo_number', momo_name = v ->> 'momo_name',
    guarantor_name = v ->> 'guarantor_name', guarantor_phone = v ->> 'guarantor_phone', guarantor_relationship = v ->> 'guarantor_relationship',
    emergency_name = v ->> 'emergency_name', emergency_phone = v ->> 'emergency_phone',
    screening_status = 'applied', applied_at = now(),
    -- a changed detail has to be checked again
    id_check_result = case when ghana_card_number is distinct from v ->> 'ghana_card_number' or full_name is distinct from v ->> 'full_name'
                             or date_of_birth is distinct from (v ->> 'date_of_birth')::date then 'pending' else id_check_result end,
    licence_checked_at = case when licence_number is distinct from v ->> 'licence_number' or licence_expiry is distinct from (v ->> 'licence_expiry')::date then null else licence_checked_at end,
    vehicle_docs_checked_at = case when plate_number is distinct from v ->> 'plate_number' or vehicle is distinct from v ->> 'vehicle'
                             or roadworthy_expiry is distinct from (v ->> 'roadworthy_expiry')::date or insurance_expiry is distinct from (v ->> 'insurance_expiry')::date then null else vehicle_docs_checked_at end,
    guarantor_checked_at = case when guarantor_phone is distinct from v ->> 'guarantor_phone' or guarantor_name is distinct from v ->> 'guarantor_name' then null else guarantor_checked_at end,
    momo_name_checked_at = case when momo_number is distinct from v ->> 'momo_number' or momo_name is distinct from v ->> 'momo_name' then null else momo_name_checked_at end
  where id = r.id;
  perform public._rider_event(r.id, 'updated_by_rider');
end;
$$;

-- what the rider app shows: now includes the screening status and the application
create or replace function public.rider_me()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.riders%rowtype; v_cash numeric; v_fees numeric;
begin
  select * into r from public.riders where id = auth.uid();
  if not found then return null; end if;
  select coalesce(sum(case entry when 'collected' then amount else -amount end), 0) into v_cash
    from public.cash_ledger where rider_id = r.id and holder_kind = 'rider';
  select coalesce(sum(fee), 0) into v_fees from public.delivery_jobs
    where rider_id = r.id and status = 'done' and done_at >= date_trunc('day', now() at time zone 'Africa/Accra') at time zone 'Africa/Accra';
  return jsonb_build_object('id', r.id, 'name', r.full_name, 'phone', r.phone, 'vehicle', r.vehicle, 'plate', r.plate_number,
    'active', r.active, 'online', r.online, 'cash_on_hand', v_cash, 'fees_today', v_fees,
    'zones', (select coalesce(jsonb_agg(name order by name), '[]'::jsonb) from public.delivery_zones where id = any(r.zone_ids)),
    'screening_status', r.screening_status, 'decision_note', r.decision_note, 'applied_at', r.applied_at,
    'next_review_at', r.next_review_at,
    'expiring', (select jsonb_agg(x.what) from (values ('Driver''s licence', r.licence_expiry), ('Roadworthy', r.roadworthy_expiry), ('Insurance', r.insurance_expiry)) x(what, d)
                 where x.d is not null and x.d <= current_date + 14),
    'steps', jsonb_build_object('details', true, 'identity', r.id_check_result = 'passed',
       'validation', r.licence_checked_at is not null and r.vehicle_docs_checked_at is not null and r.guarantor_checked_at is not null and r.momo_name_checked_at is not null),
    'application', jsonb_build_object('full_name', r.full_name, 'date_of_birth', r.date_of_birth, 'ghana_card_number', r.ghana_card_number,
       'residential_address', r.residential_address, 'digital_address', r.digital_address, 'vehicle', r.vehicle, 'plate_number', r.plate_number,
       'licence_number', r.licence_number, 'licence_class', r.licence_class, 'licence_expiry', r.licence_expiry,
       'roadworthy_expiry', r.roadworthy_expiry, 'insurance_expiry', r.insurance_expiry, 'momo_number', r.momo_number, 'momo_name', r.momo_name,
       'guarantor_name', r.guarantor_name, 'guarantor_phone', r.guarantor_phone, 'guarantor_relationship', r.guarantor_relationship,
       'emergency_name', r.emergency_name, 'emergency_phone', r.emergency_phone));
end;
$$;

-- ---------- the team's review ----------
create or replace function public.ops_rider_review(p_rider uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.riders%rowtype;
begin
  if not public.is_market_ops() then raise exception 'Team members only'; end if;
  select * into r from public.riders where id = p_rider;
  if not found then raise exception 'Rider not found'; end if;
  return jsonb_build_object('rider', to_jsonb(r), 'checks', public._rider_checks(r), 'blockers', public._rider_blockers(r),
    'same_plate', (select coalesce(jsonb_agg(jsonb_build_object('name', o.full_name, 'phone', o.phone, 'status', o.screening_status)), '[]'::jsonb)
                   from public.riders o where o.id <> r.id and r.plate_number is not null
                     and upper(regexp_replace(o.plate_number, '[^A-Za-z0-9]', '', 'g')) = upper(regexp_replace(r.plate_number, '[^A-Za-z0-9]', '', 'g'))),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('at', e.at, 'action', e.action, 'note', e.note,
                      'by', coalesce(p.full_name, p.display_name, case when e.actor = r.id then 'the rider' when e.actor is null then 'system' else 'team' end)) order by e.at desc), '[]'::jsonb)
               from public.rider_screening_events e left join public.profiles p on p.id = e.actor where e.rider_id = r.id));
end;
$$;

-- record the result of the NIA biometric check. p_method: 'nia_app' | 'nia_platform' | 'nia_card_reader'
create or replace function public.ops_rider_id_check(p_rider uuid, p_result text, p_method text, p_ref text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_market_ops() then raise exception 'Team members only'; end if;
  if p_result not in ('passed','failed','pending') then raise exception 'Choose passed or failed'; end if;
  if p_result <> 'pending' and coalesce(p_method, '') not in ('nia_app','nia_platform','nia_card_reader') then
    raise exception 'Choose how the NIA check was done. Looking at the card is not a check.'; end if;
  update public.riders set id_check_result = p_result,
    id_check_method = case when p_result = 'pending' then null else p_method end,
    id_check_at = case when p_result = 'pending' then null else now() end,
    id_check_by = case when p_result = 'pending' then null else auth.uid() end,
    id_check_ref = case when p_result = 'pending' then null else nullif(left(btrim(coalesce(p_ref, '')), 80), '') end
  where id = p_rider and screening_status in ('applied','more_info');
  if not found then raise exception 'This application is not open for checks'; end if;
  perform public._rider_event(p_rider, 'identity_' || p_result, p_method);
end;
$$;

-- tick or untick a manual check. p_key: 'licence' | 'vehicle_docs' | 'guarantor' | 'momo_name' | 'phone'
create or replace function public.ops_rider_set_check(p_rider uuid, p_key text, p_ok boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare t timestamptz := case when p_ok then now() else null end;
begin
  if not public.is_market_ops() then raise exception 'Team members only'; end if;
  if p_key not in ('licence','vehicle_docs','guarantor','momo_name','phone') then raise exception 'Unknown check'; end if;
  update public.riders set
    licence_checked_at = case when p_key = 'licence' then t else licence_checked_at end,
    vehicle_docs_checked_at = case when p_key = 'vehicle_docs' then t else vehicle_docs_checked_at end,
    guarantor_checked_at = case when p_key = 'guarantor' then t else guarantor_checked_at end,
    momo_name_checked_at = case when p_key = 'momo_name' then t else momo_name_checked_at end,
    phone_verified_at = case when p_key = 'phone' then t else phone_verified_at end
  where id = p_rider and screening_status in ('applied','more_info');
  if not found then raise exception 'This application is not open for checks'; end if;
  perform public._rider_event(p_rider, p_key || case when p_ok then '_checked' else '_unchecked' end);
end;
$$;

-- p_action: 'approve' | 'more_info' | 'reject' | 'suspend' | 'reinstate' | 'reopen'
create or replace function public.ops_rider_decide(p_rider uuid, p_action text, p_note text default null, p_zone_ids uuid[] default null)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.riders%rowtype; v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), ''); v text;
begin
  if not public.is_market_ops() then raise exception 'Team members only'; end if;
  select * into r from public.riders where id = p_rider for update;
  if not found then raise exception 'Rider not found'; end if;

  if p_action in ('approve','reinstate') then
    if p_action = 'approve' and r.screening_status not in ('applied','more_info') then raise exception 'This application is already %', r.screening_status; end if;
    if p_action = 'reinstate' and r.screening_status <> 'suspended' then raise exception 'This rider is not suspended'; end if;
    v := public._rider_blockers(r);
    if v is not null then raise exception 'Cannot approve yet. Still to do: %', v; end if;
    update public.riders set screening_status = 'approved', active = true, decision_at = now(), decision_by = auth.uid(), decision_note = v_note,
      next_review_at = case when p_action = 'approve' then current_date + 365 else coalesce(next_review_at, current_date + 365) end,
      zone_ids = coalesce(p_zone_ids, zone_ids) where id = r.id;
    perform public._send_order_sms(r.phone, 'NYANSATEK Rider: you are approved. Open nyansatek.store/rider, sign in and go online to take jobs.');
  elsif p_action = 'more_info' then
    if r.screening_status not in ('applied','more_info') then raise exception 'This application is already %', r.screening_status; end if;
    if v_note is null then raise exception 'Say what the rider needs to fix or bring'; end if;
    update public.riders set screening_status = 'more_info', decision_at = now(), decision_by = auth.uid(), decision_note = v_note where id = r.id;
    perform public._send_order_sms(r.phone, 'NYANSATEK Rider: we need something more before we can approve you. Sign in at nyansatek.store/rider to see what.');
  elsif p_action = 'reject' then
    if r.screening_status not in ('applied','more_info') then raise exception 'This application is already %', r.screening_status; end if;
    if v_note is null then raise exception 'Give the reason'; end if;
    update public.riders set screening_status = 'rejected', decision_at = now(), decision_by = auth.uid(), decision_note = v_note where id = r.id;
    perform public._send_order_sms(r.phone, 'NYANSATEK Rider: sorry, we cannot approve your application. Sign in at nyansatek.store/rider for the reason.');
  elsif p_action = 'suspend' then
    if r.screening_status <> 'approved' then raise exception 'Only an approved rider can be suspended'; end if;
    if v_note is null then raise exception 'Give the reason'; end if;
    if exists (select 1 from public.delivery_jobs where rider_id = r.id and status = 'picked_up') then
      raise exception 'This rider is carrying an order. Wait until it is handed over, then suspend.'; end if;
    -- jobs they accepted but have not collected go back to the pool
    update public.delivery_jobs set rider_id = null, status = 'open', assigned_at = null where rider_id = r.id and status in ('assigned','at_shop');
    update public.riders set screening_status = 'suspended', decision_at = now(), decision_by = auth.uid(), decision_note = v_note where id = r.id;
    perform public._send_order_sms(r.phone, 'NYANSATEK Rider: your account is suspended. Sign in at nyansatek.store/rider for the reason, or call the team.');
  elsif p_action = 'reopen' then
    if r.screening_status <> 'rejected' then raise exception 'Only a rejected application can be reopened'; end if;
    update public.riders set screening_status = 'more_info', decision_at = now(), decision_by = auth.uid(), decision_note = coalesce(v_note, 'Reopened by the team') where id = r.id;
  else
    raise exception 'Unknown action';
  end if;
  perform public._rider_event(r.id, p_action, v_note);
end;
$$;

-- ---------- daily: expired papers and the yearly re-check ----------
create or replace function public.rider_screening_sweep()
returns int language plpgsql security definer set search_path = '' as $$
declare r public.riders%rowtype; n int := 0; v_what text;
begin
  for r in select * from public.riders where screening_status = 'approved' for update skip locked loop
    v_what := concat_ws(', ',
      case when r.licence_expiry < current_date then 'driver''s licence' end,
      case when r.roadworthy_expiry < current_date then 'roadworthy' end,
      case when r.insurance_expiry < current_date then 'insurance' end);
    if v_what <> '' or r.next_review_at <= current_date then
      -- never strand an order: wait until the rider has nothing in hand
      continue when exists (select 1 from public.delivery_jobs where rider_id = r.id and status in ('assigned','at_shop','picked_up'));
      update public.riders set screening_status = 'more_info', decision_at = now(), decision_by = null,
        decision_note = case when v_what <> '' then 'Expired: ' || v_what || '. Update the date in the app and show the new document to the team.'
                             else 'Your yearly re-check is due. Confirm your details in the app; the team will call you.' end,
        licence_checked_at = case when r.licence_expiry < current_date or v_what = '' then null else licence_checked_at end,
        vehicle_docs_checked_at = case when r.roadworthy_expiry < current_date or r.insurance_expiry < current_date or v_what = '' then null else vehicle_docs_checked_at end,
        guarantor_checked_at = case when v_what = '' then null else guarantor_checked_at end
      where id = r.id;
      insert into public.rider_screening_events (rider_id, action, note) values (r.id, 'paused_by_system', coalesce(nullif(v_what, ''), 'yearly re-check'));
      perform public._send_order_sms(r.phone, 'NYANSATEK Rider: your account is paused until your details are re-checked. Sign in at nyansatek.store/rider to see why.');
      n := n + 1;
    elsif least(r.licence_expiry, r.roadworthy_expiry, r.insurance_expiry) <= current_date + 14
          and (r.expiry_reminded_at is null or r.expiry_reminded_at < current_date - 6) then
      update public.riders set expiry_reminded_at = current_date where id = r.id;
      perform public._send_order_sms(r.phone, format('NYANSATEK Rider: one of your documents expires on %s. Renew it and update the date in the app so you can keep riding.',
        to_char(least(r.licence_expiry, r.roadworthy_expiry, r.insurance_expiry), 'DD Mon YYYY')));
    end if;
  end loop;
  return n;
end;
$$;
revoke all on function public.rider_screening_sweep() from public, anon, authenticated;
select cron.unschedule('rider-screening-sweep') where exists (select 1 from cron.job where jobname = 'rider-screening-sweep');
select cron.schedule('rider-screening-sweep', '30 4 * * *', $$select public.rider_screening_sweep()$$);

-- the rider may renew a document date while approved (the team sees it; an expired date still pauses the account)
create or replace function public.rider_update_expiry(p_licence date, p_roadworthy date, p_insurance date)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.riders set licence_expiry = coalesce(p_licence, licence_expiry), roadworthy_expiry = coalesce(p_roadworthy, roadworthy_expiry),
    insurance_expiry = coalesce(p_insurance, insurance_expiry), expiry_reminded_at = null
  where id = auth.uid() and screening_status = 'approved';
  if not found then raise exception 'Not an approved rider account'; end if;
  perform public._rider_event(auth.uid(), 'expiry_updated_by_rider',
    concat_ws(', ', 'licence ' || p_licence::text, 'roadworthy ' || p_roadworthy::text, 'insurance ' || p_insurance::text));
end;
$$;

-- ---------- selfies: a private bucket only the team (and the rider's own) can read ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rider-selfies', 'rider-selfies', false, 1048576, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg'];
drop policy if exists rider_selfies_read on storage.objects;
create policy rider_selfies_read on storage.objects for select to authenticated
  using (bucket_id = 'rider-selfies' and (public.is_market_ops() or name = auth.uid()::text || '.jpg'));

-- ---------- who may call what ----------
revoke all on function public.rider_request_phone_code(text), public.rider_update_application(jsonb), public.rider_update_expiry(date, date, date),
  public.ops_rider_review(uuid), public.ops_rider_id_check(uuid, text, text, text), public.ops_rider_set_check(uuid, text, boolean),
  public.ops_rider_decide(uuid, text, text, uuid[]), public.norm_ghana_card(text) from public, anon;
grant execute on function public.rider_request_phone_code(text) to anon, authenticated;
grant execute on function public.rider_update_application(jsonb), public.rider_update_expiry(date, date, date),
  public.ops_rider_review(uuid), public.ops_rider_id_check(uuid, text, text, text), public.ops_rider_set_check(uuid, text, boolean),
  public.ops_rider_decide(uuid, text, text, uuid[]), public.norm_ghana_card(text) to authenticated;
grant execute on function public._rider_check_phone_code(text, text), public._rider_create_application(uuid, text, jsonb, text) to service_role;

-- =====================================================================
-- Staff screening (Shop and Restaurant): a record per staff login, kept by the shop admin.
-- =====================================================================
create table if not exists public.staff_screening (
  staff_id uuid primary key references public.profiles(id) on delete cascade,
  org_id uuid not null references public.organizations(id) on delete cascade,
  legal_name text,
  phone text,
  ghana_card_number text,
  emergency_name text,
  emergency_phone text,
  id_verified_at timestamptz,
  id_verified_method text check (id_verified_method in ('nia_app','nia_platform','nia_card_reader')),
  id_verified_by uuid,
  guarantor_name text,
  guarantor_phone text,
  health_cert_number text,
  health_cert_expiry date,
  notes text,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
create index if not exists staff_screening_org on public.staff_screening (org_id);
alter table public.staff_screening enable row level security;
drop policy if exists staff_screening_admin_read on public.staff_screening;
create policy staff_screening_admin_read on public.staff_screening for select
  using ((org_id = public.current_org_id() and public.is_shop_admin()) or public.is_master());
drop policy if exists no_kitchen_access on public.staff_screening;
create policy no_kitchen_access on public.staff_screening as restrictive for all to authenticated
  using (not (select public.is_kitchen()));

-- the shop admin saves a staff member's screening record
create or replace function public.save_staff_screening(p_staff uuid, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.current_org_id(); s public.profiles%rowtype; v_card text; v_phone text; v_eph text; v_gph text;
        v_verified boolean := coalesce((p ->> 'id_verified')::boolean, false); v_method text := nullif(p ->> 'id_verified_method', '');
        v_exp date; old public.staff_screening%rowtype; v_row public.staff_screening%rowtype;
begin
  if v_org is null or not public.is_shop_admin() then raise exception 'Only the shop admin can record staff screening'; end if;
  select * into s from public.profiles where id = p_staff and org_id = v_org and role in ('cashier','kitchen');
  if not found then raise exception 'Staff login not found'; end if;
  if nullif(btrim(coalesce(p ->> 'ghana_card_number', '')), '') is not null then
    v_card := public.norm_ghana_card(p ->> 'ghana_card_number');
    if v_card is null then raise exception 'Enter the Ghana Card number like GHA-123456789-0'; end if;
  end if;
  if nullif(btrim(coalesce(p ->> 'phone', '')), '') is not null then
    v_phone := public.norm_phone(p ->> 'phone'); if v_phone is null then raise exception 'Enter a valid phone number'; end if; end if;
  if nullif(btrim(coalesce(p ->> 'emergency_phone', '')), '') is not null then
    v_eph := public.norm_phone(p ->> 'emergency_phone'); if v_eph is null then raise exception 'Enter a valid emergency phone number'; end if; end if;
  if nullif(btrim(coalesce(p ->> 'guarantor_phone', '')), '') is not null then
    v_gph := public.norm_phone(p ->> 'guarantor_phone'); if v_gph is null then raise exception 'Enter a valid guarantor phone number'; end if; end if;
  if coalesce(p ->> 'health_cert_expiry', '') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then v_exp := (p ->> 'health_cert_expiry')::date; end if;
  if v_verified then
    if v_card is null then raise exception 'Enter the Ghana Card number before marking the identity as verified'; end if;
    if coalesce(v_method, '') not in ('nia_app','nia_platform','nia_card_reader') then
      raise exception 'Choose how you verified with the NIA. Looking at the card is not a check.'; end if;
  end if;
  select * into old from public.staff_screening where staff_id = p_staff;
  insert into public.staff_screening as t (staff_id, org_id, legal_name, phone, ghana_card_number, emergency_name, emergency_phone,
    id_verified_at, id_verified_method, id_verified_by, guarantor_name, guarantor_phone, health_cert_number, health_cert_expiry, notes, updated_at, updated_by)
  values (p_staff, v_org, nullif(left(btrim(coalesce(p ->> 'legal_name', '')), 120), ''), v_phone, v_card,
    nullif(left(btrim(coalesce(p ->> 'emergency_name', '')), 120), ''), v_eph,
    case when v_verified then now() end, case when v_verified then v_method end, case when v_verified then auth.uid() end,
    nullif(left(btrim(coalesce(p ->> 'guarantor_name', '')), 120), ''), v_gph,
    nullif(left(btrim(coalesce(p ->> 'health_cert_number', '')), 60), ''), v_exp,
    nullif(left(btrim(coalesce(p ->> 'notes', '')), 500), ''), now(), auth.uid())
  on conflict (staff_id) do update set legal_name = excluded.legal_name, phone = excluded.phone, ghana_card_number = excluded.ghana_card_number,
    emergency_name = excluded.emergency_name, emergency_phone = excluded.emergency_phone,
    -- keep the original verification date unless the card number or the method changed
    id_verified_at = case when not v_verified then null
                          when t.id_verified_at is not null and t.ghana_card_number is not distinct from excluded.ghana_card_number
                               and t.id_verified_method is not distinct from excluded.id_verified_method then t.id_verified_at else now() end,
    id_verified_by = case when not v_verified then null
                          when t.id_verified_at is not null and t.ghana_card_number is not distinct from excluded.ghana_card_number
                               and t.id_verified_method is not distinct from excluded.id_verified_method then t.id_verified_by else auth.uid() end,
    id_verified_method = excluded.id_verified_method,
    guarantor_name = excluded.guarantor_name, guarantor_phone = excluded.guarantor_phone,
    health_cert_number = excluded.health_cert_number, health_cert_expiry = excluded.health_cert_expiry,
    notes = excluded.notes, updated_at = now(), updated_by = auth.uid()
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;
revoke all on function public.save_staff_screening(uuid, jsonb) from public, anon;
grant execute on function public.save_staff_screening(uuid, jsonb) to authenticated;
