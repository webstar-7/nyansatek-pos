// online-order-sms: sends one order SMS via Hubtel.
// Called only by the nyansatek-pos database (pg_net) with a shared secret; not callable by browsers.
// Secrets (Supabase > Edge Functions > Secrets): ORDER_SMS_SECRET, plus the Hubtel keys already used by pos-send-receipt-sms.
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405);
  const secret = Deno.env.get('ORDER_SMS_SECRET');
  if (!secret || req.headers.get('x-order-sms-secret') !== secret) return json({ error: 'not found' }, 404);
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
  if (!res.ok) return json({ error: 'Hubtel failed', status: res.status }, 502);
  return json({ ok: true });
});
