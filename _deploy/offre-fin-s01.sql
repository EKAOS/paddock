-- Offre exceptionnelle de fin de Série 01 : 200 paquets pour 10 pistons, une fois par compte,
-- jusqu'à la sortie de la Série 02 (dimanche 30 novembre 2026, 21 h, heure de Paris = 20:00 UTC).
create table if not exists public.offer_claims (user_id uuid not null references auth.users(id) on delete cascade, k text not null, at timestamptz not null default now(), primary key (user_id, k));
alter table public.offer_claims enable row level security;

-- vrai = déjà profité (le jeu n'affiche plus l'offre)
create or replace function public.offer_s1_state() returns boolean language sql stable security definer set search_path = public as $$
  select now() >= '2026-11-30 20:00+00' or exists (select 1 from offer_claims where user_id = _uid() and k = 'fin_s1');
$$;

create or replace function public.claim_offer_s1() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); w wallets;
begin
  if u is null then raise exception 'Connectez-vous pour profiter de l''offre.'; end if;
  if now() >= '2026-11-30 20:00+00' then raise exception 'L''offre de fin de Série 01 est terminée.'; end if;
  select * into w from wallets where user_id = u for update;
  if w.coins < 10 then raise exception 'Il vous faut 10 pistons.'; end if;
  insert into offer_claims(user_id, k) values (u, 'fin_s1') on conflict do nothing;
  if not found then raise exception 'Vous avez déjà profité de cette offre.'; end if;
  update wallets set coins = coins - 10, packs = packs + 200 where user_id = u returning * into w;
  return jsonb_build_object('coins', w.coins, 'packs', w.packs);
end $$;

revoke all on function public.offer_s1_state(), public.claim_offer_s1() from public, anon;
grant execute on function public.offer_s1_state(), public.claim_offer_s1() to authenticated;
