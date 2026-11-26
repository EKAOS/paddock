-- Acheter une carte qui manque : 2 500 pistons la carte, quelle que soit la rareté.
create or replace function public.buy_card_price() returns int language sql immutable as $$ select 2500 $$;

create or replace function public.buy_card(id int) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); w wallets; isnew boolean;
begin
  if u is null then raise exception 'Connectez-vous pour acheter une carte.'; end if;
  if not exists (select 1 from cards c where c.id = buy_card.id) then raise exception 'Carte inconnue.'; end if;
  if exists (select 1 from inventory i where i.user_id = u and i.card_id = buy_card.id and i.n > 0) then raise exception 'Vous avez déjà cette carte.'; end if;
  select * into w from wallets where user_id = u for update;
  if w.coins < 2500 then raise exception 'Il vous faut 2 500 pistons.'; end if;
  update wallets set coins = coins - 2500 where user_id = u returning * into w;
  isnew := _give(u, buy_card.id, false);
  return jsonb_build_object('coins', w.coins, 'new', isnew);
end $$;

revoke all on function public.buy_card(int), public.buy_card_price() from public, anon;
grant execute on function public.buy_card(int), public.buy_card_price() to authenticated;
