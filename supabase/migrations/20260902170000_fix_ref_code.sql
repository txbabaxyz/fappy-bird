-- gen_random_bytes lives in the extensions schema (pgcrypto); use the built-in gen_random_uuid instead.
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
