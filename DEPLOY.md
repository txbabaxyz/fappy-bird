# FAPPY BIRD — deploy notes

Stack: one static `index.html` on Vercel (`fappybird.tech`) + Supabase (Postgres + Edge Function).
Wallets are EVM `0x…` addresses (Robinhood Chain, chain id 4663, MetaMask-compatible).

## Architecture (hardened)

```
browser  POST {op:"start"}  ──►  Edge Function submit-score  ──►  {run: HMAC token with start time}
   … player plays …
browser  POST {op:"submit", wallet, score, ships, best_streak, duration_s, run}
   ▼
Edge Function: token HMAC valid · elapsed time ≥ claimed duration · not expired · EIP-55 checksum
   │ INSERT (service role)
   ▼
Postgres scores  (RLS on, NO anon policies; trigger: rate limits + plausibility; run_id unique)
   │
   ▼
view leaderboard  (shortened wallets only — the only thing the publishable key can read)
```

- The publishable key shipped in `index.html` can only `SELECT` the `leaderboard` view, which exposes
  `0x1234…abcd`-style wallets, never full addresses.
- Nothing writes to `scores` except the Edge Function. Every score needs a run token issued when the
  game started; the claimed duration cannot exceed the real elapsed time; a token is single-use.
- Abuse: 1 submission / wallet / 15 s, 6 submissions / IP hash / minute, plausibility bounds on
  score vs ships and ships vs duration (DB trigger, applies to every write path).
- Wallet ownership is NOT proven (by product decision): anyone can submit for any address, but only
  within the rules above and only at real-time speed.
- Supabase Auth signups are disabled; GraphQL is off; no storage buckets.
- Site headers: CSP (scripts only self + cdnjs, connections only to our Supabase), HSTS, no framing.

## Supabase

Project ref: `jxzjmiagaghjvdqhvwig` (eu-central-1).

```sh
supabase login --token sbp_…
supabase link --project-ref jxzjmiagaghjvdqhvwig
supabase db push                                   # applies supabase/migrations/*
supabase secrets set IP_SALT=$(openssl rand -hex 16) RUN_SECRET=$(openssl rand -hex 32)
supabase functions deploy submit-score --no-verify-jwt
```

`index.html` → `CFG` holds `SUPABASE_URL`, the **publishable** key and `EDGE_URL`.
Never put the `service_role` / `sb_secret_*` key in the frontend.

## Vercel

```sh
vercel --prod
```
Domain `fappybird.tech` is attached in the Vercel project settings.

## Export wallets for the airdrop

In Supabase SQL Editor (runs as owner, sees raw rows):

```sql
select * from public.wallet_export;   -- full addresses, best score, runs
```
`wallet_export` is owner-only; the public `leaderboard` view never returns full addresses.
