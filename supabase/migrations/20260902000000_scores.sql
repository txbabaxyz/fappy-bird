-- FAPPY BIRD leaderboard — hardened schema.
-- Writes happen ONLY through the submit-score Edge Function (service role) after
-- an EIP-191 wallet signature is verified. The anon/publishable key can read the
-- aggregated leaderboard view and nothing else.

create table if not exists public.scores (
  id           bigserial primary key,
  wallet       text        not null check (wallet ~ '^0x[0-9a-f]{40}$'),  -- lowercase EVM address
  score        integer     not null check (score >= 0 and score <= 50000000),
  ships        integer     not null default 0 check (ships between 0 and 5000),
  best_streak  integer     not null default 0 check (best_streak between 0 and 5000),
  duration_s   integer     not null check (duration_s between 0 and 86400),
  nonce        bigint      not null,          -- client timestamp (ms) embedded in the signed message
  msg          text        not null,          -- exact signed message
  sig          text        not null check (sig ~ '^0x[0-9a-f]{130}$'),  -- EIP-191 signature
  ip_hash      text,                          -- sha256(ip + salt), for abuse limiting only
  created_at   timestamptz not null default now()
);
create index        if not exists scores_wallet_idx       on public.scores (wallet);
create index        if not exists scores_score_idx        on public.scores (score desc);
create index        if not exists scores_ip_idx           on public.scores (ip_hash, created_at desc);
create unique index if not exists scores_sig_uidx         on public.scores (sig);            -- replay protection
create unique index if not exists scores_wallet_nonce_uidx on public.scores (wallet, nonce);

-- Plausibility + rate limits, enforced in the DB so they hold even if the function is bypassed.
create or replace function public.scores_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.scores
             where wallet = new.wallet and created_at > now() - interval '20 seconds') then
    raise exception 'too many submissions, wait a bit';
  end if;
  if new.ip_hash is not null and (select count(*) from public.scores
             where ip_hash = new.ip_hash and created_at > now() - interval '1 minute') >= 6 then
    raise exception 'too many submissions from this network';
  end if;
  -- generous upper bound: max ship bonus = 100 * (1 + 0.5*streak) * 3, streak <= ships, plus taps/close-calls
  if new.score > 1000 + new.ships * (800 + 500 * new.ships) then
    raise exception 'implausible score for % ships', new.ships;
  end if;
  if new.best_streak > new.ships then
    raise exception 'streak cannot exceed ships';
  end if;
  -- a ship needs ~12 taps; nobody ships more than ~2 per second
  if new.ships > new.duration_s * 2 + 3 then
    raise exception 'implausible ships for % seconds', new.duration_s;
  end if;
  return new;
end $$;
drop trigger if exists scores_guard_trg on public.scores;
create trigger scores_guard_trg before insert on public.scores
  for each row execute function public.scores_guard();

-- Lock the table down: RLS on, no policies => anon/authenticated cannot read or write rows.
alter table public.scores enable row level security;
revoke all on table public.scores from anon, authenticated;
revoke all on sequence public.scores_id_seq from anon, authenticated;

-- Public leaderboard: best score per wallet. The view runs with owner rights on purpose
-- (security definer semantics) so anon can read the aggregate without touching raw rows.
create or replace view public.leaderboard with (security_invoker = false) as
  select wallet,
         max(score)        as best,
         sum(ships)::int   as ships,
         max(best_streak)  as best_streak,
         count(*)::int     as runs,
         max(created_at)   as last_run
  from public.scores
  group by wallet;
revoke all on public.leaderboard from anon, authenticated;
grant select on public.leaderboard to anon;
