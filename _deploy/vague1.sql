-- Paddock, vague 1 : roue du garage + livraison surprise. Peut être relancé sans risque.
begin;

create table if not exists public.bonus (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  wheel_last date,
  wheel_n int not null default 0,
  surprise_last date,
  surprise_n int not null default 0
);
alter table public.bonus enable row level security;

-- heure de la livraison surprise du jour : entre 10 h et 21 h (heure de Paris), différente pour chaque joueur
create or replace function public._surprise_at(u uuid, d date) returns timestamptz language sql immutable as $$
  select ((d + time '10:00') + make_interval(mins => abs(hashtext(u::text || d::text)) % 660)) at time zone 'Europe/Paris'
$$;

create or replace function public.get_bonus() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u uuid := _uid(); t date := (now() at time zone 'Europe/Paris')::date; b bonus;
begin
  select * into b from bonus where user_id = u;
  return jsonb_build_object('wheel', b.wheel_last is not distinct from t, 'spins', coalesce(b.wheel_n, 0),
    'sat', _surprise_at(u, t), 'sgot', b.surprise_last is not distinct from t, 'snext', _surprise_at(u, t + 1));
end $$;

-- roue du garage : un tour par jour
create or replace function public.spin_wheel() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); t date := (now() at time zone 'Europe/Paris')::date; b bonus; x float := random() * 100;
        seg int; co int := 0; pk int := 0; c int; isnew boolean := false;
begin
  insert into bonus(user_id) values (u) on conflict do nothing;
  select * into b from bonus where user_id = u for update;
  if b.wheel_last is not distinct from t then raise exception 'Vous avez déjà tourné la roue aujourd''hui. Revenez demain !'; end if;
  seg := case when x < 25 then 0 when x < 45 then 1 when x < 63 then 2 when x < 75 then 3 when x < 85 then 4 when x < 93 then 5 when x < 98 then 6 else 7 end;
  case seg when 0 then co := 25; when 1 then co := 50; when 2 then pk := 1; when 3 then co := 100;
           when 4 then pk := 2; when 6 then co := 250; else null; end case;
  if seg in (5, 7) then
    select id into c from cards where rarity = case when seg = 5 then 'SR' else 'UR' end order by random() limit 1;
    isnew := _give(u, c, false);
  end if;
  update wallets set coins = coins + co, packs = packs + pk where user_id = u;
  update bonus set wheel_last = t, wheel_n = wheel_n + 1 where user_id = u;
  return jsonb_build_object('seg', seg, 'coins', co, 'packs', pk, 'card', c, 'new', isnew);
end $$;

-- livraison surprise : 2 paquets + 50 pistons, à récupérer dans l'heure
create or replace function public.claim_surprise() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); t date := (now() at time zone 'Europe/Paris')::date; b bonus; a timestamptz := _surprise_at(_uid(), (now() at time zone 'Europe/Paris')::date);
begin
  insert into bonus(user_id) values (u) on conflict do nothing;
  select * into b from bonus where user_id = u for update;
  if b.surprise_last is not distinct from t then raise exception 'Vous avez déjà récupéré la livraison du jour.'; end if;
  if now() < a then raise exception 'La livraison n''est pas encore arrivée.'; end if;
  if now() > a + interval '1 hour' then raise exception 'Trop tard : le livreur est reparti. Prochaine livraison demain !'; end if;
  update wallets set packs = packs + 2, coins = coins + 50 where user_id = u;
  update bonus set surprise_last = t, surprise_n = surprise_n + 1 where user_id = u;
  return jsonb_build_object('packs', 2, 'coins', 50);
end $$;

revoke all on function public._surprise_at(uuid, date) from public, anon, authenticated;
revoke all on function public.get_bonus() from public, anon;
revoke all on function public.spin_wheel() from public, anon;
revoke all on function public.claim_surprise() from public, anon;
grant execute on function public.get_bonus() to authenticated;
grant execute on function public.spin_wheel() to authenticated;
grant execute on function public.claim_surprise() to authenticated;

commit;

select 'vague 1 installée' as resultat, (select count(*) from bonus) as joueurs;
