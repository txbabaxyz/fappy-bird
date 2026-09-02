-- Referral program: one level only. A referrer earns 20% of the GAME points their referees score.
-- Bonuses are materialised by refresh_referrals() (pg_cron every 3 h + lazy fallback), so the
-- leaderboard "total" = own game points + referral bonus, cumulative and idempotent (recomputed
-- from scratch, never incremented — no double counting, no chains: a referee's own referral
-- bonus never flows upward).

create table if not exists public.players (
  wallet       text primary key check (wallet ~ '^0x[0-9a-f]{40}$'),
  ref_code     text not null unique check (ref_code ~ '^[a-z0-9]{8}$'),
  referred_by  text references public.players(wallet),
  ref_count    integer not null default 0,
  ref_points   bigint  not null default 0,
  ref_bonus    bigint  not null default 0,
  created_at   timestamptz not null default now(),
  constraint players_no_self_ref check (referred_by is null or referred_by <> wallet)
);
create index if not exists players_referred_by_idx on public.players (referred_by);
alter table public.players enable row level security;
revoke all on table public.players from anon, authenticated;

create table if not exists public.settings (
  key text primary key, value text, updated_at timestamptz not null default now()
);
alter table public.settings enable row level security;
revoke all on table public.settings from anon, authenticated;
insert into public.settings (key, value) values ('ref_refreshed_at', now()::text) on conflict (key) do nothing;

-- Recompute every referrer's numbers from scratch.
create or replace function public.refresh_referrals() returns void
language sql security definer set search_path = public as $$
  with pts as (select wallet, sum(score)::bigint as t from public.scores group by wallet),
  agg as (select p.referred_by as w, count(*)::int as c, coalesce(sum(pts.t), 0)::bigint as tp
          from public.players p left join pts on pts.wallet = p.wallet
          where p.referred_by is not null group by p.referred_by)
  update public.players p
     set ref_count  = coalesce(a.c, 0),
         ref_points = coalesce(a.tp, 0),
         ref_bonus  = floor(coalesce(a.tp, 0) * 0.20)::bigint
    from public.players x left join agg a on a.w = x.wallet
   where p.wallet = x.wallet;
  insert into public.settings (key, value, updated_at) values ('ref_refreshed_at', now()::text, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
$$;
revoke all on function public.refresh_referrals() from public, anon, authenticated;

-- Lazy fallback: refresh if the last refresh is older than 3 hours. Called by the Edge Function.
create or replace function public.maybe_refresh_referrals() returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if (select updated_at from public.settings where key = 'ref_refreshed_at') < now() - interval '3 hours' then
    perform public.refresh_referrals(); return true;
  end if;
  return false;
end $$;
revoke all on function public.maybe_refresh_referrals() from public, anon, authenticated;

-- Get-or-create a player row. The referral is bound ONLY when the wallet is brand new
-- (no players row, no scores) and the code belongs to another existing player who was not
-- themselves referred by this wallet. Never changes afterwards.
create or replace function public.ensure_player(w text, r text default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  lw text := lower(coalesce(w, ''));
  code text; referrer text; existing public.players%rowtype; tries int := 0;
begin
  if lw !~ '^0x[0-9a-f]{40}$' then raise exception 'bad wallet'; end if;
  select * into existing from public.players where wallet = lw;
  if found then
    return json_build_object('ref_code', existing.ref_code, 'referred', existing.referred_by is not null, 'created', false);
  end if;
  if r is not null and r ~ '^[a-z0-9]{8}$' then
    select wallet into referrer from public.players where ref_code = r;
    if referrer = lw then referrer := null; end if;
    if referrer is not null and exists (select 1 from public.scores where wallet = lw) then referrer := null; end if;
    if referrer is not null and exists (select 1 from public.players where wallet = referrer and referred_by = lw) then referrer := null; end if;
  end if;
  loop
    code := lower(substr(encode(gen_random_bytes(8), 'hex'), 1, 8));
    code := translate(code, '', '');
    begin
      insert into public.players (wallet, ref_code, referred_by) values (lw, code, referrer);
      exit;
    exception when unique_violation then
      tries := tries + 1; if tries > 5 then raise; end if;
      -- someone created the row concurrently?
      select * into existing from public.players where wallet = lw;
      if found then return json_build_object('ref_code', existing.ref_code, 'referred', existing.referred_by is not null, 'created', false); end if;
    end;
  end loop;
  return json_build_object('ref_code', code, 'referred', referrer is not null, 'created', true);
end $$;
revoke all on function public.ensure_player(text, text) from public, anon, authenticated;

-- Leaderboard: total = game points + referral bonus. Shortened wallets only.
drop view if exists public.leaderboard;
create view public.leaderboard with (security_invoker = false) as
  with pts as (select wallet, sum(score)::bigint as g, max(score) as best, sum(ships)::int as ships,
                      max(best_streak) as best_streak, count(*)::int as runs, max(created_at) as last_run
               from public.scores group by wallet),
  u as (select coalesce(pts.wallet, p.wallet) as w, coalesce(pts.g, 0)::bigint as g, coalesce(p.ref_bonus, 0)::bigint as rb,
               pts.best, pts.ships, pts.best_streak, pts.runs, pts.last_run
        from pts full join public.players p on p.wallet = pts.wallet)
  select left(w, 6) || '…' || right(w, 4) as wallet, (g + rb)::bigint as total, g as game_points, rb as ref_bonus,
         best, ships, best_streak, runs, last_run
  from u where g + rb > 0;
revoke all on public.leaderboard from anon, authenticated;
grant select on public.leaderboard to anon;

drop view if exists public.wallet_export;
create view public.wallet_export with (security_invoker = false) as
  with pts as (select wallet, sum(score)::bigint as g, max(score) as best, count(*)::int as runs, max(created_at) as last_run
               from public.scores group by wallet)
  select coalesce(pts.wallet, p.wallet) as wallet, (coalesce(pts.g,0) + coalesce(p.ref_bonus,0))::bigint as total,
         coalesce(pts.g,0)::bigint as game_points, coalesce(p.ref_bonus,0)::bigint as ref_bonus, p.ref_count, p.referred_by,
         pts.best, pts.runs, pts.last_run, p.ref_code
  from pts full join public.players p on p.wallet = pts.wallet
  order by total desc;
revoke all on public.wallet_export from anon, authenticated, public;

create or replace function public.player_stats(w text default null)
returns json
language plpgsql security definer set search_path = public stable as $$
declare
  lw text := lower(coalesce(w, ''));
  g bigint; my_best integer; my_rank integer; players integer; p public.players%rowtype; total bigint; upd timestamptz;
begin
  select count(distinct wallet) into players from public.scores;
  select updated_at into upd from public.settings where key = 'ref_refreshed_at';
  if lw !~ '^0x[0-9a-f]{40}$' then
    return json_build_object('players', players, 'ref_refreshed_at', upd);
  end if;
  select sum(score), max(score) into g, my_best from public.scores where wallet = lw;
  select * into p from public.players where wallet = lw;
  total := coalesce(g, 0) + coalesce(p.ref_bonus, 0);
  if total > 0 then
    select 1 + count(*) into my_rank from public.leaderboard l where l.total > total;
  end if;
  return json_build_object('players', players, 'total', case when total > 0 then total end, 'game_points', coalesce(g, 0),
    'best', my_best, 'rank', my_rank,
    'ref_code', p.ref_code, 'ref_count', coalesce(p.ref_count, 0), 'ref_points', coalesce(p.ref_points, 0),
    'ref_bonus', coalesce(p.ref_bonus, 0), 'referred', p.referred_by is not null, 'ref_refreshed_at', upd);
end $$;
revoke all on function public.player_stats(text) from public, authenticated;
grant execute on function public.player_stats(text) to anon;

-- Scheduled refresh every 3 hours (best effort; the lazy fallback covers environments without pg_cron).
do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule(jobid) from cron.job where jobname = 'refresh-referrals';
  perform cron.schedule('refresh-referrals', '0 */3 * * *', 'select public.refresh_referrals()');
exception when others then
  raise notice 'pg_cron not available: %', sqlerrm;
end $$;
