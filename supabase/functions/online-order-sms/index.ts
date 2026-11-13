// online-order-sms: sends one order SMS via Hubtel.
// Called only by the nyansatek-pos database (pg_net) with a shared secret; not callable by browsers.
// The shared secret lives in the database Vault ('order_sms_secret'); this function checks it with
// public._order_sms_secret_ok() using the service role. Hubtel keys: the same secrets as pos-send-receipt-sms.
import { createClient } from 'npm:@supabase/supabase-js@2';
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405);
  const given = req.headers.get('x-order-sms-secret') || '';
  if (given.length < 32) return json({ error: 'not found' }, 404);
  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data: ok } = await admin.rpc('_order_sms_secret_ok', { p_secret: given });
  if (ok !== true) return json({ error: 'not found' }, 404);
  let body: { to?: string; message?: string };
  try { body = await req.json(); } catch { return json({ error: 'bad request' }, 400); }
  const to = String(body.to || '').replace(/[^0-9]/g, '');
  const message = String(body.message || '').slice(0, 459);
  if (!/^233[0-9]{9}$/.test(to) || !message) return json({ error: 'bad recipient or message' }, 400);
  const id = Deno.env.get('HUBTEL_CLIENT_ID'), key = Deno.env.get('HUBTEL_CLIENT_SECRET');
  const from = Deno.env.get('HUBTEL_SENDER_ID') || 'NYANSATEK';
  if (!id || !key) return json({ error: 'SMS not configured' }, 500);
  const url = `https://smsc.hubtel.com/v1/messages/send?clientsecret=${encodeURIComponent(key)}&clientid=${encodeURIComponent(id)}&from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}&content=${encodeURIComponent(message)}`;
  const res = await fetch(url);
  const data = await res.json().catch(() => ({}));
  // Hubtel can send the text while returning a non-2xx status: also trust a real messageId with status 0/100
  const sent = res.ok || (typeof data?.messageId === 'string' && data.messageId.length > 0 && [0, 100, '0', '100'].includes(data.status));
  if (!sent) return json({ error: 'Hubtel failed', status: res.status }, 502);
  return json({ ok: true });
});
