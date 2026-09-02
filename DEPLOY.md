# FAPPY BIRD — deploy notes

Stack: one static `index.html` on Vercel (`fappybird.tech`) + Supabase (Postgres + Edge Function).
Wallets are EVM `0x…` addresses (Robinhood Chain, chain id 4663, MetaMask-compatible).

## Architecture (hardened)

```
browser ──► fappybird.tech (Vercel: static index.html + edge proxies /api/run, /api/lb)
               │  WAF: per-IP rate limits, bot protection, odd methods denied, CSP connect-src 'self'
               ▼
        Supabase Edge Function submit-score   (accepts ONLY requests carrying the Vercel PROXY_KEY)
          ops: start (HMAC run token) · submit (score) · player (get-or-create, referral binding)
               │ service role
               ▼
        Postgres: scores (RLS, no anon access, guard trigger) · players (ref codes, bonuses) · settings
               ▼
        view leaderboard (shortened wallets, total = game points + referral bonus) ← read via /api/lb, cached 15 s
```

- The browser never talks to Supabase. `index.html` contains no keys or Supabase URL.
- Scores need a run token issued at game start; claimed duration ≤ real elapsed time; single-use.
- DB trigger: 1 submission / wallet / 5 s, 12 / IP-hash / min, plausibility bounds.
- Wallet ownership is NOT proven (product decision). Players paste an address; every run auto-credits it.
- Referrals: one level. A referrer gets 20% of referees' GAME points. Bound only for brand-new wallets
  (no players row, no scores), never self, never mutual. `refresh_referrals()` recomputes from scratch
  (pg_cron `0 */3 * * *` + lazy fallback when >3 h stale) — cumulative and idempotent.
- Public leaderboard exposes `0x1234…abcd` only; `wallet_export` (full addresses, totals, referrer) is owner-only.
- Supabase Auth signups disabled; GraphQL off; no storage buckets.
- Vercel Firewall: `/api/run` 40 req/min/IP (deny 10 m), `/api/lb` 120/min (deny 5 m), page 200/min (challenge),
  non GET/POST/HEAD/OPTIONS denied, managed bot protection (challenge). Under a real attack switch on
  **Attack Challenge Mode** in Vercel → Project → Firewall.

## Environment

Vercel (production, sensitive): `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `PROXY_KEY`.
Supabase secrets: `RUN_SECRET`, `PROXY_KEY`, `IP_SALT`.

## Supabase

Project ref: `jxzjmiagaghjvdqhvwig` (eu-central-1).

```sh
supabase login --token sbp_…
supabase link --project-ref jxzjmiagaghjvdqhvwig
supabase db push                                   # applies supabase/migrations/*
supabase secrets set IP_SALT=$(openssl rand -hex 16) RUN_SECRET=$(openssl rand -hex 32) PROXY_KEY=<same value as Vercel PROXY_KEY>
supabase functions deploy submit-score --no-verify-jwt
```

`index.html` only knows `CFG.API='/api'`. Never put any key in the frontend.

## Vercel

```sh
vercel --prod
```
Domain `fappybird.tech` is attached in the Vercel project settings.

## Export wallets for the airdrop

In Supabase SQL Editor (runs as owner, sees raw rows):

```sql
select * from public.wallet_export;   -- full address, total (game + referral bonus), game_points, ref_bonus, referrer
```
`wallet_export` is owner-only; the public `leaderboard` view never returns full addresses.
