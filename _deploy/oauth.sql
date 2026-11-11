-- =====================================================================
--  PADDOCK — connexion avec Google, Apple et Discord
--  Un compte créé par un de ces services n'a pas encore de pseudo :
--  on lui en donne un provisoire, et le joueur choisit le sien à la
--  première connexion (une seule fois, gratuitement).
--  Ne modifie pas la création de compte par e-mail. Peut être relancé.
-- =====================================================================
alter table public.profiles add column if not exists name_pending boolean not null default false;

create or replace function public._free_name(base text) returns text language plpgsql security definer set search_path = public as $$
declare b text := left(regexp_replace(coalesce(base, ''), '[^A-Za-z0-9_.-]', '', 'g'), 14); c text; i int := 0;
begin
  if length(b) < 3 then b := 'Pilote'; end if;
  c := b;
  while exists(select 1 from profiles where lower(username) = lower(c)) loop
    i := i + 1; c := b || (100 + floor(random() * 9900))::int;
    exit when i > 30;
  end loop;
  return c;
end $$;

-- avant la création du compte : un pseudo provisoire si le service n'en fournit pas
create or replace function public._oauth_prefill() returns trigger language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb); base text;
begin
  if trim(coalesce(m->>'username', '')) <> '' then return new; end if;
  base := translate(coalesce(nullif(m->>'preferred_username', ''), nullif(m->>'user_name', ''), nullif(m->>'full_name', ''), nullif(m->>'name', ''),
                    split_part(coalesce(new.email, ''), '@', 1)),
                    'àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ ', 'aaaeeeeiioouuucAAAEEEEIIOOUUUC_');
  new.raw_user_meta_data := m || jsonb_build_object('username', _free_name(base), 'name_pending', true);
  return new;
end $$;
drop trigger if exists a_oauth_prefill on auth.users;
create trigger a_oauth_prefill before insert on auth.users for each row execute function public._oauth_prefill();

-- après la création du profil : on note que le pseudo reste à choisir
create or replace function public._oauth_flag() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce((new.raw_user_meta_data->>'name_pending')::boolean, false) then
    update profiles set name_pending = true where id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists zz_oauth_flag on auth.users;
create trigger zz_oauth_flag after insert on auth.users for each row execute function public._oauth_flag();

create or replace function public.name_pending() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('pending', coalesce(p.name_pending, false), 'name', p.username) from profiles p where p.id = _uid()
$$;

create or replace function public.pick_username(u text, inv text default '') returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := _uid(); p profiles; inviter uuid;
begin
  select * into p from profiles where id = me for update;
  if not found then raise exception 'Compte introuvable.'; end if;
  if not p.name_pending then raise exception 'Votre pseudo est déjà choisi.'; end if;
  u := trim(coalesce(u, ''));
  if u !~ '^[A-Za-z0-9_.-]{3,20}$' then raise exception 'Le pseudo doit faire 3 à 20 caractères : lettres, chiffres, _ . -'; end if;
  if exists(select 1 from profiles where lower(username) = lower(u) and id <> me) then raise exception 'Ce pseudo est déjà pris.'; end if;
  update profiles set username = u, name_pending = false where id = me;
  inv := trim(coalesce(inv, ''));
  if inv <> '' and p.invited_by is null then
    select id into inviter from profiles where (lower(invite_code) = lower(inv) or lower(username) = lower(inv)) and id <> me and not banned;
    if inviter is not null then
      update profiles set invited_by = inviter where id = me;
      update wallets set ref_count = ref_count + 1 where user_id = inviter;
      insert into friendships(user_id, friend_id) values (inviter, me), (me, inviter) on conflict do nothing;
      perform _notify(inviter, u || ' a rejoint Paddock grâce à votre invitation.');
    end if;
  end if;
  return jsonb_build_object('name', u);
end $$;

revoke all on function public.name_pending(), public.pick_username(text, text) from public, anon;
grant execute on function public.name_pending(), public.pick_username(text, text) to authenticated;
revoke all on function public._free_name(text) from public, anon, authenticated;
