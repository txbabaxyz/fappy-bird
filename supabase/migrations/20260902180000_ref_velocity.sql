-- Referral velocity cap: a referrer can bind at most 30 new referees per 24 h (extra sign-ups still
-- succeed, just unreferred). Raises the cost of sybil farming without blocking anyone from playing.
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
    if referrer is not null and (select count(*) from public.players where referred_by = referrer and created_at > now() - interval '24 hours') >= 30 then referrer := null; end if;
  end if;
  loop
    code := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
    begin
      insert into public.players (wallet, ref_code, referred_by) values (lw, code, referrer);
      exit;
    exception when unique_violation then
      tries := tries + 1; if tries > 5 then raise; end if;
      select * into existing from public.players where wallet = lw;
      if found then return json_build_object('ref_code', existing.ref_code, 'referred', existing.referred_by is not null, 'created', false); end if;
    end;
  end loop;
  return json_build_object('ref_code', code, 'referred', referrer is not null, 'created', true);
end $$;
revoke all on function public.ensure_player(text, text) from public, anon, authenticated;

-- Carrier-grade NAT means thousands of phones can share one IP: loosen the per-IP submit limit.
create or replace function public.scores_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.scores
             where wallet = new.wallet and created_at > now() - interval '5 seconds') then
    raise exception 'too many submissions, wait a bit';
  end if;
  if new.ip_hash is not null and (select count(*) from public.scores
             where ip_hash = new.ip_hash and created_at > now() - interval '1 minute') >= 60 then
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
