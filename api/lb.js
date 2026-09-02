// Vercel Edge proxy for the leaderboard: top 10 + stats for an optional wallet.
// Cached at the CDN for 15 s so read spam never reaches Supabase.
export const config = { runtime: 'edge' };

const ADDR = /^0x[0-9a-fA-F]{40}$/;

export default async function handler(req) {
  if (req.method !== 'GET') return new Response('{"error":"GET only"}', { status: 405, headers: { 'Content-Type': 'application/json' } });
  const u = new URL(req.url);
  const w = (u.searchParams.get('w') || '').trim().toLowerCase();
  const wallet = ADDR.test(w) ? w : null;
  const base = process.env.SUPABASE_URL, key = process.env.SUPABASE_PUBLISHABLE_KEY;
  const hdr = { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' };
  try {
    const [rowsR, statsR] = await Promise.all([
      fetch(base + '/rest/v1/leaderboard?select=wallet,total,best,ships&order=total.desc&limit=10', { headers: hdr }),
      fetch(base + '/rest/v1/rpc/player_stats', { method: 'POST', headers: hdr, body: JSON.stringify({ w: wallet }) }),
    ]);
    const rows = rowsR.ok ? await rowsR.json() : [];
    const stats = statsR.ok ? await statsR.json() : null;
    return new Response(JSON.stringify({ rows, stats }), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, s-maxage=15, stale-while-revalidate=60, max-age=5' },
    });
  } catch {
    return new Response('{"error":"upstream"}', { status: 502, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
  }
}
