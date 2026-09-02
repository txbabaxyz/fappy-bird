-- Leaderboard ranks by TOTAL points across all runs of a wallet (was: best single run).
drop view if exists public.leaderboard;
create view public.leaderboard with (security_invoker = false) as
  select left(wallet, 6) || '…' || right(wallet, 4) as wallet,
         sum(score)::bigint as total,
         max(score)         as best,
         sum(ships)::int    as ships,
         max(best_streak)   as best_streak,
         count(*)::int      as runs,
         max(created_at)    as last_run
  from public.scores
  group by scores.wallet;
revoke all on public.leaderboard from anon, authenticated;
grant select on public.leaderboard to anon;

drop view if exists public.wallet_export;
create view public.wallet_export with (security_invoker = false) as
  select wallet, sum(score)::bigint as total, max(score) as best, sum(ships)::int as ships, count(*)::int as runs, max(created_at) as last_run
  from public.scores group by wallet order by total desc;
revoke all on public.wallet_export from anon, authenticated, public;

create or replace function public.player_stats(w text default null)
returns json
language plpgsql security definer set search_path = public stable as $$
declare
  lw text := lower(coalesce(w, ''));
  my_total bigint; my_best integer; my_rank integer; players integer;
begin
  select count(distinct wallet) into players from public.scores;
  if lw ~ '^0x[0-9a-f]{40}$' then
    select sum(score), max(score) into my_total, my_best from public.scores where wallet = lw;
    if my_total is not null then
      select 1 + count(*) into my_rank
      from (select wallet, sum(score) as t from public.scores group by wallet) s
      where s.t > my_total;
    end if;
  end if;
  return json_build_object('players', players, 'total', my_total, 'best', my_best, 'rank', my_rank);
end $$;
revoke all on function public.player_stats(text) from public, authenticated;
grant execute on function public.player_stats(text) to anon;

-- Quick restarts are legit: per-wallet gap 15 s -> 5 s (run tokens already enforce real play time).
create or replace function public.scores_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.scores
             where wallet = new.wallet and created_at > now() - interval '5 seconds') then
    raise exception 'too many submissions, wait a bit';
  end if;
  if new.ip_hash is not null and (select count(*) from public.scores
             where ip_hash = new.ip_hash and created_at > now() - interval '1 minute') >= 12 then
    raise exception 'too many submissions from this network';
  end if;
  if new.ships > new.duration_s * 1.5 + 3 then
    raise exception 'implausible ships for % seconds', new.duration_s;
  end if;
  if new.score > 1000 + new.ships * (600 + 200 * new.ships) then
    raise exception 'implausible score for % ships', new.ships;
  end if;
  if new.best_streak > new.ships then
    raise exception 'streak cannot exceed ships';
  end if;
  return new;
end $$;
