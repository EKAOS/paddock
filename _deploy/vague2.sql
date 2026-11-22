-- Paddock, vague 2 : cartes numérotées, défis d'ouverture, cadeau à un ami, parrainage amélioré, code du jour.
-- À lancer APRÈS maj-novembre.sql. Peut être relancé sans risque.
begin;

alter table public.wallets add column if not exists pity int not null default 0;

-- ===== cartes numérotées =====
create table if not exists public.numbered (
  card_id int not null,
  serial int not null check (serial between 1 and 100),
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (card_id, serial)
);
alter table public.numbered enable row level security;
create index if not exists numbered_u on public.numbered(user_id);

create or replace function public.get_numbered() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_array(n.card_id, n.serial) order by n.serial), '[]'::jsonb) from numbered n
  where n.user_id = _uid() and exists (select 1 from inventory i where i.user_id = n.user_id and i.card_id = n.card_id and i.n > 0)
$$;
revoke all on function public.get_numbered() from public, anon;
grant execute on function public.get_numbered() to authenticated;

create or replace function public.open_pack(kind text default 'normal') returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); w wallets; pro boolean := _is_pro(u); n int; ids int[] := '{}'; t int := _ev_theme();
        c int; h boolean; i int; res jsonb := '[]'::jsonb; isnew boolean; got_holo boolean := false; num int;
begin
  perform _sync_packs(u);
  select * into w from wallets where user_id = u for update;
  if kind = 'normal' then
    if w.packs < 1 then raise exception 'Plus de paquet disponible. Le prochain arrive bientôt.'; end if;
    update wallets set packs = packs - 1, pack_ts = case when w.packs >= 10 then now() else pack_ts end, full_notified = false where user_id = u;
    n := 5;
  elsif kind = 'pro' then
    if not pro then raise exception 'Le pack Paddock Pro est réservé aux membres Paddock Pro.'; end if;
    -- recharge chaque jour à minuit (heure de Paris)
    if w.pro_pack_ts is not null and (w.pro_pack_ts at time zone 'Europe/Paris')::date >= (now() at time zone 'Europe/Paris')::date then raise exception 'Votre prochain pack Paddock Pro n''est pas encore prêt.'; end if;
    update wallets set pro_pack_ts = now(), pro_notified = false where user_id = u;
    n := 10;
  elsif kind = 'event' then
    if w.ev_pack_ts is not null and w.ev_pack_ts > now() - (case when pro then interval '12 hours' else interval '24 hours' end) then raise exception 'Votre prochain paquet d''événement n''est pas encore prêt.'; end if;   -- Paddock Pro : 2 par jour
    update wallets set ev_pack_ts = now() where user_id = u;
    if t = 0 then
      select id into c from cards where rarity = 'ED' order by random() limit 1;
      if c is not null then ids := ids || c; end if;
      n := 4;
    else
      ids := ids || _draw_ev(t, true);
      for i in 1..4 loop ids := ids || _draw_ev(t, false); end loop;
      n := 0;
    end if;
  else raise exception 'Type de paquet inconnu.'; end if;
  -- pack Paddock Pro : la 1re carte est une ultra rare ou une légendaire garantie (20 % de légendaire)
  if kind = 'pro' then ids := ids || _draw_pro_top(); n := n - 1; end if;
  -- Paddock Pro : paquets normaux un peu plus généreux
  for i in 1..n loop ids := ids || case when kind = 'pro' then _draw(true) when pro then _draw_vip() else _draw(false) end; end loop;
  -- légendaire garantie : au plus tard au 50e paquet normal sans légendaire
  if kind = 'normal' then
    if exists (select 1 from cards where id = any(ids) and rarity = 'L') then
      update wallets set pity = 0 where user_id = u;
    elsif coalesce(w.pity, 0) >= 49 then
      select id into c from cards where rarity = 'L' order by random() limit 1;
      if c is not null then ids[1] := c; end if;
      update wallets set pity = 0 where user_id = u;
    else
      update wallets set pity = coalesce(pity, 0) + 1 where user_id = u;
    end if;
  end if;
  foreach c in array ids loop
    h := random() < case when kind = 'pro' then 0.05 else 0.03 end;
    got_holo := got_holo or h;
    isnew := _give(u, c, h);
    -- carte numérotée : 1 chance sur 200, 100 exemplaires numérotés au maximum par voiture
    num := null;
    if random() < 0.005 then
      select coalesce(max(serial), 0) + 1 into num from numbered where card_id = c;
      if num <= 100 then insert into numbered(card_id, serial, user_id) values (c, num, u) on conflict do nothing;
        perform _notify(u, 'Incroyable : vous avez obtenu une carte numérotée N° ' || num || ' / 100 !');
      else num := null; end if;
    end if;
    res := res || jsonb_build_array(jsonb_build_object('id', c, 'holo', h, 'new', isnew) || case when num is null then '{}'::jsonb else jsonb_build_object('num', num) end);
  end loop;
  perform _stat_inc(u, 'packs'); perform _wk_inc(u, 'packs'); perform _comm_inc(u);
  if got_holo then perform _notify(u, 'Vous avez obtenu une carte brillante !'); end if;
  return res;
end $$;
revoke all on function public.open_pack(text) from public, anon;
grant execute on function public.open_pack(text) to authenticated;

-- ===== cadeau à un ami et défis d'ouverture =====
create table if not exists public.gifts (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  to_id uuid not null references public.profiles(id) on delete cascade,
  primary key (user_id, day)
);
alter table public.gifts enable row level security;

create table if not exists public.pack_duels (
  id bigserial primary key,
  a uuid not null references public.profiles(id) on delete cascade,
  b uuid not null references public.profiles(id) on delete cascade,
  a_cards int[], b_cards int[], a_score int, b_score int,
  created_at timestamptz not null default now(),
  done boolean not null default false,
  winner uuid
);
alter table public.pack_duels enable row level security;
create index if not exists pack_duels_a on public.pack_duels(a, done);
create index if not exists pack_duels_b on public.pack_duels(b, done);

create or replace function public._rpts(r text) returns int language sql immutable as $$
  select case r when 'L' then 100 when 'ED' then 100 when 'UR' then 40 when 'SR' then 15 when 'R' then 6 when 'PC' then 2 else 1 end
$$;

create or replace function public._friend_id(nm text) returns uuid language plpgsql stable security definer set search_path = public as $$
declare f uuid;
begin
  select id into f from profiles where lower(username) = lower(nm) and not banned;
  if f is null then raise exception 'Joueur introuvable.'; end if;
  if not exists (select 1 from friendships where user_id = _uid() and friend_id = f) then raise exception 'Vous devez être amis.'; end if;
  return f;
end $$;

-- règle un défi : le meilleur score gagne 100 pistons ; égalité : 30 chacun ; après 48 h, celui qui a ouvert gagne
create or replace function public._duel_settle(d pack_duels) returns void language plpgsql security definer set search_path = public as $$
declare w uuid; an text; bn text;
begin
  if d.done then return; end if;
  if d.a_score is not null and d.b_score is not null then
    w := case when d.a_score > d.b_score then d.a when d.b_score > d.a_score then d.b end;
  elsif d.created_at < now() - interval '48 hours' then
    w := case when d.a_score is not null then d.a when d.b_score is not null then d.b end;
    if w is null then update pack_duels set done = true where id = d.id; return; end if;
  else return; end if;
  update pack_duels set done = true, winner = w where id = d.id;
  select username into an from profiles where id = d.a; select username into bn from profiles where id = d.b;
  if w is null then
    update wallets set coins = coins + 30 where user_id in (d.a, d.b);
    perform _notify(d.a, 'Défi d''ouverture contre ' || bn || ' : égalité ! +30 pistons.');
    perform _notify(d.b, 'Défi d''ouverture contre ' || an || ' : égalité ! +30 pistons.');
  else
    update wallets set coins = coins + 100 where user_id = w;
    perform _notify(w, 'Vous gagnez le défi d''ouverture contre ' || case when w = d.a then bn else an end || ' ! +100 pistons.');
    perform _notify(case when w = d.a then d.b else d.a end, case when w = d.a then an else bn end || ' gagne le défi d''ouverture. Revanche ?');
  end if;
end $$;

create or replace function public.get_social() returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); t date := (now() at time zone 'Europe/Paris')::date; d pack_duels;
begin
  for d in select * from pack_duels where (a = u or b = u) and not done loop perform _duel_settle(d); end loop;
  return jsonb_build_object(
    'gift', (select p.username from gifts g join profiles p on p.id = g.to_id where g.user_id = u and g.day = t),
    'made', (select count(*) from pack_duels where a = u and created_at > now() - interval '24 hours'),
    'duels', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'foe', p.username, 'me_a', x.a = u, 'done', x.done,
        'win', case when x.done then case when x.winner is null then 0 when x.winner = u then 1 else -1 end end,
        'mine', case when x.a = u then x.a_cards else x.b_cards end, 'ms', case when x.a = u then x.a_score else x.b_score end,
        'theirs', case when (case when x.a = u then x.a_cards else x.b_cards end) is not null or x.done then case when x.a = u then x.b_cards else x.a_cards end end,
        'ts', case when (case when x.a = u then x.a_cards else x.b_cards end) is not null or x.done then case when x.a = u then x.b_score else x.a_score end end,
        'opened', (case when x.a = u then x.b_cards else x.a_cards end) is not null,
        'ends', x.created_at + interval '48 hours') order by x.done, x.created_at desc)
      from (select * from pack_duels where (a = u or b = u) and (not done or created_at > now() - interval '3 days') order by created_at desc limit 20) x
      join profiles p on p.id = case when x.a = u then x.b else x.a end), '[]'::jsonb));
end $$;

create or replace function public.send_gift(nm text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); f uuid := _friend_id(nm); t date := (now() at time zone 'Europe/Paris')::date; me text;
begin
  insert into gifts(user_id, day, to_id) values (u, t, f) on conflict do nothing;
  if not found then raise exception 'Vous avez déjà offert un paquet aujourd''hui. Revenez demain !'; end if;
  update wallets set packs = packs + 1 where user_id = f;
  select username into me from profiles where id = u;
  perform _notify(f, me || ' vous offre un paquet ! 🎁');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.duel_create(nm text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); f uuid := _friend_id(nm); me text; nid bigint;
begin
  if (select count(*) from pack_duels where a = u and created_at > now() - interval '24 hours') >= 3 then raise exception 'Trois défis par jour au maximum.'; end if;
  if exists (select 1 from pack_duels where not done and ((a = u and b = f) or (a = f and b = u))) then raise exception 'Un défi est déjà en cours avec ce joueur.'; end if;
  insert into pack_duels(a, b) values (u, f) returning id into nid;
  select username into me from profiles where id = u;
  perform _notify(f, me || ' vous lance un défi d''ouverture : qui tirera les meilleures cartes ? Vous avez 48 h.');
  return jsonb_build_object('id', nid);
end $$;

create or replace function public.duel_open(did bigint) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); d pack_duels; ids int[] := '{}'; c int; sc int := 0; i int;
begin
  select * into d from pack_duels where id = did for update;
  if d.id is null or (d.a <> u and d.b <> u) then raise exception 'Défi introuvable.'; end if;
  if d.done then raise exception 'Ce défi est terminé.'; end if;
  if (d.a = u and d.a_cards is not null) or (d.b = u and d.b_cards is not null) then raise exception 'Vous avez déjà ouvert votre paquet.'; end if;
  for i in 1..5 loop c := _draw(false); ids := ids || c; perform _give(u, c, false); end loop;
  select coalesce(sum(_rpts(rarity)), 0) into sc from cards where id = any(ids);
  -- une carte présente deux fois compte deux fois
  sc := (select coalesce(sum(_rpts(cards.rarity)), 0) from unnest(ids) x join cards on cards.id = x);
  if d.a = u then update pack_duels set a_cards = ids, a_score = sc where id = did; else update pack_duels set b_cards = ids, b_score = sc where id = did; end if;
  select * into d from pack_duels where id = did;
  perform _duel_settle(d);
  return jsonb_build_object('cards', ids, 'score', sc);
end $$;

-- ===== parrainage : 1 paquet pour le parrain et 1 pour le filleul dès l'inscription =====
create or replace function public._ref_welcome() returns trigger language plpgsql security definer set search_path = public as $$
declare p profiles;
begin
  begin
    select * into p from profiles where id = new.user_id;
    if p.invited_by is not null then
      new.packs := coalesce(new.packs, 0) + 1;
      update wallets set packs = packs + 1 where user_id = p.invited_by;
      perform _notify(p.invited_by, coalesce(p.username, 'Un joueur') || ' s''est inscrit avec votre lien : +1 paquet !');
    end if;
  exception when others then null;
  end;
  return new;
end $$;
drop trigger if exists ref_welcome on public.wallets;
create trigger ref_welcome before insert on public.wallets for each row execute function public._ref_welcome();

-- ===== code du jour =====
create table if not exists public.app_salt (k text primary key, v text not null);
insert into public.app_salt values ('daily', md5(random()::text || clock_timestamp()::text)) on conflict do nothing;

create or replace function public._daily_code(d date) returns text language sql stable security definer set search_path = public as $$
  select (array['TURBO','NITRO','DRIFT','PISTON','APEX','BOOST','CHRONO','RALLYE','GARAGE','PADDOCK','VIRAGE','DRAPEAU'])[1 + abs(hashtext(v || d::text || 'w')) % 12]
         || lpad((abs(hashtext(v || d::text)) % 1000)::text, 3, '0')
  from app_salt where k = 'daily'
$$;

create or replace function public._ensure_daily_code() returns text language plpgsql security definer set search_path = public as $$
declare t date := (now() at time zone 'Europe/Paris')::date; k text := _daily_code(t);
begin
  insert into cheat_codes(code, packs, coins, ends_at, active)
  values (k, 1, 50, ((t + 1)::timestamp) at time zone 'Europe/Paris', true) on conflict (code) do nothing;
  return k;
end $$;

-- get_bonus crée le code du jour au passage (et le donne aux administrateurs)
create or replace function public.get_bonus() returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare u uuid := _uid(); t date := (now() at time zone 'Europe/Paris')::date; b bonus; k text := _ensure_daily_code();
begin
  select * into b from bonus where user_id = u;
  return jsonb_build_object('wheel', b.wheel_last is not distinct from t, 'spins', coalesce(b.wheel_n, 0),
    'sat', _surprise_at(u, t), 'sgot', b.surprise_last is not distinct from t, 'snext', _surprise_at(u, t + 1),
    'code', case when exists (select 1 from profiles where id = u and is_admin) then k end,
    'hook', case when exists (select 1 from profiles where id = u and is_admin) then exists (select 1 from app_hooks where app_hooks.k = 'discord') end);
end $$;

-- ===== code du jour publié tout seul sur Discord (chaque matin vers 8 h) =====
create table if not exists public.app_hooks (k text primary key, url text not null);
alter table public.app_hooks enable row level security;
do $x$ begin
  begin execute 'create extension if not exists pg_net'; exception when others then raise notice 'pg_net indisponible : %', sqlerrm; end;
  begin execute 'create extension if not exists pg_cron'; exception when others then raise notice 'pg_cron indisponible : %', sqlerrm; end;
end $x$;

create or replace function public._post_daily_code() returns void language plpgsql security definer set search_path = public, extensions as $$
declare k text := _ensure_daily_code(); u text;
begin
  select url into u from app_hooks where app_hooks.k = 'discord';
  if u is null then return; end if;
  perform net.http_post(url := u,
    body := jsonb_build_object('content', E'🎁 **Code du jour : `' || k || E'`**\n1 paquet + 50 pistons, valable jusqu''à minuit.\nÀ entrer dans Paramètres → Codes de triche sur https://paddock.click'),
    headers := '{"Content-Type": "application/json"}'::jsonb);
end $$;

create or replace function public.set_discord_hook(url text) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from profiles where id = _uid() and is_admin) then raise exception 'Réservé aux administrateurs.'; end if;
  if url is null or url = '' then delete from app_hooks where k = 'discord'; return jsonb_build_object('hook', false); end if;
  if url !~ '^https://(discord|discordapp)\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$' then raise exception 'Ce n''est pas une adresse de webhook Discord.'; end if;
  insert into app_hooks values ('discord', url) on conflict (k) do update set url = excluded.url;
  perform _post_daily_code();
  return jsonb_build_object('hook', true);
end $$;
revoke all on function public._post_daily_code() from public, anon, authenticated;
revoke all on function public.set_discord_hook(text) from public, anon;
grant execute on function public.set_discord_hook(text) to authenticated;

do $x$ begin
  begin
    perform cron.unschedule(jobid) from cron.job where jobname = 'paddock-code-du-jour';
    perform cron.schedule('paddock-code-du-jour', '5 7 * * *', 'select public._post_daily_code()');
  exception when others then raise notice 'programmation impossible : %', sqlerrm; end;
end $x$;

revoke all on function public._rpts(text) from public, anon, authenticated;
revoke all on function public._friend_id(text) from public, anon, authenticated;
revoke all on function public._duel_settle(pack_duels) from public, anon, authenticated;
revoke all on function public._ref_welcome() from public, anon, authenticated;
revoke all on function public._daily_code(date) from public, anon, authenticated;
revoke all on function public._ensure_daily_code() from public, anon, authenticated;
revoke all on function public.get_social() from public, anon;
revoke all on function public.send_gift(text) from public, anon;
revoke all on function public.duel_create(text) from public, anon;
revoke all on function public.duel_open(bigint) from public, anon;
grant execute on function public.get_social() to authenticated;
grant execute on function public.send_gift(text) to authenticated;
grant execute on function public.duel_create(text) to authenticated;
grant execute on function public.duel_open(bigint) to authenticated;
grant execute on function public.get_bonus() to authenticated;

commit;

select 'vague 2 installée' as resultat, public._ensure_daily_code() as code_du_jour;
