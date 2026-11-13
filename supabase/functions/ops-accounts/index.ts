// ops-accounts: NYANSATEK team creates rider logins and team-member logins, and resets their passwords.
// Caller must be signed in and pass public.is_market_ops(). Verify JWT: ON.
import { createClient } from 'npm:@supabase/supabase-js@2';

const ORIGINS = ['https://nyansatek.store', 'https://www.nyansatek.store', 'https://webstar-7.github.io'];
const cors = (o: string | null) => ({
  'Access-Control-Allow-Origin': o && ORIGINS.includes(o) ? o : ORIGINS[0],
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Vary': 'Origin',
});
const VEHICLES = ['motorbike', 'car', 'van', 'truck'];
const normPhone = (p: unknown) => {
  const d = String(p || '').replace(/[^0-9]/g, '');
  if (/^233[0-9]{9}$/.test(d)) return d;
  if (/^0[0-9]{9}$/.test(d)) return '233' + d.slice(1);
  if (/^[0-9]{9}$/.test(d)) return '233' + d;
  return null;
};
const makePassword = () => {
  const A = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  for (;;) {
    const b = new Uint8Array(10); crypto.getRandomValues(b);
    const p = Array.from(b, (x) => A[x % A.length]).join('');
    if (/[a-z]/.test(p) && /[A-Z]/.test(p) && /\d/.test(p)) return p;
  }
};

Deno.serve(async (req) => {
  const h = cors(req.headers.get('origin'));
  const out = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...h, 'Content-Type': 'application/json' } });
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  if (req.method !== 'POST') return out({ error: 'Use POST' }, 405);
  const auth = req.headers.get('Authorization') || '';
  const url = Deno.env.get('SUPABASE_URL')!;
  const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: who } = await asUser.auth.getUser();
  if (!who?.user) return out({ error: 'Please sign in again.' }, 401);
  const { data: ok } = await asUser.rpc('is_market_ops');
  if (ok !== true) return out({ error: 'NYANSATEK team members only.' }, 403);
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

  let b: Record<string, unknown>;
  try { b = await req.json(); } catch { return out({ error: 'Bad request' }, 400); }
  try {
    if (b.action === 'create_rider') {
      const phone = normPhone(b.phone), name = String(b.full_name || '').trim(), vehicle = String(b.vehicle || '');
      if (!phone) throw new Error('Enter a valid phone number.');
      if (!name) throw new Error('Enter the rider\'s name.');
      if (!VEHICLES.includes(vehicle)) throw new Error('Choose the vehicle.');
      const zones = Array.isArray(b.zone_ids) ? b.zone_ids.map(String) : [];
      const password = makePassword();
      const { data: cu, error: ce } = await admin.auth.admin.createUser({
        email: `${phone}@rider.nyansatek.internal`, password, email_confirm: true,
        user_metadata: { app: 'rider', full_name: name },
      });
      if (ce || !cu?.user) throw new Error(ce?.message?.includes('already') ? 'A rider with this phone number already exists.' : (ce?.message || 'Could not create the login.'));
      const { error: re } = await admin.from('riders').insert({ id: cu.user.id, full_name: name, phone, vehicle,
        plate_number: String(b.plate_number || '').trim() || null, zone_ids: zones });
      if (re) { await admin.auth.admin.deleteUser(cu.user.id); throw new Error(re.message); }
      return out({ ok: true, login: '0' + phone.slice(3), password });
    }
    if (b.action === 'reset_rider_password') {
      const { data: r } = await admin.from('riders').select('id, phone').eq('id', String(b.rider_id || '')).maybeSingle();
      if (!r) throw new Error('Rider not found.');
      const password = makePassword();
      const { error } = await admin.auth.admin.updateUserById(r.id, { password });
      if (error) throw new Error(error.message);
      return out({ ok: true, login: '0' + String(r.phone).slice(3), password });
    }
    if (b.action === 'create_team_member') {
      const email = String(b.email || '').trim().toLowerCase(), name = String(b.full_name || '').trim();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new Error('Enter a valid email address.');
      if (!name) throw new Error('Enter the person\'s name.');
      const password = makePassword();
      const { data: cu, error: ce } = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { full_name: name } });
      if (ce || !cu?.user) throw new Error(ce?.message || 'Could not create the login.');
      // the till's sign-up trigger gives every new login a cashier profile; make it a team profile instead
      const { error: pe } = await admin.from('profiles').upsert({ id: cu.user.id, role: 'market_ops', org_id: null,
        display_name: name, full_name: name, must_change_password: false, is_active: true });
      if (pe) { await admin.auth.admin.deleteUser(cu.user.id); throw new Error(pe.message); }
      return out({ ok: true, login: email, password });
    }
    return out({ error: 'Unknown action.' }, 400);
  } catch (e) {
    return out({ error: e instanceof Error ? e.message : String(e) }, 400);
  }
});
