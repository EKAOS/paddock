-- Paddock : objectif commun plus difficile (35 % de plus que la semaine précédente, 1 000 minimum)
create or replace function public._comm_target() returns int language sql stable security definer set search_path = public as $$
  select greatest(1000, (ceil(1.35 * coalesce((select packs from community where week = _week_prev()), 0) / 100.0) * 100)::int)
$$;
-- semaine en cours : nouvel objectif tout de suite (s'il n'est pas déjà atteint)
update public.community set target = public._comm_target() where week = public._week_id() and done_at is null;
select week, packs, target from public.community where week = public._week_id();
