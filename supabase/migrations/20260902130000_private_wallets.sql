-- Harden what the public can see: the leaderboard exposes only a shortened wallet
-- (0x1234…abcd) so the full address list cannot be scraped for airdrop phishing.
-- Full addresses stay in public.scores, readable only by the project owner / service role.

drop view if exists public.leaderboard;
create view public.leaderboard with (security_invoker = false) as
  select left(wallet, 6) || '…' || right(wallet, 4) as wallet,
         max(score)        as best,
         sum(ships)::int   as ships,
         max(best_streak)  as best_streak,
         count(*)::int     as runs,
         max(created_at)   as last_run
  from public.scores
  group by scores.wallet;
revoke all on public.leaderboard from anon, authenticated;
grant select on public.leaderboard to anon;

-- Owner-only helper for the airdrop export (not callable via the API by anon/authenticated).
create or replace view public.wallet_export with (security_invoker = false) as
  select wallet, max(score) as best, sum(ships)::int as ships, count(*)::int as runs, max(created_at) as last_run
  from public.scores group by wallet order by best desc;
revoke all on public.wallet_export from anon, authenticated, public;

-- Hygiene: trigger function must not be executable through the API.
revoke execute on function public.scores_guard() from anon, authenticated, public;
