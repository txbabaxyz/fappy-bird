// Vercel Edge proxy for the Supabase submit-score function.
// The browser only ever talks to this origin; Supabase accepts requests carrying our secret
// proxy key, so all traffic passes Vercel's WAF / rate limits first.
export const config = { runtime: 'edge' };

const H = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
const json = (b, s = 200) => new Response(JSON.stringify(b), { status: s, headers: H });

export default async function handler(req) {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const len = Number(req.headers.get('content-length') || 0);
  if (len > 2048) return json({ error: 'too large' }, 413);
  let body;
  try { body = await req.text(); if (body.length > 2048) throw 0; JSON.parse(body); } catch { return json({ error: 'bad json' }, 400); }
  const ip = req.headers.get('x-real-ip') || (req.headers.get('x-forwarded-for') || '').split(',')[0].trim() || '';
  const r = await fetch(process.env.SUPABASE_URL + '/functions/v1/submit-score', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-proxy-key': process.env.PROXY_KEY, 'x-fappy-ip': ip },
    body,
  });
  const text = await r.text();
  return new Response(text, { status: r.status, headers: H });
}
