-- player_stats: local variable "total" shadowed the leaderboard column -> ambiguous reference.
create or replace function public.player_stats(w text default null)
returns json
language plpgsql security definer set search_path = public stable as $$
declare
  lw text := lower(coalesce(w, ''));
  g bigint; my_best integer; my_rank integer; n_players integer; p public.players%rowtype; my_total bigint; upd timestamptz;
begin
  select count(distinct s.wallet) into n_players from public.scores s;
  select st.updated_at into upd from public.settings st where st.key = 'ref_refreshed_at';
  if lw !~ '^0x[0-9a-f]{40}$' then
    return json_build_object('players', n_players, 'ref_refreshed_at', upd);
  end if;
  select sum(s.score), max(s.score) into g, my_best from public.scores s where s.wallet = lw;
  select * into p from public.players pl where pl.wallet = lw;
  my_total := coalesce(g, 0) + coalesce(p.ref_bonus, 0);
  if my_total > 0 then
    select 1 + count(*) into my_rank from public.leaderboard l where l.total > my_total;
  end if;
  return json_build_object('players', n_players, 'total', case when my_total > 0 then my_total end, 'game_points', coalesce(g, 0),
    'best', my_best, 'rank', my_rank,
    'ref_code', p.ref_code, 'ref_count', coalesce(p.ref_count, 0), 'ref_points', coalesce(p.ref_points, 0),
    'ref_bonus', coalesce(p.ref_bonus, 0), 'referred', p.referred_by is not null, 'ref_refreshed_at', upd);
end $$;
revoke all on function public.player_stats(text) from public, authenticated;
grant execute on function public.player_stats(text) to anon;
