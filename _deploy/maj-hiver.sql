-- Paddock : mise à jour d'hiver + objectif commun plus exigeant. À coller dans Supabase > SQL Editor > Run.
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
    isnew := _give(u, c, false);
    return jsonb_build_object('day', d, 'card', c, 'new', isnew);
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
    perform _notify(rec.p, 'Fin de saison : vous terminez ' || case when k = 1 then '1er' else k || 'e' end || ' du classement ! ' || _season_prize(k) || ' paquets offerts.');
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

-- ---------- État des nouveautés (une seule requête à chaque synchronisation) ----
create or replace function public.get_extras() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); y int := extract(year from now() at time zone 'Europe/Paris')::int;
begin
  perform _season_settle();
  return jsonb_build_object(
    'series', (select to_jsonb(series_claimed) from wallets where user_id = u),
    'seasons', (select coalesce(jsonb_agg(jsonb_build_object('s', season, 'r', rank) order by season desc), '[]'::jsonb) from season_results where user_id = u and rank <= 10),
    'advent', jsonb_build_object('today', _adv_today(),
      'days', (select coalesce(jsonb_agg(day order by day), '[]'::jsonb) from advent where user_id = u and yr = y)));
end $$;

-- ---------- Vitrine : 6 voitures ---------------------------------------------
do $$ begin
  alter table public.profiles add constraint showcase_max6 check (coalesce(array_length(showcase, 1), 0) <= 6) not valid;
exception when duplicate_object then null; end $$;

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
    'show', (select coalesce(jsonb_agg(x), '[]'::jsonb) from unnest(p.showcase) x where x is not null and exists (select 1 from inventory where user_id = f and card_id = x)),
    'banner', case when _is_pro(f) then p.banner_img end,
    'avatar', case when _is_pro(f) then p.avatar_img end);
end $$;

-- ---------- Droits ------------------------------------------------------------
revoke all on function public._adv(int), public._adv_today(), public._season_scores(text), public._season_settle(), public._profile_json(uuid) from public, anon, authenticated;
revoke all on function public.claim_series(text), public.upgrade_dup(int), public.claim_advent(), public.get_season(), public.get_extras() from public, anon;
grant execute on function public.claim_series(text), public.upgrade_dup(int), public.claim_advent(), public.get_season(), public.get_extras() to authenticated;

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
('electrique', 'Branchées', '🔌', 7, '{483,484,486,488,4147,490,3740,406}')
on conflict (k) do update set name = excluded.name, emoji = excluded.emoji, packs = excluded.packs, ids = excluded.ids;
delete from public.series where k not in ('groupeb', 'jdm', 'gt-r', '911', 'gti', 'golf', 'bmw-m', 'amg', 'ferrari', 'lambo', 'bugatti', 'hyper', 'lemans', 'f1', 'muscle', 'mustang', 'citroen', 'alpine', 'populaires', 'electrique');
