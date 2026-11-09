-- Paddock : objectif commun plus difficile (35 % de plus que la semaine précédente, 1 000 minimum)
create or replace function public._comm_target() returns int language sql stable security definer set search_path = public as $$
  select greatest(1000, (ceil(1.35 * coalesce((select packs from community where week = _week_prev()), 0) / 100.0) * 100)::int)
$$;
-- semaine en cours : nouvel objectif tout de suite (s'il n'est pas déjà atteint)
update public.community set target = public._comm_target() where week = public._week_id() and done_at is null;
select week, packs, target from public.community where week = public._week_id();

-- =====================================================================
--  PADDOCK — bonus Paddock Pro :
--    • +25 % d'expérience (on monte de niveau plus vite)
--    • paquets normaux un peu plus généreux : 1,5 % de légendaire (1 % sinon), 5 % d'ultra rare (4 %), 8 % de super rare (7 %)
--  Peut être relancé sans risque.
-- =====================================================================
create or replace function public._draw_vip() returns int language plpgsql volatile security definer set search_path = public as $$
declare x float := random() * 100; r text; cid int;
begin
  r := case when x < 47 then 'C' when x < 72 then 'PC' when x < 85.5 then 'R' when x < 93.5 then 'SR' when x < 98.5 then 'UR' else 'L' end;
  select id into cid from cards where rarity = r order by random() limit 1;
  if cid is null then select id into cid from cards where rarity <> 'ED' order by random() limit 1; end if;
  return cid;
end $$;
revoke all on function public._draw_vip() from public, anon, authenticated;

create or replace function public._xp_add(u uuid, n int) returns void language plpgsql security definer set search_path = public as $$
declare old int; nw int; l int; gc int := 0; gp int := 0;
begin
  if n <= 0 then return; end if;
  if _is_pro(u) then n := ceil(n * 1.25)::int; end if;   -- Paddock Pro : +25 % d'expérience
  update profiles set xp = xp + n where id = u returning xp - n, xp into old, nw;
  if old is null or _lvl(nw) <= _lvl(old) then return; end if;
  for l in _lvl(old) + 1 .. _lvl(nw) loop
    gc := gc + least(5 * l, 150);
    if l % 5 = 0 then gp := gp + 2; end if;
  end loop;
  update wallets set coins = coins + gc, packs = packs + gp where user_id = u;
  perform _notify(u, 'Niveau ' || _lvl(nw) || ' atteint ! +' || gc || ' pistons' || case when gp > 0 then ' et ' || gp || ' paquets bonus' else '' end || '.');
  if _lvl(nw) >= 5 then perform _ref_reward(u); end if;
end $$;
revoke all on function public._xp_add(uuid, int) from public, anon, authenticated;

create or replace function public.open_pack(kind text default 'normal') returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); w wallets; pro boolean := _is_pro(u); n int; ids int[] := '{}'; t int := _ev_theme();
        c int; h boolean; i int; res jsonb := '[]'::jsonb; isnew boolean; got_holo boolean := false;
begin
  perform _sync_packs(u);
  select * into w from wallets where user_id = u for update;
  if kind = 'normal' then
    if w.packs < 1 then raise exception 'Plus de paquet disponible. Le prochain arrive bientôt.'; end if;
    update wallets set packs = packs - 1, pack_ts = case when w.packs >= 10 then now() else pack_ts end, full_notified = false where user_id = u;
    n := 5;
  elsif kind = 'pro' then
    if not pro then raise exception 'Le pack Paddock Pro est réservé aux membres Paddock Pro.'; end if;
    -- recharge chaque jour à minuit (heure de Paris)
    if w.pro_pack_ts is not null and (w.pro_pack_ts at time zone 'Europe/Paris')::date >= (now() at time zone 'Europe/Paris')::date then raise exception 'Votre prochain pack Paddock Pro n''est pas encore prêt.'; end if;
    update wallets set pro_pack_ts = now(), pro_notified = false where user_id = u;
    n := 10;
  elsif kind = 'event' then
    if w.ev_pack_ts is not null and w.ev_pack_ts > now() - (case when pro then interval '12 hours' else interval '24 hours' end) then raise exception 'Votre prochain paquet d''événement n''est pas encore prêt.'; end if;   -- Paddock Pro : 2 par jour
    update wallets set ev_pack_ts = now() where user_id = u;
    if t = 0 then
      select id into c from cards where rarity = 'ED' order by random() limit 1;
      if c is not null then ids := ids || c; end if;
      n := 4;
    else
      ids := ids || _draw_ev(t, true);
      for i in 1..4 loop ids := ids || _draw_ev(t, false); end loop;
      n := 0;
    end if;
  else raise exception 'Type de paquet inconnu.'; end if;
  -- pack Paddock Pro : la 1re carte est une ultra rare ou une légendaire garantie (20 % de légendaire)
  if kind = 'pro' then ids := ids || _draw_pro_top(); n := n - 1; end if;
  -- Paddock Pro : paquets normaux un peu plus généreux
  for i in 1..n loop ids := ids || case when kind = 'pro' then _draw(true) when pro then _draw_vip() else _draw(false) end; end loop;
  foreach c in array ids loop
    h := random() < case when kind = 'pro' then 0.05 else 0.03 end;
    got_holo := got_holo or h;
    isnew := _give(u, c, h);
    res := res || jsonb_build_array(jsonb_build_object('id', c, 'holo', h, 'new', isnew));
  end loop;
  perform _stat_inc(u, 'packs'); perform _wk_inc(u, 'packs'); perform _comm_inc(u);
  if got_holo then perform _notify(u, 'Vous avez obtenu une carte brillante !'); end if;
  return res;
end $$;
revoke all on function public.open_pack(text) from public, anon;
grant execute on function public.open_pack(text) to authenticated;
