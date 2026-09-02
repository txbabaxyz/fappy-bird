-- Switch from wallet signatures to server-issued run tokens.
-- Wallet ownership is no longer proven; a run token (HMAC, issued at game start by the
-- Edge Function) ties every score to a real elapsed play time and can be used once.

drop index if exists public.scores_sig_uidx;
drop index if exists public.scores_wallet_nonce_uidx;
alter table public.scores
  drop column if exists nonce,
  drop column if exists msg,
  drop column if exists sig,
  add column if not exists run_id text;
update public.scores set run_id = 'legacy-' || id where run_id is null;
alter table public.scores alter column run_id set not null;
create unique index if not exists scores_run_uidx on public.scores (run_id);

create or replace function public.scores_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.scores
             where wallet = new.wallet and created_at > now() - interval '15 seconds') then
    raise exception 'too many submissions, wait a bit';
  end if;
  if new.ip_hash is not null and (select count(*) from public.scores
             where ip_hash = new.ip_hash and created_at > now() - interval '1 minute') >= 6 then
    raise exception 'too many submissions from this network';
  end if;
  -- ~12 taps per ship, humans mash ~10-12 taps/s => about 1 ship/s at the very best
  if new.ships > new.duration_s * 1.5 + 3 then
    raise exception 'implausible ships for % seconds', new.duration_s;
  end if;
  -- every ship risky (x3) with an unbroken streak + all taps during fireworks (x2) stays under this
  if new.score > 1000 + new.ships * (600 + 200 * new.ships) then
    raise exception 'implausible score for % ships', new.ships;
  end if;
  if new.best_streak > new.ships then
    raise exception 'streak cannot exceed ships';
  end if;
  return new;
end $$;

-- leaderboard view is unchanged (wallet, best, ships, best_streak, runs, last_run)
