-- =====================================================================
--  PADDOCK — compteur anonyme d'utilisation des écrans
--  Le jeu envoie, toutes les minutes, combien de fois chaque écran a été ouvert.
--  Aucun identifiant de joueur n'est enregistré : seulement (jour, écran, nombre).
--  Peut être relancé sans risque.
-- =====================================================================
create table if not exists public.usage_views (
  day date not null,
  view text not null,
  n int not null default 0,
  primary key (day, view)
);
alter table public.usage_views enable row level security;

create or replace function public.log_views(v jsonb) returns void language plpgsql security definer set search_path = public as $$
declare k text; c int; m int := 0;
begin
  if _uid() is null or jsonb_typeof(v) <> 'object' then return; end if;
  for k, c in select key, least(50, greatest(0, coalesce((value #>> '{}')::int, 0))) from jsonb_each(v) loop
    m := m + 1; exit when m > 40;
    if k !~ '^[a-z]{2,20}$' or c = 0 then continue; end if;
    insert into usage_views(day, view, n) values ((now() at time zone 'Europe/Paris')::date, k, c)
    on conflict (day, view) do update set n = usage_views.n + excluded.n;
  end loop;
end $$;

-- lecture réservée aux administrateurs : écrans les plus ouverts sur les N derniers jours
create or replace function public.get_usage(days int default 14) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from profiles where id = _uid() and is_admin) then raise exception 'Réservé aux administrateurs.'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('view', view, 'n', n) order by n desc), '[]'::jsonb)
          from (select view, sum(n)::int n from usage_views where day > (now() at time zone 'Europe/Paris')::date - least(90, greatest(1, days)) group by view) x);
end $$;

revoke all on function public.log_views(jsonb), public.get_usage(int) from public, anon;
grant execute on function public.log_views(jsonb), public.get_usage(int) to authenticated;
