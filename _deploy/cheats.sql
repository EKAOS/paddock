-- =====================================================================
--  PADDOCK — codes de triche
--  Chaque code ne sert qu'une fois par compte. Les administrateurs créent
--  et désactivent les codes depuis le panneau Modération.
--  Peut être relancé sans risque.
-- =====================================================================
create table if not exists public.cheat_codes (
  code text primary key,
  packs int not null default 0 check (packs between 0 and 20),
  coins int not null default 0 check (coins between 0 and 5000),
  active boolean not null default true,
  ends_at timestamptz,
  max_uses int,
  secret boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.cheat_uses (
  user_id uuid not null references auth.users(id) on delete cascade,
  code text not null references public.cheat_codes(code) on delete cascade,
  at timestamptz not null default now(),
  primary key (user_id, code)
);
create table if not exists public.cheat_tries (
  user_id uuid not null,
  at timestamptz not null default now()
);
create index if not exists cheat_tries_u on public.cheat_tries(user_id, at);
alter table public.cheat_codes enable row level security;
alter table public.cheat_uses enable row level security;
alter table public.cheat_tries enable row level security;

create or replace function public._cheat_norm(c text) returns text language sql immutable as $$
  select upper(regexp_replace(translate(coalesce(c,''), 'àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ', 'aaaeeeeiioouuucAAAEEEEIIOOUUUC'), '[^A-Za-z0-9]', '', 'g'))
$$;

create or replace function public.redeem_cheat(c text) returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := _uid(); k text := _cheat_norm(c); r cheat_codes; n int;
begin
  if u is null then raise exception 'Connectez-vous pour utiliser un code.'; end if;
  if length(k) < 3 or length(k) > 24 then raise exception 'Code inconnu.'; end if;
  -- anti-devinette : 12 essais ratés par heure au maximum
  delete from cheat_tries where at < now() - interval '1 hour';
  if (select count(*) from cheat_tries where user_id = u) >= 12 then
    raise exception 'Trop d''essais. Réessayez dans une heure.';
  end if;
  select * into r from cheat_codes where code = k;
  if not found or not r.active or (r.ends_at is not null and r.ends_at < now()) then
    -- pas d'exception ici : l'essai raté doit rester enregistré
    insert into cheat_tries(user_id) values (u);
    return jsonb_build_object('err', 'Code inconnu ou expiré.');
  end if;
  if r.max_uses is not null and (select count(*) from cheat_uses where code = k) >= r.max_uses then
    raise exception 'Trop tard : ce code a déjà été utilisé par tout le monde.';
  end if;
  insert into cheat_uses(user_id, code) values (u, k) on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Vous avez déjà utilisé ce code.'; end if;
  update wallets set packs = packs + r.packs, coins = coins + r.coins where user_id = u;
  return jsonb_build_object('code', k, 'packs', r.packs, 'coins', r.coins, 'secret', r.secret);
end $$;

-- administration
create or replace function public.cheat_list() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from profiles where id = _uid() and is_admin) then raise exception 'Réservé aux administrateurs.'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'packs', c.packs, 'coins', c.coins, 'active', c.active,
            'ends', c.ends_at, 'max', c.max_uses, 'secret', c.secret, 'uses', (select count(*) from cheat_uses x where x.code = c.code))
            order by c.created_at desc), '[]'::jsonb) from cheat_codes c);
end $$;

create or replace function public.cheat_save(c text, p int, co int, days int default null, mx int default null, on_ boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k text := _cheat_norm(c);
begin
  if not exists (select 1 from profiles where id = _uid() and is_admin) then raise exception 'Réservé aux administrateurs.'; end if;
  if length(k) < 3 or length(k) > 24 then raise exception 'Le code doit faire entre 3 et 24 lettres ou chiffres.'; end if;
  insert into cheat_codes(code, packs, coins, ends_at, max_uses, active)
  values (k, greatest(0, least(20, coalesce(p,0))), greatest(0, least(5000, coalesce(co,0))),
          case when days is null or days <= 0 then null else now() + make_interval(days => days) end, nullif(mx, 0), on_)
  on conflict (code) do update set packs = excluded.packs, coins = excluded.coins, ends_at = excluded.ends_at,
    max_uses = excluded.max_uses, active = excluded.active;
  return cheat_list();
end $$;

revoke all on function public.redeem_cheat(text), public.cheat_list(), public.cheat_save(text,int,int,int,int,boolean) from public, anon;
grant execute on function public.redeem_cheat(text), public.cheat_list(), public.cheat_save(text,int,int,int,int,boolean) to authenticated;

-- codes de départ
insert into public.cheat_codes(code, packs, coins, secret) values
  ('HHBBGDGDBA', 2, 300, true),   -- le code Konami, sur la manette secrète
  ('VROUM', 1, 0, false),
  ('PLEINGAZ', 0, 300, false),
  ('NITRO', 2, 0, false)
on conflict (code) do nothing;
