-- Paddock : récompenses des nouveaux succès rééquilibrées
begin;
update public.ach2_defs set reward = 20 where k = 'p100';
update public.ach2_defs set reward = 50 where k = 'p500';
update public.ach2_defs set reward = 100 where k = 'p1000';
update public.ach2_defs set reward = 80 where k = 'u500';
update public.ach2_defs set reward = 120 where k = 'u1000';
update public.ach2_defs set reward = 200 where k = 'u2000';
update public.ach2_defs set reward = 25 where k = 'l5';
update public.ach2_defs set reward = 80 where k = 'l25';
update public.ach2_defs set reward = 40 where k = 'w50';
update public.ach2_defs set reward = 15 where k = 't10';
update public.ach2_defs set reward = 15 where k = 's10';
update public.ach2_defs set reward = 15 where k = 'a10';
update public.ach2_defs set reward = 25 where k = 'ser3';
update public.ach2_defs set reward = 60 where k = 'ser10';
update public.ach2_defs set reward = 15 where k = 'h5';
update public.ach2_defs set reward = 10 where k = 'f10';
update public.ach2_defs set reward = 15 where k = 'fus10';
update public.ach2_defs set reward = 30 where k = 'num1';
update public.ach2_defs set reward = 25 where k = 'duel5';
update public.ach2_defs set reward = 25 where k = 'wheel30';
update public.ach2_defs set reward = 15 where k = 'gift10';
update public.ach2_defs set reward = 20 where k = 'b25';
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
    if rc > 0 then update wallets set coins = coins + 10 where user_id = u; perform _notify(u, 'Succès caché débloqué ! +10 pistons.'); end if;
  end loop;
  return coalesce((select jsonb_object_agg(s2.k, s2.at) from secrets2 s2 where s2.user_id = u), '{}'::jsonb);
end $$;

commit;
select k, reward from public.ach2_defs order by reward desc;
