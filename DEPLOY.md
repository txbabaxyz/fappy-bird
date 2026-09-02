# FAPPY BIRD — deploy notes

Stack: one static `index.html` on Vercel (`fappybird.tech`) + Supabase (Postgres + Edge Function).
Wallets are EVM `0x…` addresses (Robinhood Chain, chain id 4663, MetaMask-compatible).

## Architecture (hardened by default)

```
browser ──personal_sign──► MetaMask/Rabby/Coinbase Wallet
   │ POST {wallet, score, ships, best_streak, duration_s, nonce, msg, sig}
   ▼
Edge Function submit-score  (verifies EIP-191 signature with viem, service role)
   │ INSERT
   ▼
Postgres scores  (RLS on, NO anon policies, guard trigger: rate limit + plausibility + replay)
   │
   ▼
view leaderboard  (the only thing the publishable key can read)
```

- The publishable key shipped in `index.html` can only `SELECT` the `leaderboard` view.
- Nothing can write to `scores` except the Edge Function, which requires a valid signature
  from the wallet itself over a canonical message that contains the score.
- Replay: `sig` and `(wallet, nonce)` are unique; nonce must be within 10 minutes.
- Abuse: 1 submission / wallet / 20 s, 6 submissions / IP hash / minute, plausibility bounds
  on score vs ships and ships vs duration (DB trigger, applies to every write path).

## Supabase

Project ref: `jxzjmiagaghjvdqhvwig` (eu-central-1).

```sh
supabase login --token sbp_…
supabase link --project-ref jxzjmiagaghjvdqhvwig
supabase db push                                   # applies supabase/migrations/*
supabase secrets set IP_SALT=$(openssl rand -hex 16)
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
select wallet, best, ships, best_streak, runs, last_run
from public.leaderboard
order by best desc;
```
