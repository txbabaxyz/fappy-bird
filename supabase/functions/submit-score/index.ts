// Supabase Edge Function: verifies an EIP-191 (personal_sign) signature over a canonical
// message and inserts the score with the service role. This is the ONLY write path.
// Deploy:  supabase functions deploy submit-score --no-verify-jwt
// Env:     SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.
//          IP_SALT (optional): salt for hashing client IPs used in abuse limiting.
import { createClient } from "npm:@supabase/supabase-js@2";
import { verifyMessage } from "npm:viem@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const MAX_AGE_MS = 10 * 60 * 1000;   // signature must be fresh
const MAX_SKEW_MS = 60 * 1000;       // tolerate slightly-ahead client clocks
const ADDR = /^0x[0-9a-f]{40}$/;
const SIG = /^0x[0-9a-fA-F]{130}$/;

// Must match the client exactly (index.html → buildMsg).
function canonical(w: string, score: number, ships: number, streak: number, dur: number, nonce: number) {
  return `FAPPY BIRD score\nwallet:${w}\nscore:${score}\nships:${ships}\nstreak:${streak}\nduration:${dur}\nnonce:${nonce}`;
}
const isInt = (n: unknown, lo: number, hi: number) => typeof n === "number" && Number.isInteger(n) && n >= lo && n <= hi;

async function sha256(s: string) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (Number(req.headers.get("content-length") || 0) > 4096) return json({ error: "too large" }, 413);

  let b: any;
  try { b = await req.json(); } catch { return json({ error: "bad json" }, 400); }

  const wallet = String(b.wallet || "").toLowerCase();
  const { score, ships, best_streak, duration_s, nonce } = b;
  const msg = String(b.msg || ""), sig = String(b.sig || "");

  if (!ADDR.test(wallet)) return json({ error: "bad wallet" }, 400);
  if (!isInt(score, 0, 50_000_000) || !isInt(ships, 0, 5000) || !isInt(best_streak, 0, 5000) ||
      !isInt(duration_s, 0, 86400) || !isInt(nonce, 0, Number.MAX_SAFE_INTEGER)) return json({ error: "bad numbers" }, 400);
  if (!SIG.test(sig)) return json({ error: "bad signature format" }, 400);
  if (msg !== canonical(wallet, score, ships, best_streak, duration_s, nonce)) return json({ error: "message mismatch" }, 400);

  const age = Date.now() - nonce;
  if (age > MAX_AGE_MS || age < -MAX_SKEW_MS) return json({ error: "stale signature" }, 400);

  let ok = false;
  try {
    ok = await verifyMessage({ address: wallet as `0x${string}`, message: msg, signature: sig as `0x${string}` });
  } catch { ok = false; }
  if (!ok) return json({ error: "invalid signature" }, 401);

  const ip = (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || req.headers.get("cf-connecting-ip") || "";
  const ip_hash = ip ? await sha256(ip + (Deno.env.get("IP_SALT") || "fappy")) : null;

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { error } = await sb.from("scores").insert({
    wallet, score, ships, best_streak, duration_s, nonce, msg, sig: sig.toLowerCase(), ip_hash,
  });
  if (error) {
    if (error.code === "23505") return json({ error: "already submitted" }, 409);
    return json({ error: error.message.replace(/^.*?: /, "") }, 400);
  }
  return json({ ok: true });
});
