-- Paddock : parrainage récompensé (3 paquets chacun au niveau 5 du filleul)
-- parrainage récompensé : quand un filleul atteint le niveau 5, le parrain et le filleul gagnent 3 paquets chacun (une seule fois)
alter table public.profiles add column if not exists ref_rewarded boolean not null default false;
create or replace function public._ref_reward(u uuid) returns void language plpgsql security definer set search_path = public as $$
declare p profiles; par profiles;
begin
  select * into p from profiles where id = u for update;
  if p.id is null or p.invited_by is null or p.ref_rewarded or p.banned then return; end if;
  select * into par from profiles where id = p.invited_by;
  update profiles set ref_rewarded = true where id = u;
  update wallets set packs = packs + 3 where user_id = u;
  perform _notify(u, 'Parrainage : vous avez atteint le niveau 5 ! Vous gagnez 3 paquets' || case when par.id is not null and not par.banned then ', et ' || par.username || ' aussi.' else '.' end);
  if par.id is not null and not par.banned then
    update wallets set packs = packs + 3 where user_id = par.id;
    perform _notify(par.id, 'Parrainage : ' || p.username || ' a atteint le niveau 5. Vous gagnez 3 paquets !');
  end if;
end $$;
create or replace function public.get_refs() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'lv', _lvl(me.xp), 'done', me.ref_rewarded,
    'parrain', case when me.invited_by is not null then _user_json(me.invited_by) end,
    'kids', coalesce((select jsonb_agg(_user_json(k.id) || jsonb_build_object('lv', _lvl(k.xp), 'done', k.ref_rewarded) order by k.ref_rewarded, k.xp desc)
                      from (select * from profiles where invited_by = me.id and not banned order by created_at desc limit 60) k), '[]'::jsonb))
  from profiles me where me.id = _uid()
$$;
revoke all on function public._ref_reward(uuid) from public, anon, authenticated;
grant execute on function public.get_refs() to authenticated;
-- gagne de l'expérience ; à chaque niveau : 5 pistons par niveau (max 150), et 2 paquets tous les 5 niveaux
create or replace function public._xp_add(u uuid, n int) returns void language plpgsql security definer set search_path = public as $$
declare old int; nw int; l int; gc int := 0; gp int := 0;
begin
  if n <= 0 then return; end if;
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
