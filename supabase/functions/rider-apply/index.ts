// rider-apply: a new rider applies (anyone with a confirmed phone number), or retakes the selfie.
// Verify JWT: OFF (applicants have no login yet). The function does its own checks:
//   apply  -> the phone code must be right (sent by rpc rider_request_phone_code), then the login,
//             the selfie and the application are created together, or not at all.
//   selfie -> the caller must be a signed-in rider whose application is still open.
// Never accepts or stores a picture of the Ghana Card: only the number is kept (L.I. 2523).
import { createClient } from 'npm:@supabase/supabase-js@2';

const ORIGINS = ['https://nyansatek.store', 'https://www.nyansatek.store', 'https://nyansatek.food', 'https://www.nyansatek.food', 'https://webstar-7.github.io'];
const cors = (o: string | null) => ({
  'Access-Control-Allow-Origin': o && ORIGINS.includes(o) ? o : ORIGINS[0],
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Vary': 'Origin',
});
const normPhone = (p: unknown) => {
  const d = String(p || '').replace(/[^0-9]/g, '');
  if (/^233[0-9]{9}$/.test(d)) return d;
  if (/^0[0-9]{9}$/.test(d)) return '233' + d.slice(1);
  if (/^[0-9]{9}$/.test(d)) return '233' + d;
  return null;
};
// "data:image/jpeg;base64,...." -> bytes, only if it really is a JPEG under 1 MB
const jpeg = (s: unknown): Uint8Array | null => {
  const m = /^data:image\/jpeg;base64,([A-Za-z0-9+/=]+)$/.exec(String(s || ''));
  if (!m || m[1].length > 1_400_000) return null;
  let bin: string;
  try { bin = atob(m[1]); } catch { return null; }
  const b = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) b[i] = bin.charCodeAt(i);
  if (b.length < 2000 || b.length > 1_048_576 || b[0] !== 0xff || b[1] !== 0xd8 || b[2] !== 0xff) return null;
  return b;
};

Deno.serve(async (req) => {
  const h = cors(req.headers.get('origin'));
  const out = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...h, 'Content-Type': 'application/json' } });
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  if (req.method !== 'POST') return out({ error: 'Use POST' }, 405);
  const url = Deno.env.get('SUPABASE_URL')!;
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

  let b: Record<string, unknown>;
  try { b = await req.json(); } catch { return out({ error: 'Bad request' }, 400); }

  try {
    if (b.action === 'apply') {
      const phone = normPhone(b.phone), password = String(b.password || '');
      const appl = (b.application && typeof b.application === 'object' ? b.application : {}) as Record<string, unknown>;
      if (!phone) throw new Error('Enter a valid phone number.');
      if (password.length < 8) throw new Error('Choose a password of at least 8 characters.');
      if (appl.consent !== true) throw new Error('You need to agree to the checks to apply.');
      const photo = jpeg(b.selfie);
      if (!photo) throw new Error('Take a selfie to apply.');

      const { data: codeOk, error: ke } = await admin.rpc('_rider_check_phone_code', { p_phone: phone, p_code: String(b.code || '') });
      if (ke) throw new Error('Could not check the code. Try again.');
      if (codeOk !== true) throw new Error('That code is wrong or has expired. Ask for a new one.');

      const { data: cu, error: ce } = await admin.auth.admin.createUser({
        email: `${phone}@rider.nyansatek.internal`, password, email_confirm: true,
        user_metadata: { app: 'rider', full_name: String(appl.full_name || '').slice(0, 120) },
      });
      if (ce || !cu?.user) throw new Error(ce?.message?.includes('already') ? 'This phone number already has a rider account. Sign in instead.' : (ce?.message || 'Could not create your login.'));
      const id = cu.user.id, path = `${id}.jpg`;
      const undo = async () => { await admin.storage.from('rider-selfies').remove([path]); await admin.auth.admin.deleteUser(id); };

      const { error: ue } = await admin.storage.from('rider-selfies').upload(path, photo, { contentType: 'image/jpeg', upsert: true });
      if (ue) { await undo(); throw new Error('Could not save your selfie. Try again.'); }
      const { error: ae } = await admin.rpc('_rider_create_application', { p_id: id, p_phone: phone, p: appl, p_selfie_path: path });
      if (ae) { await undo(); throw new Error(ae.message); }
      return out({ ok: true });
    }

    if (b.action === 'selfie') {
      const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') || '' } }, auth: { persistSession: false } });
      const { data: who } = await asUser.auth.getUser();
      if (!who?.user) return out({ error: 'Please sign in again.' }, 401);
      const { data: r } = await admin.from('riders').select('id, screening_status').eq('id', who.user.id).maybeSingle();
      if (!r) throw new Error('Not a rider account.');
      if (!['applied', 'more_info'].includes(r.screening_status)) throw new Error('Your selfie can no longer be changed here. Contact NYANSATEK.');
      const photo = jpeg(b.selfie);
      if (!photo) throw new Error('Take a selfie first.');
      const path = `${r.id}.jpg`;
      const { error: ue } = await admin.storage.from('rider-selfies').upload(path, photo, { contentType: 'image/jpeg', upsert: true });
      if (ue) throw new Error('Could not save your selfie. Try again.');
      await admin.from('riders').update({ selfie_path: path }).eq('id', r.id);
      await admin.from('rider_screening_events').insert({ rider_id: r.id, actor: r.id, action: 'selfie_retaken' });
      return out({ ok: true });
    }
    return out({ error: 'Unknown action.' }, 400);
  } catch (e) {
    return out({ error: e instanceof Error ? e.message : String(e) }, 400);
  }
});
