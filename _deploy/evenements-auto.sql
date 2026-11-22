-- Paddock : événements automatiques chaque semaine (32 thèmes qui tournent tout seuls)
begin;

-- quelles voitures appartiennent à quel thème (10 et plus : nouveaux thèmes)
create or replace function public._ev_ok(t int, brand text, hp int, vmax int, y1 int, body text) returns boolean language sql immutable as $$
  select coalesce(case t
    when 10 then brand = any(array['Ferrari'])
    when 11 then brand = any(array['Porsche'])
    when 12 then brand = any(array['BMW'])
    when 13 then brand = any(array['Mercedes-Benz'])
    when 14 then brand = any(array['Lamborghini'])
    when 15 then body = 'r'
    when 16 then body in ('v','p')
    when 17 then body = 'c'
    when 18 then body = 'h'
    when 19 then y1 between 1950 and 1969
    when 20 then y1 between 1970 and 1989
    when 21 then y1 between 1990 and 2009
    when 22 then y1 >= 2015
    when 23 then vmax >= 300
    when 24 then brand = any(array['Volvo','Saab','Koenigsegg','Polestar'])
    when 25 then brand = any(array['Hyundai','Kia','Genesis','Daewoo','SsangYong'])
    when 26 then body = 'k'
    when 27 then body in ('b','m')
    when 28 then hp <= 80
    when 29 then brand = any(array['Audi'])
    when 30 then brand = any(array['Ford'])
    when 31 then brand = any(array['Volkswagen'])
    when 32 then body = 's'
  end, false)
$$;

-- thème de la semaine : l'ancien cycle jusqu'au 22 novembre 2026, puis le nouveau cycle de 32 semaines ; Noël du 1er décembre au 6 janvier
create or replace function public._ev_cycle_theme(w int) returns int language sql immutable as $$
  select case when w < 45 then ((w % 9) + 9) % 9
              else (array[10, 15, 20, 2, 23, 17, 12, 25, 6, 26, 1, 19, 28, 11, 16, 4, 22, 14, 27, 7, 21, 0, 13, 24, 18, 5, 29, 32, 3, 30, 8, 31])[(((w - 45) % 32) + 32) % 32 + 1] end
$$;
-- on garde les anciennes fonctions sous un autre nom (les 10 premiers thèmes ne changent pas)
do $$ declare r record; begin
  if not exists (select 1 from pg_proc where proname = '_draw_ev_v1' and pronamespace = 'public'::regnamespace) then
    for r in select oid::regprocedure s from pg_proc where proname = '_draw_ev' and pronamespace = 'public'::regnamespace loop
      execute format('alter function %s rename to _draw_ev_v1', r.s); end loop;
  end if;
  if not exists (select 1 from pg_proc where proname = '_ev_theme_v1' and pronamespace = 'public'::regnamespace) then
    for r in select oid::regprocedure s from pg_proc where proname = '_ev_theme' and pronamespace = 'public'::regnamespace loop
      execute format('alter function %s rename to _ev_theme_v1', r.s); end loop;
  end if;
end $$;

create or replace function public._ev_theme() returns int language plpgsql stable security definer set search_path = public as $$
declare v int := _ev_theme_v1(); w int;
begin
  if v = 9 then return 9; end if;                       -- Noël
  w := ((date_trunc('week', now() at time zone 'Europe/Paris'))::date - date '2026-01-12') / 7;
  if w < 45 then return v; end if;
  return _ev_cycle_theme(w);
end $$;

create or replace function public._draw_ev(t int, top boolean) returns int language plpgsql volatile security definer set search_path = public as $$
declare x float := random() * 100; r text; c int;
begin
  if t < 10 then return _draw_ev_v1(t, top); end if;
  r := case when top then case when x < 70 then 'SR' when x < 95 then 'UR' else 'L' end
            else case when x < 50 then 'C' when x < 75 then 'PC' when x < 88 then 'R' when x < 95 then 'SR' when x < 99 then 'UR' else 'L' end end;
  select id into c from cards where rarity = r and _ev_ok(t, brand, hp, vmax, y1, body) order by random() limit 1;
  if c is null and top then select id into c from cards where rarity in ('SR','UR','L') and _ev_ok(t, brand, hp, vmax, y1, body) order by random() limit 1; end if;
  if c is null then select id into c from cards where rarity <> 'ED' and _ev_ok(t, brand, hp, vmax, y1, body) order by random() limit 1; end if;
  if c is null then c := _draw(false); end if;
  return c;
end $$;

revoke all on function public._ev_theme() from public, anon, authenticated;
revoke all on function public._draw_ev(int, boolean) from public, anon, authenticated;
revoke all on function public._ev_ok(int, text, int, int, int, text) from public, anon, authenticated;
revoke all on function public._ev_cycle_theme(int) from public, anon, authenticated;

commit;

-- vérification : chaque nouveau thème doit avoir des voitures, et "affichage_ok" doit être vrai
select t as theme, count(*) as voitures, count(*) filter (where rarity in ('SR','UR','L')) as rares
  from generate_series(10, 32) t join cards on _ev_ok(t, brand, hp, vmax, y1, body) and rarity <> 'ED' group by t
union all
select -1, _ev_theme(), (position('_ev_theme' in pg_get_functiondef('public.get_event'::regproc)) > 0)::int
order by 1;
