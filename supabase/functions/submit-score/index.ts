// Supabase Edge Function — the ONLY write path to public.scores.
//
//   POST {op:"start"}                                   -> {run:"<token>"}   issued when a game starts
//   POST {op:"submit", wallet, score, ships, best_streak, duration_s, run}
//
// The run token is an HMAC-signed (id, startedAt). On submit we require that the wall-clock
// time since the token was issued is at least the claimed duration, that the token is fresh,
// and that it has not been used before (unique index on scores.run_id). The DB trigger adds
// per-wallet / per-IP rate limits and plausibility bounds.
//
// Deploy:  supabase functions deploy submit-score --no-verify-jwt
// Secrets: RUN_SECRET, PROXY_KEY (required), IP_SALT (optional). SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected.
import { createClient } from "npm:@supabase/supabase-js@2";
import { isAddress } from "npm:viem@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const MAX_RUN_AGE_MS = 6 * 60 * 60 * 1000;  // a run token dies after 6 h
const SUBMIT_GRACE_S = 900;                 // must submit within 15 min after the run ended
const isInt = (n: unknown, lo: number, hi: number) => typeof n === "number" && Number.isInteger(n) && n >= lo && n <= hi;

const enc = new TextEncoder();
const hex = (buf: ArrayBuffer) => Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
async function hmac(data: string) {
  const key = await crypto.subtle.importKey("raw", enc.encode(Deno.env.get("RUN_SECRET")!), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, enc.encode(data)));
}
async function sha256(s: string) { return hex(await crypto.subtle.digest("SHA-256", enc.encode(s))); }
function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (!Deno.env.get("RUN_SECRET") || !Deno.env.get("PROXY_KEY")) return json({ error: "server not configured" }, 500);
  // Only our Vercel proxy may call this function (the browser never talks to Supabase directly).
  if (!timingSafeEqual(req.headers.get("x-proxy-key") || "", Deno.env.get("PROXY_KEY")!)) return json({ error: "forbidden" }, 403);
  if (Number(req.headers.get("content-length") || 0) > 2048) return json({ error: "too large" }, 413);

  let b: any;
  try { b = await req.json(); } catch { return json({ error: "bad json" }, 400); }

  // ---- issue a run token
  if (b.op === "start") {
    const id = crypto.randomUUID().replace(/-/g, "");
    const ts = Date.now();
    const body = `${id}.${ts}`;
    return json({ run: `${body}.${await hmac(body)}` });
  }
  if (b.op !== "submit") return json({ error: "bad op" }, 400);

  // ---- validate submission
  const walletRaw = String(b.wallet || "").trim();
  if (!/^0x[0-9a-fA-F]{40}$/.test(walletRaw)) return json({ error: "bad wallet" }, 400);
  // mixed-case input must carry a valid EIP-55 checksum (catches typos); all-lowercase is accepted as-is
  const mixed = walletRaw !== walletRaw.toLowerCase() && walletRaw !== walletRaw.toUpperCase();
  if (mixed && !isAddress(walletRaw, { strict: true })) return json({ error: "wallet checksum mismatch — double-check the address" }, 400);
  const wallet = walletRaw.toLowerCase();

  const { score, ships, best_streak, duration_s } = b;
  if (!isInt(score, 0, 50_000_000) || !isInt(ships, 0, 5000) || !isInt(best_streak, 0, 5000) || !isInt(duration_s, 0, 86400))
    return json({ error: "bad numbers" }, 400);

  const run = String(b.run || "");
  const m = run.match(/^([0-9a-f]{32})\.(\d{13})\.([0-9a-f]{64})$/);
  if (!m) return json({ error: "bad run token" }, 400);
  const [, run_id, tsStr, mac] = m;
  if (!timingSafeEqual(mac, await hmac(`${run_id}.${tsStr}`))) return json({ error: "bad run token" }, 401);
  const elapsed = (Date.now() - Number(tsStr)) / 1000;
  if (elapsed < -5 || elapsed > MAX_RUN_AGE_MS / 1000) return json({ error: "run token expired" }, 400);
  if (duration_s > elapsed + 3) return json({ error: "duration longer than the run itself" }, 400);
  if (elapsed > duration_s + SUBMIT_GRACE_S) return json({ error: "run submitted too late" }, 400);

  const ip = (req.headers.get("x-fappy-ip") || "").trim();
  const ip_hash = ip ? await sha256(ip + (Deno.env.get("IP_SALT") || "fappy")) : null;

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { error } = await sb.from("scores").insert({ wallet, score, ships, best_streak, duration_s, run_id, ip_hash });
  if (error) {
    if (error.code === "23505") return json({ error: "this run was already saved" }, 409);
    return json({ error: error.message.replace(/^.*?: /, "") }, 400);
  }
  return json({ ok: true });
});
