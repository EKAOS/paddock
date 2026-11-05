-- PADDOCK : la plus grosse mise à jour (hiver + vagues 1 à 4 + Paddock Pro + objectif commun).
-- À coller en une fois dans Supabase > SQL Editor > Run. Peut être relancé sans risque.

-- objectif : 15 % de plus que les paquets réellement ouverts la semaine précédente (arrondi à la centaine, 500 minimum).
-- Il s'ajuste tout seul : si l'objectif est raté, celui de la semaine suivante repart du total plus bas.
create or replace function public._comm_target() returns int language sql stable security definer set search_path = public as $$
  select greatest(500, (ceil(1.15 * coalesce((select packs from community where week = _week_prev()), 0) / 100.0) * 100)::int)
$$;
-- semaine en cours : nouvel objectif tout de suite, sauf s'il est déjà atteint
update public.community set target = public._comm_target() where week = public._week_id() and done_at is null;
-- garde-fou : si le nouvel objectif est déjà dépassé, il est considéré comme atteint
with w as (update public.community set done_at = now() where week = public._week_id() and done_at is null and packs >= target returning week)
select public._notify(c.user_id, 'Objectif commun atteint ! Récupérez votre paquet communautaire dans l''onglet Paquets.')
from public.community_contrib c join w on w.week = c.week;

-- =====================================================================
--  PADDOCK — mise à jour d'hiver :
--    • Séries : petites collections thématiques, récompensées en paquets + badge
--    • Améliorer une voiture avec ses propres doublons (sans pistons)
--    • Noël du 1er décembre au 6 janvier + calendrier de l'Avent (1er au 24 décembre)
--    • Saisons classées : classement des batailles en direct remis à zéro chaque mois,
--      paquets pour les 50 premiers
--    • Vitrine du profil : 6 voitures au lieu de 3
--  À coller après les autres fichiers. Peut être relancé sans risque.
-- =====================================================================

-- ---------- Séries -------------------------------------------------------
create table if not exists public.series (
  k text primary key,
  name text not null,
  emoji text not null default '',
  packs int not null,
  ids int[] not null
);
alter table public.series enable row level security;
alter table public.wallets add column if not exists series_claimed text[] not null default '{}';

create or replace function public.claim_series(sk text) returns int language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); s series; owned int;
begin
  select * into s from series where k = sk;
  if s.k is null then raise exception 'Série inconnue.'; end if;
  select count(*) into owned from inventory where user_id = u and card_id = any(s.ids);
  if owned < cardinality(s.ids) then raise exception 'Série pas encore complétée.'; end if;
  update wallets set series_claimed = series_claimed || s.k, packs = packs + s.packs
  where user_id = u and not (s.k = any(series_claimed));
  if not found then raise exception 'Récompense déjà récupérée.'; end if;
  perform _notify(u, 'Série « ' || s.name || ' » complétée : ' || s.packs || ' paquets offerts !');
  return s.packs;
end $$;

-- ---------- Améliorer avec ses doublons ------------------------------------
-- niveau 1 → 2 : 1 doublon, 2 → 3 : 2, 3 → 4 : 3, 4 → 5 : 4. Les cartes brillantes ne sont jamais utilisées.
create or replace function public.upgrade_dup(cid int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); iv inventory; need int;
begin
  select * into iv from inventory where user_id = u and card_id = cid for update;
  if iv.user_id is null then raise exception 'Vous ne possédez pas cette voiture.'; end if;
  if iv.lvl >= 5 then raise exception 'Cette voiture est déjà au niveau maximum.'; end if;
  need := iv.lvl;
  if iv.n - greatest(1, iv.holo) < need then raise exception 'Il vous faut % doublon% de cette voiture.', need, case when need > 1 then 's' else '' end; end if;
  update inventory set n = n - need, lvl = lvl + 1 where user_id = u and card_id = cid;
  perform _stat_inc(u, 'fus');
  return jsonb_build_object('lvl', iv.lvl + 1, 'n', iv.n - need);
end $$;

-- ---------- Noël : du 1er décembre au 6 janvier ------------------------------
create or replace function public._ev_noel() returns boolean language sql stable as $$
  select extract(month from now() at time zone 'Europe/Paris') = 12
      or (extract(month from now() at time zone 'Europe/Paris') = 1 and extract(day from now() at time zone 'Europe/Paris') <= 6)
$$;
create or replace function public._ev_until() returns timestamptz language sql stable security definer set search_path = public as $$
  select coalesce(_ev_manual(),
    case when _ev_noel() then (make_date(extract(year from now() at time zone 'Europe/Paris')::int + case when extract(month from now() at time zone 'Europe/Paris') = 12 then 1 else 0 end, 1, 7)::timestamp) at time zone 'Europe/Paris' end,
    (date_trunc('week', now() at time zone 'Europe/Paris') + interval '7 days') at time zone 'Europe/Paris')
$$;

-- ---------- Calendrier de l'Avent ------------------------------------------
create table if not exists public.advent (
  user_id uuid not null references public.profiles(id) on delete cascade,
  yr int not null,
  day int not null check (day between 1 and 24),
  primary key (user_id, yr, day)
);
alter table public.advent enable row level security;
-- récompense du jour : c = pistons, p = paquets, SR / UR / L = une voiture de cette rareté
create or replace function public._adv(d int) returns text[] language sql immutable as $$
  select (array[
    array['c','100'], array['p','1'], array['c','150'], array['p','2'], array['c','200'], array['SR','1'],
    array['p','2'], array['c','250'], array['p','3'], array['c','300'], array['p','2'], array['UR','1'],
    array['c','350'], array['p','3'], array['c','400'], array['p','3'], array['c','450'], array['UR','1'],
    array['p','4'], array['c','500'], array['p','4'], array['c','600'], array['p','5'], array['L','1']])[d:d][1:2]
$$;
create or replace function public._adv_today() returns int language sql stable as $$
  select case when extract(month from now() at time zone 'Europe/Paris') = 12 and extract(day from now() at time zone 'Europe/Paris') <= 24
    then extract(day from now() at time zone 'Europe/Paris')::int end
$$;
create or replace function public.claim_advent() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); d int := _adv_today(); y int := extract(year from now() at time zone 'Europe/Paris')::int; r text[]; c int; isnew boolean;
begin
  if d is null then raise exception 'Le calendrier de l''Avent est ouvert du 1er au 24 décembre.'; end if;
  insert into advent(user_id, yr, day) values (u, y, d) on conflict do nothing;
  if not found then raise exception 'Vous avez déjà ouvert la case d''aujourd''hui. Revenez demain !'; end if;
  select array_agg(x) into r from unnest(_adv(d)) x;
  if r[1] = 'c' then
    update wallets set coins = coins + r[2]::int where user_id = u;
    return jsonb_build_object('day', d, 'coins', r[2]::int);
  elsif r[1] = 'p' then
    update wallets set packs = packs + r[2]::int where user_id = u;
    return jsonb_build_object('day', d, 'packs', r[2]::int);
  else
    select id into c from cards where rarity = r[1] order by random() limit 1;
    -- le 24 : une légendaire signée
    if r[1] = 'L' then isnew := _give_signed(u, c); else isnew := _give(u, c, false); end if;
    return jsonb_build_object('day', d, 'card', c, 'new', isnew, 'signed', r[1] = 'L');
  end if;
end $$;

-- ---------- Saisons classées (batailles en direct, une saison = un mois) ------
-- victoire 3 points, égalité 1 point ; au plus 15 points par adversaire et par saison (pas de « farm » entre amis)
create index if not exists live_battles_done on public.live_battles (updated_at) where status = 'done';
create table if not exists public.season_results (
  season text not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  rank int not null, pts int not null, packs int not null,
  primary key (season, user_id)
);
alter table public.season_results enable row level security;

create or replace function public._season_id(t timestamptz default now()) returns text language sql stable as $$
  select to_char(t at time zone 'Europe/Paris', 'YYYY-MM')
$$;
create or replace function public._season_scores(s text) returns table(p uuid, pts int, w int, g int) language sql stable security definer set search_path = public as $$
  with b as (
    select p1, p2, winner from live_battles
    where status = 'done' and p2 is not null and p1 <> p2
      and updated_at >= (to_date(s, 'YYYY-MM')::timestamp at time zone 'Europe/Paris')
      and updated_at <  ((to_date(s, 'YYYY-MM') + interval '1 month')::timestamp at time zone 'Europe/Paris')
  ), x as (
    select p1 as p, p2 as o, case winner when 1 then 3 when 0 then 1 else 0 end as pts, (winner = 1)::int as w from b
    union all
    select p2, p1, case winner when 2 then 3 when 0 then 1 else 0 end, (winner = 2)::int from b
  ), y as (
    select x.p, least(15, sum(x.pts))::int as pts, sum(x.w)::int as w, count(*)::int as g from x group by x.p, x.o
  )
  select y.p, sum(y.pts)::int, sum(y.w)::int, sum(y.g)::int from y join profiles pr on pr.id = y.p where not pr.banned group by y.p
$$;
create or replace function public._season_prize(r int) returns int language sql immutable as $$
  select case when r = 1 then 15 when r = 2 then 10 when r = 3 then 8 when r <= 10 then 5 when r <= 25 then 3 when r <= 50 then 2 else 0 end
$$;
-- clôture de la saison précédente, une seule fois (appelée à chaque synchronisation, ne fait rien si c'est déjà fait)
create or replace function public._season_settle() returns void language plpgsql security definer set search_path = public as $$
declare s text := _season_id(now() - interval '1 month'); rec record; k int := 0;
begin
  if exists (select 1 from settings where key = 'season_done:' || s) then return; end if;
  if not pg_try_advisory_xact_lock(hashtext('paddock_season')) then return; end if;
  if exists (select 1 from settings where key = 'season_done:' || s) then return; end if;
  for rec in select sc.p, sc.pts from _season_scores(s) sc where sc.pts >= 3 order by sc.pts desc, sc.w desc, sc.g asc limit 50 loop
    k := k + 1;
    insert into season_results(season, user_id, rank, pts, packs) values (s, rec.p, k, rec.pts, _season_prize(k)) on conflict do nothing;
    update wallets set packs = packs + _season_prize(k) where user_id = rec.p;
    -- podium : une ultra rare signée en plus
    if k <= 3 then perform _give_signed(rec.p, (select id from cards where rarity = 'UR' order by random() limit 1)); end if;
    perform _notify(rec.p, 'Fin de saison : vous terminez ' || case when k = 1 then '1er' else k || 'e' end || ' du classement ! ' || _season_prize(k) || ' paquets offerts' || case when k <= 3 then ' et une ultra rare signée.' else '.' end);
  end loop;
  insert into settings(key, value) values ('season_done:' || s, jsonb_build_object('at', now(), 'n', k)) on conflict do nothing;
end $$;

-- la première saison commence avec cette mise à jour : le mois précédent n'est pas récompensé
insert into public.settings(key, value) values ('season_done:' || public._season_id(now() - interval '1 month'), '{"skip": true}'::jsonb) on conflict do nothing;

create or replace function public.get_season() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); s text := _season_id(); me record; myrank int; top jsonb;
begin
  perform _season_settle();
  with sc as (select * from _season_scores(s)),
       rk as (select sc.*, row_number() over (order by pts desc, w desc, g asc) as r from sc where pts > 0)
  select coalesce(jsonb_agg(_user_json(rk.p) || jsonb_build_object('pts', rk.pts, 'w', rk.w, 'g', rk.g, 'r', rk.r, 'me', rk.p = u) order by rk.r) filter (where rk.r <= 50), '[]'::jsonb),
         max(rk.r) filter (where rk.p = u)
    into top, myrank from rk;
  select * into me from _season_scores(s) x where x.p = u;
  return jsonb_build_object('season', s,
    'until', ((date_trunc('month', now() at time zone 'Europe/Paris') + interval '1 month') at time zone 'Europe/Paris'),
    'top', top, 'rank', myrank, 'pts', coalesce(me.pts, 0), 'w', coalesce(me.w, 0), 'g', coalesce(me.g, 0),
    'last', (select jsonb_build_object('season', season, 'rank', rank, 'packs', packs) from season_results where user_id = u order by season desc limit 1));
end $$;

-- ---------- Vitrine : 6 voitures (9 avec Paddock Pro) ------------------------------
create or replace function public._showcase_cap() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(array_length(new.showcase, 1), 0) > 6 and not _is_pro(new.id) then new.showcase := new.showcase[1:6]; end if;
  return new;
end $$;
drop trigger if exists profiles_showcase_cap on public.profiles;
create trigger profiles_showcase_cap before update of showcase on public.profiles for each row execute function public._showcase_cap();
do $$ begin
  alter table public.profiles add constraint showcase_max9 check (coalesce(array_length(showcase, 1), 0) <= 9) not valid;
exception when duplicate_object then null; end $$;

-- ---------- Droits ------------------------------------------------------------
revoke all on function public._adv(int), public._adv_today(), public._season_scores(text), public._season_settle(), public._season_prize(int) from public, anon, authenticated;
revoke all on function public.claim_series(text), public.upgrade_dup(int), public.claim_advent(), public.get_season() from public, anon;
grant execute on function public.claim_series(text), public.upgrade_dup(int), public.claim_advent(), public.get_season() to authenticated;

-- =====================================================================
--  PADDOCK — vague 1 :
--    • Carte du mois : les joueurs votent pendant le mois pour la carte du mois suivant,
--      tous les votants la reçoivent le 1er
--    • Chasse aux objets cachés (Noël, Halloween, Pâques) : 3 objets par jour cachés dans les menus
--    • Paddock Wrapped : le bilan de l'année de chaque joueur
--  Peut être relancé sans risque.
-- =====================================================================

-- ---------- Carte du mois ----------------------------------------------------
create table if not exists public.cotm (
  month text primary key,             -- mois du vote (AAAA-MM) ; la carte gagnante est celle du mois suivant
  options int[] not null,
  winner int,
  settled_at timestamptz
);
create table if not exists public.cotm_votes (
  month text not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  choice int not null,
  primary key (month, user_id)
);
alter table public.cotm enable row level security;
alter table public.cotm_votes enable row level security;

-- 4 voitures légendaires ou ultra rares, tirées au hasard mais toujours les mêmes pour un mois donné
create or replace function public._cotm_row(m text) returns cotm language plpgsql security definer set search_path = public as $$
declare r cotm;
begin
  select * into r from cotm where month = m;
  if r.month is null then
    insert into cotm(month, options)
    select m, array_agg(id) from (select id from cards where rarity in ('L', 'UR') order by md5(id::text || m) limit 4) x
    on conflict do nothing;
    select * into r from cotm where month = m;
  end if;
  return r;
end $$;

-- le mois précédent est clos : la carte la plus votée est donnée à tous ceux qui ont voté
create or replace function public._cotm_settle() returns void language plpgsql security definer set search_path = public as $$
declare m text := _season_id(now() - interval '1 month'); r cotm; w int; v record;
begin
  select * into r from cotm where month = m;
  if r.month is null or r.settled_at is not null then return; end if;
  if not pg_try_advisory_xact_lock(hashtext('paddock_cotm')) then return; end if;
  select * into r from cotm where month = m for update;
  if r.settled_at is not null then return; end if;
  select choice into w from cotm_votes where month = m group by choice order by count(*) desc, min(user_id::text) limit 1;
  update cotm set winner = w, settled_at = now() where month = m;
  if w is null then return; end if;
  for v in select user_id from cotm_votes where month = m loop
    perform _give(v.user_id, w, _is_pro(v.user_id));   -- Paddock Pro : en version brillante
    perform _notify(v.user_id, 'Carte du mois : la ' || (select name from cards where id = w) || ' a gagné le vote ! Elle est dans votre collection.');
  end loop;
end $$;

create or replace function public._cotm_json(u uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare m text := _season_id(); r cotm; p cotm;
begin
  r := _cotm_row(m);
  select * into p from cotm where month = _season_id(now() - interval '1 month');
  return jsonb_build_object('month', m, 'opts', to_jsonb(r.options),
    'votes', (select jsonb_agg(coalesce((select count(*) from cotm_votes v where v.month = m and v.choice = o), 0) order by k) from unnest(r.options) with ordinality as x(o, k)),
    'mine', (select choice from cotm_votes where month = m and user_id = u),
    'prev', case when p.winner is not null then jsonb_build_object('month', p.month, 'winner', p.winner,
      'got', exists (select 1 from cotm_votes where month = p.month and user_id = u)) end);
end $$;

create or replace function public.vote_cotm(c int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); m text := _season_id(); r cotm;
begin
  r := _cotm_row(m);
  if not (c = any(r.options)) then raise exception 'Cette voiture ne fait pas partie du vote.'; end if;
  insert into cotm_votes(month, user_id, choice) values (m, u, c)
  on conflict (month, user_id) do update set choice = excluded.choice;
  return _cotm_json(u);
end $$;

-- ---------- Chasse aux objets cachés -------------------------------------------
-- Pâques (algorithme de Meeus) : la chasse dure du samedi d'avant au dimanche d'après
create or replace function public._easter(y int) returns date language plpgsql immutable as $$
declare a int := y % 19; b int := y / 100; c int := y % 100; d int := b / 4; e int := b % 4; f int := (b + 8) / 25;
        g int := (b - f + 1) / 3; h int := (19 * a + b - d - g + 15) % 30; i int := c / 4; k int := c % 4;
        l int := (32 + 2 * e + 2 * i - h - k) % 7; m int := (a + 11 * h + 22 * l) / 451;
begin
  return make_date(y, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1);
end $$;
create or replace function public._hunt_season() returns text language plpgsql stable as $$
declare t date := (now() at time zone 'Europe/Paris')::date; y int := extract(year from t)::int; e date := _easter(y);
begin
  if extract(month from t) = 12 then return 'noel-' || y; end if;
  if extract(month from t) = 1 and extract(day from t) <= 6 then return 'noel-' || (y - 1); end if;
  if (extract(month from t) = 10 and extract(day from t) >= 20) or (extract(month from t) = 11 and extract(day from t) <= 2) then return 'halloween-' || y; end if;
  if t between e - 8 and e + 7 then return 'paques-' || y; end if;
  return null;
end $$;
create table if not exists public.hunt (
  user_id uuid not null references public.profiles(id) on delete cascade,
  season text not null,
  day date not null,
  slot int not null check (slot between 0 and 4),
  primary key (user_id, day, slot)
);
alter table public.hunt enable row level security;
create or replace function public.claim_hunt(s int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); se text := _hunt_season(); t date := (now() at time zone 'Europe/Paris')::date;
begin
  if se is null then raise exception 'Aucune chasse en cours.'; end if;
  if s < 0 or s > (case when _is_pro(u) then 4 else 2 end) then raise exception 'Objet inconnu.'; end if;
  insert into hunt(user_id, season, day, slot) values (u, se, t, s) on conflict do nothing;
  if not found then raise exception 'Déjà trouvé !'; end if;
  update wallets set coins = coins + 30 where user_id = u;
  return jsonb_build_object('coins', 30, 'total', (select count(*) from hunt where user_id = u and season = se));
end $$;
create or replace function public._hunt_json(u uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select case when _hunt_season() is null then null else jsonb_build_object('season', _hunt_season(),
    'day', to_char((now() at time zone 'Europe/Paris')::date, 'YYYY-MM-DD'),
    'today', (select coalesce(jsonb_agg(slot), '[]'::jsonb) from hunt where user_id = u and day = (now() at time zone 'Europe/Paris')::date),
    'total', (select count(*) from hunt where user_id = u and season = _hunt_season())) end
$$;

-- ---------- Paddock Wrapped -------------------------------------------------------
create or replace function public.get_wrapped() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); p profiles; st jsonb; top int; fb record; riv record; pct numeric; tot int;
begin
  select * into p from profiles where id = u;
  select stats into st from wallets where user_id = u;
  select i.card_id into top from inventory i join cards c on c.id = i.card_id where i.user_id = u
    order by case c.rarity when 'ED' then 7 when 'L' then 6 when 'UR' then 5 when 'SR' then 4 when 'R' then 3 when 'PC' then 2 else 1 end desc, i.holo desc, c.hp desc limit 1;
  select c.brand, count(*) n into fb from inventory i join cards c on c.id = i.card_id where i.user_id = u group by c.brand order by count(*) desc, c.brand limit 1;
  select o, count(*) g, sum(w) w into riv from (
    select case when p1 = u then p2 else p1 end o, (winner = case when p1 = u then 1 else 2 end)::int w
    from live_battles where status = 'done' and p2 is not null and (p1 = u or p2 = u)) x group by o order by count(*) desc limit 1;
  select count(*) into tot from profiles where not banned;
  select round(100.0 * count(*) / greatest(1, tot)) into pct from profiles where not banned and unique_count > p.unique_count;
  return jsonb_build_object('year', extract(year from now() at time zone 'Europe/Paris')::int - case when extract(month from now() at time zone 'Europe/Paris') = 1 then 1 else 0 end,
    'since', p.created_at, 'lv', _lvl(p.xp), 'xp', p.xp,
    'packs', coalesce((st->>'packs')::int, 0), 'unique', p.unique_count,
    'cards', (select coalesce(sum(n), 0) from inventory where user_id = u),
    'legend', (select count(*) from inventory i join cards c on c.id = i.card_id where i.user_id = u and c.rarity = 'L'),
    'holo', (select coalesce(sum(holo), 0) from inventory where user_id = u),
    'top', top, 'brand', fb.brand, 'brand_n', coalesce(fb.n, 0),
    'battles', coalesce((st->>'battles')::int, 0), 'wins', coalesce((st->>'wins')::int, 0),
    'trades', coalesce((st->>'trades')::int, 0), 'sales', coalesce((st->>'sales')::int, 0),
    'rival', case when riv.o is not null then (select username from profiles where id = riv.o) end, 'rival_g', coalesce(riv.g, 0), 'rival_w', coalesce(riv.w, 0),
    'top_pct', greatest(1, least(100, pct + 1)), 'players', tot,
    'series', (select coalesce(array_length(series_claimed, 1), 0) from wallets where user_id = u),
    'friends', (select count(*) from friendships where user_id = u));
end $$;

-- ---------- Droits ------------------------------------------------------------
revoke all on function public._cotm_row(text), public._cotm_settle(), public._cotm_json(uuid), public._hunt_json(uuid) from public, anon, authenticated;
revoke all on function public.vote_cotm(int), public.claim_hunt(int), public.get_wrapped() from public, anon;
grant execute on function public.vote_cotm(int), public.claim_hunt(int), public.get_wrapped() to authenticated;

-- =====================================================================
--  PADDOCK — vague 2 (profil et collection) :
--    • Livrées de profil (couleurs débloquées avec les niveaux)
--    • Avatar : toute carte super rare ou mieux, avec un cadre de sa rareté
--    • Prestige : au niveau 30, repartir à zéro contre une étoile (5 au maximum)
--    • Titres de pilote, plaque d'immatriculation, statut « Je cherche »
--    • Cartes signées (récompenses), cote des voitures et valeur de la collection
--  Peut être relancé sans risque.
-- =====================================================================

alter table public.profiles add column if not exists livery text;
alter table public.profiles add column if not exists prestige int not null default 0;
alter table public.profiles add column if not exists title text;
alter table public.profiles add column if not exists plate text;
alter table public.profiles add column if not exists plate_at timestamptz;
alter table public.profiles add column if not exists seeking int[] not null default '{}';
alter table public.inventory add column if not exists signed int not null default 0;

-- une carte signée ne peut pas exister sans la carte : le nombre de signées suit le nombre d'exemplaires
create or replace function public._inv_clamp() returns trigger language plpgsql as $$
begin new.signed := least(greatest(new.signed, 0), new.n); return new; end $$;
drop trigger if exists inventory_signed_clamp on public.inventory;
create trigger inventory_signed_clamp before insert or update on public.inventory for each row execute function public._inv_clamp();

create or replace function public._give_signed(u uuid, c int) returns boolean language plpgsql security definer set search_path = public as $$
declare isnew boolean;
begin
  isnew := _give(u, c, false);
  update inventory set signed = signed + 1 where user_id = u and card_id = c;
  return isnew;
end $$;

-- pseudo, badges… et étoiles de prestige partout où un joueur apparaît
create or replace function public._user_json(u uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('u', username, 'cert', is_cert, 'mod', is_mod or is_admin, 'admin', is_admin,
           'pro', pro_permanent or coalesce(pro_until > now(), false), 'ac', avatar_card,
           'seen', case when is_public then last_seen end,
           'ai', case when avatar_img is not null then avatar_thumb end,
           'lv', floor(sqrt(coalesce(xp, 0) / 50.0))::int + 1, 'pr', prestige)
  from profiles where id = u
$$;

-- ---------- Livrées --------------------------------------------------------------
create or replace function public._livery_lv(k text) returns int language sql immutable as $$
  select case k when 'or' then 1 when 'rouge' then 3 when 'bleu' then 5 when 'vert' then 8 when 'orange' then 12
    when 'violet' then 16 when 'carbone' then 20 when 'arcenciel' then 25 when 'chrome' then 0 end
$$;
create or replace function public.set_livery(k text) returns void language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); p profiles; need int := _livery_lv(k);
begin
  select * into p from profiles where id = u;
  if need is null then raise exception 'Livrée inconnue.'; end if;
  if k = 'chrome' and not _is_pro(u) then raise exception 'La livrée Chrome est réservée aux membres Paddock Pro.'; end if;
  if p.prestige = 0 and _lvl(p.xp) < need then raise exception 'Livrée débloquée au niveau %.', need; end if;
  update profiles set livery = nullif(k, 'or') where id = u;
end $$;

-- ---------- Avatar : carte super rare ou mieux -------------------------------------
create or replace function public.set_avatar_card(c int) returns void language plpgsql security definer set search_path = public as $$
declare u uuid := _uid();
begin
  if c is null then update profiles set avatar_card = null where id = u; return; end if;
  if not exists (select 1 from inventory iv join cards cd on cd.id = iv.card_id where iv.user_id = u and iv.card_id = c and cd.rarity in ('SR', 'UR', 'L', 'ED')) then
    raise exception 'Choisissez une carte super rare ou mieux de votre collection.'; end if;
  update profiles set avatar_card = c, avatar_img = null where id = u;
end $$;

-- ---------- Prestige ------------------------------------------------------------------
create or replace function public.do_prestige() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); p profiles; c int;
begin
  select * into p from profiles where id = u for update;
  if p.prestige >= 5 then raise exception 'Vous avez déjà les 5 étoiles de prestige.'; end if;
  if _lvl(p.xp) < 30 then raise exception 'Le prestige se débloque au niveau 30.'; end if;
  update profiles set xp = 0, prestige = prestige + 1 where id = u;
  update wallets set packs = packs + 10 where user_id = u;
  select id into c from cards where rarity = 'L' order by random() limit 1;
  perform _give_signed(u, c);
  perform _notify(u, 'Prestige ' || (p.prestige + 1) || ' ⭐ ! 10 paquets et une légendaire signée vous attendent.');
  return jsonb_build_object('prestige', p.prestige + 1, 'card', c);
end $$;

-- ---------- Titres ---------------------------------------------------------------------
create or replace function public._titles(u uuid) returns text[] language plpgsql stable security definer set search_path = public as $$
declare p profiles; w wallets; t text[] := '{}'; leg int;
begin
  select * into p from profiles where id = u; select * into w from wallets where user_id = u;
  select count(*) into leg from inventory i join cards c on c.id = i.card_id where i.user_id = u and c.rarity = 'L';
  if p.unique_count >= 100 then t := array_append(t, 'collec100'); end if;
  if p.unique_count >= 500 then t := array_append(t, 'collec500'); end if;
  if p.unique_count >= 1500 then t := array_append(t, 'collec1500'); end if;
  if leg >= 10 then t := array_append(t, 'legend10'); end if;
  if coalesce((w.stats->>'sales')::int, 0) >= 50 then t := array_append(t, 'market50'); end if;
  if coalesce((w.stats->>'trades')::int, 0) >= 25 then t := array_append(t, 'trade25'); end if;
  if coalesce((w.stats->>'wins')::int, 0) >= 25 then t := array_append(t, 'win25'); end if;
  if coalesce((w.stats->>'wins')::int, 0) >= 100 then t := array_append(t, 'win100'); end if;
  if 'jdm' = any(w.series_claimed) then t := array_append(t, 'jdm'); end if;
  if 'ferrari' = any(w.series_claimed) then t := array_append(t, 'ferrari'); end if;
  if 'groupeb' = any(w.series_claimed) then t := array_append(t, 'groupeb'); end if;
  if exists (select 1 from season_results where user_id = u and rank <= 3) then t := array_append(t, 'podium'); end if;
  if exists (select 1 from season_results where user_id = u and rank = 1) then t := array_append(t, 'champion'); end if;
  if p.prestige >= 1 then t := array_append(t, 'prestige'); end if;
  if _is_pro(u) then t := array_append(t, 'membrepro'); end if;
  if exists (select 1 from hunt where user_id = u and season like 'noel-%' group by season having count(*) >= 30) then t := array_append(t, 'lutin'); end if;
  t := t || array(select 'c_' || k from combo_claims where user_id = u order by created_at);
  return t;
end $$;
create or replace function public.set_title(k text) returns void language plpgsql security definer set search_path = public as $$
declare u uuid := _uid();
begin
  if coalesce(k, '') = '' then update profiles set title = null where id = u; return; end if;
  if not (k = any(_titles(u))) then raise exception 'Titre pas encore débloqué.'; end if;
  update profiles set title = k where id = u;
end $$;

-- ---------- Plaque d'immatriculation ---------------------------------------------------
create or replace function public.set_plate(v text) returns text language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); p profiles; x text := upper(trim(coalesce(v, '')));
begin
  select * into p from profiles where id = u for update;
  if x = '' then update profiles set plate = null where id = u; return null; end if;
  if x !~ '^[A-Z0-9]{1,4}(-[A-Z0-9]{1,4}){0,2}$' or length(x) > 10 then raise exception 'Plaque : 10 caractères maximum, lettres, chiffres et tirets (ex. AB-123-CD).'; end if;
  if not _is_pro(u) and p.plate_at is not null and p.plate_at > now() - interval '30 days' then
    raise exception 'Vous pourrez changer de plaque 30 jours après le dernier changement (ou tout de suite avec Paddock Pro).'; end if;
  update profiles set plate = x, plate_at = now() where id = u;
  return x;
end $$;

-- ---------- Je cherche -------------------------------------------------------------------
create or replace function public.set_seeking(ids int[]) returns void language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); clean int[];
begin
  select coalesce(array_agg(distinct x), '{}') into clean from unnest(coalesce(ids, '{}')) x where exists (select 1 from cards where id = x and rarity <> 'ED');
  if cardinality(clean) > (case when _is_pro(u) then 6 else 3 end) then raise exception '% voitures maximum.', (case when _is_pro(u) then 6 else 3 end); end if;
  update profiles set seeking = clean where id = u;
end $$;

-- ---------- Cote et valeur de la collection ------------------------------------------------
create or replace function public._cote() returns table(card_id int, avg int) language sql stable security definer set search_path = public as $$
  select l.card_id, round(avg(b.mx))::int from listings l
  join lateral (select max(amount) mx from bids where listing_id = l.id) b on b.mx is not null
  where l.status = 'done' and l.created_at > now() - interval '60 days' group by l.card_id
$$;
create or replace function public._coll_value(u uuid) returns int language sql stable security definer set search_path = public as $$
  select coalesce(sum(i.n * c.avg), 0)::int from inventory i join _cote() c on c.card_id = i.card_id where i.user_id = u
$$;
create or replace function public.get_value_ranking() returns jsonb language sql stable security definer set search_path = public as $$
  with c as (select * from _cote()),
  v as (select i.user_id, sum(i.n * c.avg)::int val from inventory i join c on c.card_id = i.card_id group by i.user_id)
  select coalesce(jsonb_agg(_user_json(v.user_id) || jsonb_build_object('val', v.val, 'me', v.user_id = _uid()) order by v.val desc), '[]'::jsonb)
  from (select v.* from v join profiles p on p.id = v.user_id where not p.banned and (p.is_public or p.id = _uid()) order by v.val desc limit 50) v
$$;

-- ---------- Droits ------------------------------------------------------------------------
revoke all on function public._give_signed(uuid, int), public._livery_lv(text), public._titles(uuid), public._cote(), public._coll_value(uuid) from public, anon, authenticated;
revoke all on function public.set_livery(text), public.set_avatar_card(int), public.do_prestige(), public.set_title(text), public.set_plate(text), public.set_seeking(int[]), public.get_value_ranking() from public, anon;
grant execute on function public.set_livery(text), public.set_avatar_card(int), public.do_prestige(), public.set_title(text), public.set_plate(text), public.set_seeking(int[]), public.get_value_ranking() to authenticated;

-- =====================================================================
--  PADDOCK — vague 3 (social et fidélité) :
--    • Ligue entre amis
--    • Fil d'actualité des amis (légendaires obtenues, séries, prestige, voiture mystère…)
--    • Réactions sur les vitrines + Garage du jour
--    • Voiture mystère de la semaine
--    • Combinaisons secrètes de collection
--    • Coffre de fidélité (30 jours de présence)
--  Peut être relancé sans risque.
-- =====================================================================

-- ---------- Fil d'actualité ----------------------------------------------------------
create table if not exists public.feed (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,                 -- legend, series, prestige, mystery, combo, podium, loyalty
  card_id int,
  txt text,
  public boolean not null default false, -- visible par tous (voiture mystère)
  created_at timestamptz not null default now()
);
create index if not exists feed_user on public.feed (user_id, created_at desc);
create index if not exists feed_public on public.feed (created_at desc) where public;
alter table public.feed enable row level security;

create or replace function public._feed(u uuid, k text, c int, t text, pub boolean default false) returns void language sql security definer set search_path = public as $$
  insert into feed(user_id, kind, card_id, txt, public) values (u, k, c, t, pub)
$$;

-- une légendaire (ou édition limitée) qui entre pour la première fois dans une collection
create or replace function public._inv_feed() returns trigger language plpgsql security definer set search_path = public as $$
declare r text;
begin
  select rarity into r from cards where id = new.card_id;
  if r in ('L', 'ED') then perform _feed(new.user_id, 'legend', new.card_id, null); end if;
  return new;
end $$;
drop trigger if exists inventory_feed on public.inventory;
create trigger inventory_feed after insert on public.inventory for each row execute function public._inv_feed();

create or replace function public.get_feed() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(_user_json(f.user_id) || jsonb_build_object('k', f.kind, 'c', f.card_id, 'txt', f.txt, 't', f.created_at, 'pub', f.public) order by f.created_at desc), '[]'::jsonb)
  from (select f.* from feed f join profiles p on p.id = f.user_id
        where not p.banned and f.created_at > now() - interval '14 days'
          and (f.user_id = _uid() or f.public or f.user_id in (select friend_id from friendships where user_id = _uid()))
          and not _blocked(_uid(), f.user_id)
        order by f.created_at desc limit 40) f
$$;

-- ---------- Ligue entre amis ------------------------------------------------------------
create or replace function public.get_league() returns jsonb language sql stable security definer set search_path = public as $$
  with m as (select _uid() id union select friend_id from friendships where user_id = _uid()),
       s as (select * from _season_scores(_season_id()))
  select coalesce(jsonb_agg(_user_json(p.id) || jsonb_build_object('n', p.unique_count, 'xp', p.xp, 'pr', p.prestige, 'pts', coalesce(s.pts, 0), 'me', p.id = _uid())), '[]'::jsonb)
  from m join profiles p on p.id = m.id left join s on s.p = p.id where not p.banned
$$;

-- ---------- Réactions sur les vitrines --------------------------------------------------
create table if not exists public.show_reacts (
  target uuid not null references public.profiles(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  emoji text not null check (emoji in ('🔥', '😍', '🤯', '👏')),
  created_at timestamptz not null default now(),
  primary key (target, user_id)
);
alter table public.show_reacts enable row level security;
create or replace function public._reacts(t uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('counts', (select coalesce(jsonb_object_agg(emoji, n), '{}'::jsonb) from (select emoji, count(*) n from show_reacts where target = t group by emoji) x),
    'mine', (select emoji from show_reacts where target = t and user_id = auth.uid()))
$$;
create or replace function public.react_show(name text, e text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); t uuid := _uid_by_name(name);
begin
  if t is null then raise exception 'Joueur introuvable.'; end if;
  if t = u then raise exception 'Vous ne pouvez pas réagir à votre propre vitrine.'; end if;
  if _blocked(u, t) then raise exception 'Action impossible.'; end if;
  if coalesce(e, '') = '' then delete from show_reacts where target = t and user_id = u;
  else
    insert into show_reacts(target, user_id, emoji) values (t, u, e)
    on conflict (target, user_id) do update set emoji = excluded.emoji, created_at = now();
  end if;
  return _reacts(t);
end $$;

-- ---------- Garage du jour (et vitrine la plus aimée de la semaine) ----------------------
create or replace function public._garage_day() returns uuid language sql stable security definer set search_path = public as $$
  select p.id from profiles p
  where not p.banned and p.is_public and (select count(*) from unnest(p.showcase) x where x is not null) >= 3
  order by md5(p.id::text || to_char(now() at time zone 'Europe/Paris', 'YYYY-MM-DD')) limit 1
$$;
create or replace function public.get_garages() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare g uuid := _garage_day(); b uuid;
begin
  select target into b from show_reacts r join profiles p on p.id = r.target
  where not p.banned and p.is_public and r.created_at >= (date_trunc('week', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris')
  group by target order by count(*) desc, min(r.created_at) limit 1;
  return jsonb_build_object(
    'day', case when g is not null then _user_json(g) || jsonb_build_object('show', (select coalesce(jsonb_agg(x), '[]'::jsonb) from unnest((select showcase from profiles where id = g)) x where x is not null), 'reacts', _reacts(g)) end,
    'best', case when b is not null then _user_json(b) || jsonb_build_object('reacts', _reacts(b)) end);
end $$;

-- ---------- Voiture mystère de la semaine --------------------------------------------------
create table if not exists public.mystery (
  week text primary key,
  card_id int not null,
  finder uuid references public.profiles(id) on delete set null,
  found_at timestamptz
);
alter table public.mystery enable row level security;
create or replace function public._mystery_row() returns mystery language plpgsql security definer set search_path = public as $$
declare w text := _week_id(); r mystery;
begin
  select * into r from mystery where week = w;
  if r.week is null then
    insert into mystery(week, card_id) select w, id from cards where rarity in ('UR', 'L') order by md5(id::text || w || 'mystere') limit 1 on conflict do nothing;
    select * into r from mystery where week = w;
  end if;
  return r;
end $$;
-- le premier joueur qui obtient la voiture mystère (paquet, marché, échange…) la découvre
create or replace function public._mystery_check() returns trigger language plpgsql security definer set search_path = public as $$
declare r mystery;
begin
  if tg_op = 'UPDATE' and new.n <= old.n then return new; end if;
  select * into r from mystery where week = _week_id() and card_id = new.card_id and finder is null for update;
  if r.week is null then return new; end if;
  update mystery set finder = new.user_id, found_at = now() where week = r.week;
  update wallets set packs = packs + 5 where user_id = new.user_id;
  perform _notify(new.user_id, 'Vous avez trouvé la voiture mystère de la semaine ! 5 paquets offerts.');
  perform _feed(new.user_id, 'mystery', new.card_id, null, true);
  return new;
end $$;
drop trigger if exists inventory_mystery on public.inventory;
create trigger inventory_mystery after insert or update of n on public.inventory for each row execute function public._mystery_check();
create or replace function public._mystery_json() returns jsonb language plpgsql security definer set search_path = public as $$
declare r mystery := _mystery_row(); c cards;
begin
  select * into c from cards where id = r.card_id;
  return jsonb_build_object('week', r.week, 'until', ((date_trunc('week', now() at time zone 'Europe/Paris') + interval '7 days') at time zone 'Europe/Paris'),
    'found', r.finder is not null,
    'card', case when r.finder is not null then r.card_id end,
    'finder', case when r.finder is not null then (select username from profiles where id = r.finder) end,
    'hint', jsonb_build_object('r', c.rarity, 'decade', (c.y1 / 10) * 10, 'letter', left(c.brand, 1), 'body', c.body,
      'm1', case when coalesce(_is_pro(auth.uid()), false) then left(ltrim(substr(c.name, length(c.brand) + 1)), 1) end));
end $$;

-- ---------- Combinaisons secrètes ------------------------------------------------------------
create table if not exists public.combos (k text primary key, name text not null, coins int not null, ids int[] not null);
alter table public.combos enable row level security;
create table if not exists public.combo_claims (
  user_id uuid not null references public.profiles(id) on delete cascade,
  k text not null, created_at timestamptz not null default now(),
  primary key (user_id, k)
);
alter table public.combo_claims enable row level security;
-- vérifiées à chaque synchronisation : la récompense tombe toute seule
create or replace function public._combo_scan(u uuid) returns void language plpgsql security definer set search_path = public as $$
declare c combos;
begin
  for c in select * from combos cb where not exists (select 1 from combo_claims where user_id = u and k = cb.k)
           and (select count(*) from inventory where user_id = u and card_id = any(cb.ids)) = cardinality(cb.ids) loop
    insert into combo_claims(user_id, k) values (u, c.k) on conflict do nothing;
    if found then
      update wallets set coins = coins + c.coins where user_id = u;
      perform _notify(u, 'Combinaison secrète « ' || c.name || ' » découverte ! +' || c.coins || ' pistons et un nouveau titre.');
      perform _feed(u, 'combo', null, c.name);
    end if;
  end loop;
end $$;

-- ---------- Coffre de fidélité --------------------------------------------------------------
create table if not exists public.loyalty (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  days int not null default 0,
  last date,
  opened int not null default 0
);
alter table public.loyalty enable row level security;
create or replace function public._loyalty_tick(u uuid) returns loyalty language plpgsql security definer set search_path = public as $$
declare t date := (now() at time zone 'Europe/Paris')::date; l loyalty;
begin
  insert into loyalty(user_id, days, last) values (u, 1, t) on conflict (user_id) do update
    set days = least(30, loyalty.days + 1), last = t where loyalty.last is distinct from t;
  select * into l from loyalty where user_id = u;
  return l;
end $$;
create or replace function public.open_loyalty() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); l loyalty; c int; isnew boolean;
begin
  select * into l from loyalty where user_id = u for update;
  if l.user_id is null or l.days < (case when _is_pro(u) then 20 else 30 end) then raise exception 'Le coffre s''ouvre après % jours de présence.', (case when _is_pro(u) then 20 else 30 end); end if;
  update loyalty set days = 0, opened = opened + 1 where user_id = u;
  update wallets set packs = packs + 15, coins = coins + 500 where user_id = u;
  select id into c from cards where rarity = 'L' order by random() limit 1;
  isnew := _give(u, c, false);
  perform _feed(u, 'loyalty', c, null);
  return jsonb_build_object('card', c, 'new', isnew, 'packs', 15, 'coins', 500);
end $$;

-- ---------- Ajouts au fil d'actualité depuis les autres nouveautés --------------------------
create or replace function public._feed_series() returns trigger language plpgsql security definer set search_path = public as $$
declare sk text;
begin
  foreach sk in array new.series_claimed loop
    if not (sk = any(coalesce(old.series_claimed, '{}'))) then perform _feed(new.user_id, 'series', null, (select name from series where series.k = sk)); end if;
  end loop;
  return new;
end $$;
drop trigger if exists wallets_feed_series on public.wallets;
create trigger wallets_feed_series after update of series_claimed on public.wallets for each row execute function public._feed_series();
create or replace function public._feed_prestige() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.prestige > old.prestige then perform _feed(new.id, 'prestige', null, new.prestige::text); end if;
  return new;
end $$;
drop trigger if exists profiles_feed_prestige on public.profiles;
create trigger profiles_feed_prestige after update of prestige on public.profiles for each row execute function public._feed_prestige();

-- ---------- Droits -----------------------------------------------------------------------------
revoke all on function public._feed(uuid, text, int, text, boolean), public._inv_feed(), public._reacts(uuid), public._garage_day(), public._mystery_row(), public._mystery_check(),
  public._mystery_json(), public._combo_scan(uuid), public._loyalty_tick(uuid), public._feed_series(), public._feed_prestige() from public, anon, authenticated;
revoke all on function public.get_feed(), public.get_league(), public.react_show(text, text), public.get_garages(), public.open_loyalty() from public, anon;
grant execute on function public.get_feed(), public.get_league(), public.react_show(text, text), public.get_garages(), public.open_loyalty() to authenticated;

-- =====================================================================
--  PADDOCK — vague 4 :
--    • Décors de garage pour la vitrine (achetés en pistons)
--    • Trouvailles de grange : une épave par jour à restaurer en 3 étapes,
--      la voiture restaurée devient une carte brillante
--  Peut être relancé sans risque.
-- =====================================================================

-- ---------- Décors de garage --------------------------------------------------------
alter table public.profiles add column if not exists decor text;
create table if not exists public.decor_owned (
  user_id uuid not null references public.profiles(id) on delete cascade,
  k text not null, primary key (user_id, k)
);
alter table public.decor_owned enable row level security;
create or replace function public._decor_price(k text) returns int language sql immutable as $$
  select case k when 'box' then 0 when 'pro' then 0 when 'neige' then 400 when 'neon' then 500 when 'damier' then 600 when 'expo' then 800 when 'nuit' then 1000 when 'or' then 2500 end
$$;
create or replace function public.buy_decor(k text) returns int language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); pr int := _decor_price(k); c int;
begin
  if pr is null then raise exception 'Décor inconnu.'; end if;
  if pr = 0 or exists (select 1 from decor_owned where user_id = u and decor_owned.k = buy_decor.k) then raise exception 'Vous avez déjà ce décor.'; end if;
  update wallets set coins = coins - pr where user_id = u and coins >= pr returning coins into c;
  if c is null then raise exception 'Il vous faut % pistons.', pr; end if;
  insert into decor_owned(user_id, k) values (u, k);
  update profiles set decor = k where id = u;
  return c;
end $$;
create or replace function public.set_decor(k text) returns void language plpgsql security definer set search_path = public as $$
declare u uuid := _uid();
begin
  if _decor_price(k) is null then raise exception 'Décor inconnu.'; end if;
  if k = 'pro' and not _is_pro(u) then raise exception 'Le Garage Pro est réservé aux membres Paddock Pro.'; end if;
  if k not in ('box', 'pro') and not exists (select 1 from decor_owned where user_id = u and decor_owned.k = set_decor.k) then raise exception 'Achetez d''abord ce décor.'; end if;
  update profiles set decor = nullif(k, 'box') where id = u;
end $$;

-- ---------- Trouvailles de grange -------------------------------------------------------
create table if not exists public.barns (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  card_id int,
  step int not null default 0,
  next_at timestamptz,
  last_search date,
  restored int not null default 0
);
alter table public.barns add column if not exists searches int not null default 0;
alter table public.barns enable row level security;
create or replace function public._barn_cost(s int) returns int language sql immutable as $$ select (array[100, 150, 250])[s + 1] $$;
create or replace function public._barn_json(u uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('card', b.card_id, 'step', coalesce(b.step, 0), 'next', b.next_at, 'restored', coalesce(b.restored, 0),
    'cost', case when b.card_id is not null then _barn_cost(b.step) end,
    'can_search', b.card_id is null and (b.last_search is distinct from (now() at time zone 'Europe/Paris')::date or (_is_pro(u) and b.searches < 2)))
  from (select 1) x left join barns b on b.user_id = u
$$;
create or replace function public.barn_search() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); b barns; x float := random() * 100; r text; c int;
begin
  insert into barns(user_id) values (u) on conflict do nothing;
  select * into b from barns where user_id = u for update;
  if b.card_id is not null then raise exception 'Restaurez d''abord la voiture en cours.'; end if;
  if b.last_search = (now() at time zone 'Europe/Paris')::date and (not _is_pro(u) or b.searches >= 2) then
    raise exception '%', case when _is_pro(u) then 'Deux granges par jour : revenez demain !' else 'Une grange par jour : revenez demain ! (deux avec Paddock Pro)' end; end if;
  r := case when x < 50 then 'R' when x < 85 then 'SR' when x < 98 then 'UR' else 'L' end;
  select id into c from cards where rarity = r and coalesce(y1, 2000) < 1995 order by random() limit 1;
  if c is null then select id into c from cards where rarity = r order by random() limit 1; end if;
  update barns set card_id = c, step = 0, next_at = now(),
    searches = case when last_search = (now() at time zone 'Europe/Paris')::date then searches + 1 else 1 end,
    last_search = (now() at time zone 'Europe/Paris')::date where user_id = u;
  return _barn_json(u);
end $$;
create or replace function public.barn_work() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); b barns; cost int; c int; isnew boolean;
begin
  select * into b from barns where user_id = u for update;
  if b.card_id is null then raise exception 'Aucune voiture à restaurer.'; end if;
  if b.next_at > now() then raise exception 'L''atelier travaille encore sur la voiture. Revenez plus tard !'; end if;
  cost := _barn_cost(b.step);
  update wallets set coins = coins - cost where user_id = u and coins >= cost returning coins into c;
  if c is null then raise exception 'Il vous faut % pistons pour cette étape.', cost; end if;
  if b.step >= 2 then
    isnew := _give(u, b.card_id, true);
    update barns set card_id = null, step = 0, next_at = null, restored = restored + 1 where user_id = u;
    perform _notify(u, 'Restauration terminée : ' || (select name from cards where id = b.card_id) || ' brille comme neuve !');
    return _barn_json(u) || jsonb_build_object('done', b.card_id, 'new', isnew);
  end if;
  update barns set step = step + 1, next_at = now() + case when _is_pro(u) then interval '6 hours' else interval '12 hours' end where user_id = u;
  return _barn_json(u);
end $$;

-- ---------- Droits ------------------------------------------------------------------------
revoke all on function public._decor_price(text), public._barn_cost(int), public._barn_json(uuid) from public, anon, authenticated;
revoke all on function public.buy_decor(text), public.set_decor(text), public.barn_search(), public.barn_work() from public, anon;
grant execute on function public.buy_decor(text), public.set_decor(text), public.barn_search(), public.barn_work() to authenticated;

-- =====================================================================
--  PADDOCK — pack Paddock Pro plus généreux :
--    • 1re carte : ultra rare ou légendaire garantie (20 % de légendaire)
--    • 9 autres cartes : 3,5 % de légendaire (1 % dans un paquet normal)
--  Peut être relancé sans risque.
-- =====================================================================
create or replace function public._draw(pro boolean) returns int language plpgsql volatile security definer set search_path = public as $$
declare x float := random() * 100; r text; cid int;
begin
  if pro then
    r := case when x < 38 then 'C' when x < 63 then 'PC' when x < 80 then 'R' when x < 91 then 'SR' when x < 96.5 then 'UR' else 'L' end;
  else
    r := case when x < 50 then 'C' when x < 75 then 'PC' when x < 88 then 'R' when x < 95 then 'SR' when x < 99 then 'UR' else 'L' end;
  end if;
  select id into cid from cards where rarity = r order by random() limit 1;
  if cid is null then select id into cid from cards where rarity <> 'ED' order by random() limit 1; end if;
  return cid;
end $$;
create or replace function public._draw_pro_top() returns int language plpgsql volatile security definer set search_path = public as $$
declare r text := case when random() < 0.2 then 'L' else 'UR' end; cid int;
begin
  select id into cid from cards where rarity = r order by random() limit 1;
  return cid;
end $$;
revoke all on function public._draw(boolean), public._draw_pro_top() from public, anon, authenticated;

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
    if w.pro_pack_ts is not null and w.pro_pack_ts > now() - interval '24 hours' then raise exception 'Votre prochain pack Paddock Pro n''est pas encore prêt.'; end if;
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
  for i in 1..n loop ids := ids || _draw(kind = 'pro'); end loop;
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

-- ---------- Correction : paquet communautaire (ultra rare ou légendaire garantie) ----------
create or replace function public.claim_community(wk text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); me community_contrib; ids int[] := '{}'; c int; i int; res jsonb := '[]'::jsonb; isnew boolean;
begin
  if wk not in (_week_id(), _week_prev()) then raise exception 'Cette récompense n''est plus disponible.'; end if;
  if not exists (select 1 from community where week = wk and done_at is not null) then raise exception 'L''objectif commun n''est pas encore atteint.'; end if;
  select * into me from community_contrib where week = wk and user_id = u for update;
  if me.user_id is null then raise exception 'Ouvrez au moins un paquet cette semaine pour participer.'; end if;
  if me.claimed then raise exception 'Vous avez déjà récupéré ce paquet.'; end if;
  update community_contrib set claimed = true where week = wk and user_id = u;
  c := _draw_pro_top();   -- 20 % de légendaire, comme annoncé (l'ancien tirage n'en donnait qu'environ 11 %)
  ids := ids || c;
  for i in 1..4 loop ids := ids || _draw(false); end loop;
  foreach c in array ids loop
    isnew := _give(u, c, false);
    res := res || jsonb_build_array(jsonb_build_object('id', c, 'holo', false, 'new', isnew));
  end loop;
  return res;
end $$;

-- ---------- Paddock Pro : 15 ventes en même temps au marché ----------
create or replace function public.create_listing(card int, price int, minutes int) returns void language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); inv inventory; use_holo boolean;
begin
  if minutes not in (5, 60, 360, 720) then raise exception 'Durée invalide.'; end if;
  if price < 5 or price > 1000000 then raise exception 'Prix invalide.'; end if;
  if (select count(*) from listings where seller_id = u and status = 'open') >= (case when _is_pro(u) then 15 else 10 end) then
    raise exception 'Vous avez déjà % ventes en cours.', (case when _is_pro(u) then 15 else 10 end); end if;   -- Paddock Pro : 15
  select * into inv from inventory where user_id = u and card_id = card for update;
  if inv.n is null then raise exception 'Vous ne possédez pas cette carte.'; end if;
  use_holo := inv.holo >= inv.n;
  perform _take(u, card);
  insert into listings(seller_id, card_id, holo, start_price, ends_at) values (u, card, use_holo, price, now() + make_interval(mins => minutes));
end $$;

-- ---------- Paddock Pro : réactions exclusives 💎 et 🏆 sur les vitrines ----------
alter table public.show_reacts drop constraint if exists show_reacts_emoji_check;
do $$ begin
  alter table public.show_reacts add constraint show_reacts_emoji_ok check (emoji in ('🔥', '😍', '🤯', '👏', '💎', '🏆'));
exception when duplicate_object then null; end $$;
create or replace function public.react_show(name text, e text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); t uuid := _uid_by_name(name);
begin
  if t is null then raise exception 'Joueur introuvable.'; end if;
  if t = u then raise exception 'Vous ne pouvez pas réagir à votre propre vitrine.'; end if;
  if _blocked(u, t) then raise exception 'Action impossible.'; end if;
  if e in ('💎', '🏆') and not _is_pro(u) then raise exception 'Cette réaction est réservée aux membres Paddock Pro.'; end if;
  if coalesce(e, '') = '' then delete from show_reacts where target = t and user_id = u;
  else
    insert into show_reacts(target, user_id, emoji) values (t, u, e)
    on conflict (target, user_id) do update set emoji = excluded.emoji, created_at = now();
  end if;
  return _reacts(t);
end $$;

-- Séries (générées par wk/series.py)
insert into public.series(k, name, emoji, packs, ids) values
('groupeb', 'Groupe B', '🏁', 7, '{2,42,117,263,265,3229,4211,193,287}'),
('jdm', 'Légendes JDM', '🇯🇵', 6, '{415,430,443,453,3546,3189,3182,446}'),
('gt-r', 'Godzilla', '🦖', 7, '{3506,429,3180,430,3505,431,3507}'),
('911', 'Les 911 de légende', '🐸', 7, '{185,186,3694,3696,187,3701,3704,3711,3715}'),
('gti', 'Petites bombes', '🔥', 4, '{3207,3,96,3194,3770,3197,3211,3335}'),
('golf', 'La saga Golf', '⛳', 5, '{95,1327,3279,97,1685,3287,3291,2212}'),
('bmw-m', 'BMW M3 de génération en génération', 'Ⓜ️', 6, '{139,3192,140,3193,2315,3362,3366}'),
('amg', 'Black Series', '🖤', 5, '{3666,3669,3671,3675,176,178}'),
('ferrari', 'Le Cheval cabré', '🐎', 7, '{281,284,286,288,289,292,295,296}'),
('lambo', 'Taureaux furieux', '🐂', 6, '{303,305,307,308,309,310,311,314}'),
('bugatti', 'Bugatti, de Molsheim à 400 km/h', '🔵', 7, '{325,326,327,328,329,330,331}'),
('hyper', 'Hypercars', '⚡', 6, '{335,334,538,344,536,535,4130,320}'),
('lemans', 'Vainqueurs du Mans', '🏆', 8, '{218,3503,3723,3532,3643,3724,3502,4035}'),
('f1', 'Monoplaces mythiques', '🏎️', 8, '{3687,3686,4108,3469,3767,4094,4037}'),
('muscle', 'Muscle cars', '💪', 5, '{217,3957,505,3915,3972,3984,3975}'),
('mustang', '60 ans de Mustang', '🐴', 5, '{217,3916,2591,3917,3919,3920,3922,3923}'),
('citroen', 'Le génie Citroën', '🇫🇷', 9, '{64,65,67,66,69,72,73}'),
('alpine', 'Bleu Alpine', '🔷', 6, '{31,4170,4171,1244,2266,32,33}'),
('populaires', 'Les populaires', '🚗', 8, '{0,65,91,239,155,40,1}'),
('records', 'Records du monde', '🏆', 8, '{303,193,288,335,329,1667,4127,333,4130}'),
('electrique', 'Branchées', '🔌', 7, '{483,484,486,488,4147,490,3740,406}')
on conflict (k) do update set name = excluded.name, emoji = excluded.emoji, packs = excluded.packs, ids = excluded.ids;
delete from public.series where k not in ('groupeb', 'jdm', 'gt-r', '911', 'gti', 'golf', 'bmw-m', 'amg', 'ferrari', 'lambo', 'bugatti', 'hyper', 'lemans', 'f1', 'muscle', 'mustang', 'citroen', 'alpine', 'populaires', 'records', 'electrique');
-- Combinaisons secrètes
insert into public.combos(k, name, coins, ids) values
('agent', 'Agent secret', 120, '{339,367,148,408}'),
('rue', 'Pilote de rue', 150, '{415,430,453,505,3551,444}'),
('miami', 'Années 80 à Miami', 100, '{286,284,285}'),
('temps', 'Voyageur du temps', 80, '{383,92}'),
('gendarme', 'Gendarme de Saint-Tropez', 60, '{69,65}'),
('braquage', 'Braquage à l''italienne', 100, '{155,239,303}'),
('poster', 'Poster de chambre', 150, '{305,288,193,286}'),
('poursuite', 'Course-poursuite', 80, '{217,505}')
on conflict (k) do update set name = excluded.name, coins = excluded.coins, ids = excluded.ids;

-- =====================================================================
--  PADDOCK — état des nouveautés et profil (toujours à coller en DERNIER) :
--  get_extras() regroupe tout ce que le jeu charge à chaque synchronisation,
--  _profile_json() tout ce qu'on voit sur un profil.
-- =====================================================================

-- ---------- État des nouveautés (une seule requête à chaque synchronisation) ----
create or replace function public.get_extras() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); y int := extract(year from now() at time zone 'Europe/Paris')::int; lo loyalty;
begin
  perform _season_settle(); perform _cotm_settle(); perform _combo_scan(u);
  lo := _loyalty_tick(u);
  return jsonb_build_object(
    'loyalty', jsonb_build_object('days', lo.days, 'opened', lo.opened), 'mystery', _mystery_json(),
    'barn', _barn_json(u),
    'combos', (select coalesce(jsonb_agg(k order by created_at), '[]'::jsonb) from combo_claims where user_id = u),
    'cotm', _cotm_json(u), 'hunt', _hunt_json(u),
    'signed', (select coalesce(jsonb_agg(jsonb_build_array(card_id, signed)), '[]'::jsonb) from inventory where user_id = u and signed > 0),
    'me', (select jsonb_build_object('livery', livery, 'prestige', prestige, 'title', title, 'plate', plate, 'plate_at', plate_at, 'seeking', to_jsonb(seeking), 'titles', to_jsonb(_titles(u)), 'value', _coll_value(u), 'reacts', _reacts(u), 'decor', decor, 'decors', (select coalesce(jsonb_agg(k), '[]'::jsonb) from decor_owned where user_id = u)) from profiles where id = u),
    'series', (select to_jsonb(series_claimed) from wallets where user_id = u),
    'seasons', (select coalesce(jsonb_agg(jsonb_build_object('s', season, 'r', rank) order by season desc), '[]'::jsonb) from season_results where user_id = u and rank <= 10),
    'advent', jsonb_build_object('today', _adv_today(),
      'days', (select coalesce(jsonb_agg(day order by day), '[]'::jsonb) from advent where user_id = u and yr = y)));
end $$;

-- ---------- Profil : badges des séries, des saisons et de l'Avent ----------------
create or replace function public._profile_json(f uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p profiles; w int; st jsonb;
begin
  select * into p from profiles where id = f;
  select stats into st from wallets where user_id = f;
  select coalesce(sum((winner = case when p1 = f then 1 else 2 end)::int), 0) into w from live_battles where status = 'done' and (p1 = f or p2 = f);
  return jsonb_build_object(
    'since', p.created_at, 'unique', p.unique_count, 'seen', p.last_seen,
    'friends', (select count(*) from friendships fr join profiles fp on fp.id = fr.friend_id where fr.user_id = f and not fp.banned),
    'legend', (select count(*) from inventory i join cards c on c.id = i.card_id where i.user_id = f and c.rarity = 'L'),
    'ur', (select count(*) from inventory i join cards c on c.id = i.card_id where i.user_id = f and c.rarity = 'UR'),
    'sr', (select count(*) from inventory i join cards c on c.id = i.card_id where i.user_id = f and c.rarity = 'SR'),
    'ed', (select count(*) from inventory i join cards c on c.id = i.card_id where i.user_id = f and c.rarity = 'ED'),
    'holo', (select coalesce(sum(holo), 0) from inventory where user_id = f),
    'wins', coalesce((st->>'wins')::int, 0), 'battles', coalesce((st->>'battles')::int, 0), 'trades', coalesce((st->>'trades')::int, 0),
    'live_wins', w, 'xp', p.xp, 'lv', _lvl(p.xp), 'cur', _lvl_xp(_lvl(p.xp)), 'next', _lvl_xp(_lvl(p.xp) + 1),
    'guild', (select name from guilds where id = p.guild_id),
    'brands', (select coalesce(array_length(brands_claimed, 1), 0) from wallets where user_id = f),
    'series', (select to_jsonb(series_claimed) from wallets where user_id = f),
    'seasons', (select coalesce(jsonb_agg(jsonb_build_object('s', season, 'r', rank) order by season desc), '[]'::jsonb) from season_results where user_id = f and rank <= 10),
    'advent', (select count(*) from advent where user_id = f and yr = extract(year from now() at time zone 'Europe/Paris')::int - case when extract(month from now() at time zone 'Europe/Paris') = 1 then 1 else 0 end),
    'hunts', (select coalesce(jsonb_agg(season order by season desc), '[]'::jsonb) from (select season from hunt where user_id = f group by season having count(*) >= 30) h),
    'livery', p.livery, 'prestige', p.prestige, 'title', p.title, 'plate', p.plate, 'seeking', to_jsonb(p.seeking), 'value', _coll_value(f),
    'decor', p.decor, 'reacts', _reacts(f), 'combos', (select coalesce(jsonb_agg(k order by created_at), '[]'::jsonb) from combo_claims where user_id = f),
    'show', (select coalesce(jsonb_agg(x), '[]'::jsonb) from unnest(p.showcase) x where x is not null and exists (select 1 from inventory where user_id = f and card_id = x)),
    'banner', case when _is_pro(f) then p.banner_img end,
    'avatar', case when _is_pro(f) then p.avatar_img end);
end $$;

revoke all on function public._profile_json(uuid) from public, anon, authenticated;
revoke all on function public.get_extras() from public, anon;
grant execute on function public.get_extras() to authenticated;

