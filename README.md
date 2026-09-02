# FAPPY BIRD 3D

A one-file Three.js arcade game with a wallet-signed `$FAPPY` leaderboard.
Play: https://fappybird.tech

- `index.html` — the whole game (Three.js r128 from cdnjs, WebAudio SFX, embedded posters)
- `supabase/migrations/` — `scores` table, guard trigger, RLS, `leaderboard` view
- `supabase/functions/submit-score/` — Edge Function that verifies the wallet signature and writes the score
- `DEPLOY.md` — setup, security model, how to export wallets

Run locally: open `index.html` in a browser (needs internet for the Three.js CDN).
