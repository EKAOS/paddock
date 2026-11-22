-- Paddock : nouveaux succès du Palmarès, 12 nouvelles collections et 18 succès cachés.
-- À lancer APRÈS vague2.sql. Peut être relancé sans risque.
begin;

-- ===== 12 nouvelles collections =====
insert into public.series(k, name, emoji, packs, ids) values
  ('rallye', 'Rois du rallye', '🌲', 7, array[116, 262, 264, 417, 463, 3188, 224, 3260]),
  ('cine', 'Stars de cinéma', '🎬', 5, array[339, 383, 502, 156, 513]),
  ('fr80', 'Années 80 à la française', '🥖', 5, array[41, 63, 75, 74, 574, 2991, 3250, 1261]),
  ('kei', 'Kei cars', '🍡', 5, array[467, 469, 470, 2632, 3457, 3474, 3540]),
  ('vwold', 'Volkswagen d''antan', '🚐', 4, array[92, 93, 102, 103, 105]),
  ('papaya', 'Papaya McLaren', '🧡', 7, array[336, 337, 338, 1884, 2132, 2136, 4088]),
  ('transaxle', 'Porsche à moteur avant', '⚙️', 5, array[190, 191, 192, 1432, 3731, 3732]),
  ('posters', 'Posters de chambre', '🖼️', 7, array[286, 288, 305, 193, 352, 328]),
  ('hothatch', 'Hot hatch modernes', '🌶️', 7, array[11, 99, 226, 421, 474, 3210, 2988]),
  ('minisaga', 'La saga Mini', '🇬🇧', 6, array[156, 157, 158, 258, 3891, 2795]),
  ('typer', 'Type R de génération en génération', '🔴', 6, array[445, 3162, 3163, 3164, 3165, 3166, 3167]),
  ('evo', 'Lancer Evolution, de I à X', '🐉', 7, array[3543, 3544, 3545, 458, 3547, 3548, 1615, 459])
on conflict (k) do update set name = excluded.name, emoji = excluded.emoji, packs = excluded.packs, ids = excluded.ids;

-- ===== compteurs d'un joueur (pour les succès) =====
create or replace function public._ach2_metrics(u uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare w wallets; r jsonb;
begin
  select * into w from wallets where user_id = u;
  select jsonb_build_object(
    'packs', coalesce((w.stats->>'packs')::int, 0), 'wins', coalesce((w.stats->>'wins')::int, 0),
    'trades', coalesce((w.stats->>'trades')::int, 0), 'sales', coalesce((w.stats->>'sales')::int, 0),
    'auctions', coalesce((w.stats->>'auctions')::int, 0), 'fus', coalesce((w.stats->>'fus')::int, 0),
    'uniq', (select count(*) from inventory where user_id = u and n > 0),
    'leg', (select count(*) from inventory i join cards c on c.id = i.card_id where i.user_id = u and i.n > 0 and c.rarity = 'L'),
    'holo', (select count(*) from inventory where user_id = u and n > 0 and holo > 0),
    'brands', (select count(distinct c.brand) from inventory i join cards c on c.id = i.card_id where i.user_id = u and i.n > 0),
    'ser', coalesce(cardinality(w.series_claimed), 0),
    'friends', (select count(*) from friendships where user_id = u),
    'numb', (select count(*) from numbered where user_id = u),
    'duelw', (select count(*) from pack_duels where winner = u),
    'wheel', coalesce((select wheel_n from bonus where user_id = u), 0),
    'gifts', (select count(*) from gifts where user_id = u)) into r;
  return r;
end $$;

-- ===== nouveaux succès du Palmarès =====
create table if not exists public.ach2_defs (k text primary key, metric text not null, goal int not null, reward int not null);
insert into public.ach2_defs values
  ('p100', 'packs', 100, 60),
  ('p500', 'packs', 500, 200),
  ('p1000', 'packs', 1000, 400),
  ('u500', 'uniq', 500, 250),
  ('u1000', 'uniq', 1000, 500),
  ('u2000', 'uniq', 2000, 1000),
  ('l5', 'leg', 5, 100),
  ('l25', 'leg', 25, 400),
  ('w50', 'wins', 50, 150),
  ('t10', 'trades', 10, 60),
  ('s10', 'sales', 10, 50),
  ('a10', 'auctions', 10, 60),
  ('ser3', 'ser', 3, 100),
  ('ser10', 'ser', 10, 300),
  ('h5', 'holo', 5, 60),
  ('f10', 'friends', 10, 40),
  ('fus10', 'fus', 10, 60),
  ('num1', 'numb', 1, 100),
  ('duel5', 'duelw', 5, 100),
  ('wheel30', 'wheel', 30, 100),
  ('gift10', 'gifts', 10, 60),
  ('b25', 'brands', 25, 80)
on conflict (k) do update set metric = excluded.metric, goal = excluded.goal, reward = excluded.reward;
create table if not exists public.ach2 (
  user_id uuid not null references public.profiles(id) on delete cascade,
  k text not null, at timestamptz not null default now(),
  primary key (user_id, k)
);
alter table public.ach2_defs enable row level security;
alter table public.ach2 enable row level security;

create or replace function public.get_ach2() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('m', _ach2_metrics(_uid()), 'got', coalesce((select jsonb_agg(k) from ach2 where user_id = _uid()), '[]'::jsonb))
$$;

create or replace function public.claim_ach2(ak text) returns int language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); d ach2_defs; v int;
begin
  select * into d from ach2_defs where k = ak;
  if d.k is null then raise exception 'Succès inconnu.'; end if;
  v := coalesce((_ach2_metrics(u)->>d.metric)::int, 0);
  if v < d.goal then raise exception 'Succès pas encore atteint.'; end if;
  insert into ach2(user_id, k) values (u, ak) on conflict do nothing;
  if not found then raise exception 'Récompense déjà récupérée.'; end if;
  update wallets set coins = coins + d.reward where user_id = u;
  return d.reward;
end $$;

-- ===== succès cachés =====
create table if not exists public.secrets2 (
  user_id uuid not null references public.profiles(id) on delete cascade,
  k text not null, at timestamptz not null default now(),
  primary key (user_id, k)
);
alter table public.secrets2 enable row level security;

create or replace function public.get_secrets2() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); t timestamp := now() at time zone 'Europe/Paris'; m int := extract(month from t); d int := extract(day from t);
        ok text[] := '{}'; sk text; rc int;
begin
  if u is null then return '{}'::jsonb; end if;
  if exists (select 1 from inventory i join cards c on c.id = i.card_id where i.user_id = u and i.n > 0 and c.name ilike 'Peugeot 404%') then ok := ok || text 'erreur404'; end if;
  if (select coins from wallets where user_id = u) = 1000 then ok := ok || text 'pile'; end if;
  if m = 1 and d = 1 then ok := ok || text 'nouvelan'; end if;
  if m = 2 and d = 14 then ok := ok || text 'valentin'; end if;
  if m = 4 and d = 1 then ok := ok || text 'poisson'; end if;
  if m = 12 and d = 25 then ok := ok || text 'noel'; end if;
  if extract(hour from t) = 0 and extract(minute from t) < 5 then ok := ok || text 'minuit2'; end if;
  if (select count(distinct c.brand) from inventory i join cards c on c.id = i.card_id where i.user_id = u and i.n > 0) >= 50 then ok := ok || text 'marques50'; end if;
  if exists (select 1 from inventory i join cards c on c.id = i.card_id where i.user_id = u and i.n > 0 group by c.brand having count(*) >= 20) then ok := ok || text 'fan'; end if;
  if (select coalesce(sum(greatest(n - 1, 0)), 0) from inventory where user_id = u) >= 100 then ok := ok || text 'doublons'; end if;
  if (select count(*) from inventory i join cards c on c.id = i.card_id where i.user_id = u and i.n > 0 and c.rarity = 'L') >= 7 then ok := ok || text 'sept'; end if;
  if exists (select 1 from numbered where user_id = u and serial = 1) then ok := ok || text 'numero1'; end if;
  if exists (select 1 from inventory i join cards c on c.id = i.card_id where i.user_id = u and i.n > 0 and c.y1 < 1900)
     and exists (select 1 from inventory i join cards c on c.id = i.card_id where i.user_id = u and i.n > 0 and c.y1 >= 2025) then ok := ok || text 'temps'; end if;
  if (select count(*) from inventory i join cards c on c.id = i.card_id where i.user_id = u and i.n > 0 and c.brand = 'Ferrari') >= 10 then ok := ok || text 'rouge'; end if;
  if (select count(*) from gifts where user_id = u) >= 10 then ok := ok || text 'genereux'; end if;
  if exists (select 1 from pack_duels where (a = u and a_score >= 200) or (b = u and b_score >= 200)) then ok := ok || text 'duel200'; end if;
  if exists (select 1 from inventory i join cards c on c.id = i.card_id where i.user_id = u and i.n > 0 and c.hp = (select min(hp) from cards where rarity <> 'ED' and hp > 0)) then ok := ok || text 'escargot'; end if;
  if exists (select 1 from inventory i join cards c on c.id = i.card_id where i.user_id = u and i.n > 0 and c.vmax = (select max(vmax) from cards where rarity <> 'ED')) then ok := ok || text 'fusee'; end if;
  foreach sk in array ok loop
    insert into secrets2(user_id, k) values (u, sk) on conflict do nothing;
    get diagnostics rc = row_count;
    if rc > 0 then update wallets set coins = coins + 25 where user_id = u; perform _notify(u, 'Succès caché débloqué ! +25 pistons.'); end if;
  end loop;
  return coalesce((select jsonb_object_agg(s2.k, s2.at) from secrets2 s2 where s2.user_id = u), '{}'::jsonb);
end $$;

revoke all on function public._ach2_metrics(uuid) from public, anon, authenticated;
revoke all on function public.get_ach2() from public, anon;
revoke all on function public.claim_ach2(text) from public, anon;
revoke all on function public.get_secrets2() from public, anon;
grant execute on function public.get_ach2() to authenticated;
grant execute on function public.claim_ach2(text) to authenticated;
grant execute on function public.get_secrets2() to authenticated;

commit;

select 'palmarès installé' as resultat, (select count(*) from series) as collections, (select count(*) from ach2_defs) as succes;
