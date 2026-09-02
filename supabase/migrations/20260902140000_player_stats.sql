-- Public, read-only stats for the leaderboard modal: total players, and (for a given wallet)
-- its best score and rank. Exposes nothing beyond what the leaderboard already shows.
create or replace function public.player_stats(w text default null)
returns json
language plpgsql security definer set search_path = public stable as $$
declare
  lw text := lower(coalesce(w, ''));
  my_best integer;
  my_rank integer;
  players integer;
begin
  select count(distinct wallet) into players from public.scores;
  if lw ~ '^0x[0-9a-f]{40}$' then
    select max(score) into my_best from public.scores where wallet = lw;
    if my_best is not null then
      select 1 + count(*) into my_rank
      from (select wallet, max(score) as m from public.scores group by wallet) t
      where t.m > my_best;
    end if;
  end if;
  return json_build_object('players', players, 'best', my_best, 'rank', my_rank);
end $$;
revoke all on function public.player_stats(text) from public, authenticated;
grant execute on function public.player_stats(text) to anon;
