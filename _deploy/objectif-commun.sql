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
