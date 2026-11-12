-- GRAFITYGATE：GATE に置く AR の作品（写真パネル・光る文字・花びら・光）
--
-- 作品は扉（場所の記憶の印 gg.gate）を基準にした位置・向き・大きさで残す。扉が同じ位置に出れば、作品も同じ位置に出る。
-- 置く・動かすのは現地で入場中のときだけ。見られるのも入場中の人（と置いた本人）だけ。
-- 触れたときの反応は、プログラムではなく決まった形のルール（きっかけ と 動き）で残し、サーバーで中身を確かめる。
--
-- 使い方：0002 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

insert into public.gf_settings (key, value, note) values
  ('artworks_per_user_gate', 3, '1 人が 1 つの GATE に置ける作品の数'),
  ('artworks_per_gate', 30, '1 つの GATE に置ける作品の数'),
  ('artworks_per_day', 20, '1 日に置ける作品の数')
on conflict (key) do nothing;

-- 反応のルール：[{"trigger":"touch","action":"burst","cooldown_ms":1500}, …]（6 つまで）
-- 動き：glow 光る／sway ゆれる／ripple 波紋／burst はじける／bounce はねる／chime 鳴る（やさしい鐘の音）
create or replace function public.gf_valid_rules(r jsonb) returns boolean
language sql immutable as $$
  select r is not null and jsonb_typeof(r) = 'array' and jsonb_array_length(r) <= 6 and not exists (
    select 1 from jsonb_array_elements(r) as e(x)
    where case
      when jsonb_typeof(x) <> 'object' then true
      when coalesce(x ->> 'trigger', '') not in ('approach', 'touch', 'tap', 'open') then true
      when coalesce(x ->> 'action', '') not in ('glow', 'sway', 'ripple', 'burst', 'bounce', 'chime') then true
      when x ? 'cooldown_ms' and jsonb_typeof(x -> 'cooldown_ms') <> 'number' then true
      when x ? 'cooldown_ms' and (x ->> 'cooldown_ms')::numeric not between 0 and 10000 then true
      when exists (select 1 from jsonb_object_keys(x) as k(name) where name not in ('trigger', 'action', 'cooldown_ms')) then true
      else false
    end)
$$;

create table if not exists public.gf_artworks (
  id uuid primary key default gen_random_uuid(),
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  owner uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('photo', 'text', 'petals', 'light')),
  body text not null default '' check (char_length(body) <= 120),
  photo_path text,
  color text not null default 'warm' check (color in ('warm', 'white', 'sakura', 'mint', 'sky')),
  -- 扉の足もとの中心からの位置（m）と、向き（ラジアン）・大きさ
  px real not null check (px between -4 and 4),
  py real not null check (py between -0.5 and 3.5),
  pz real not null check (pz between -4 and 4),
  yaw real not null default 0 check (yaw between -7 and 7),
  scale real not null default 1 check (scale between 0.3 and 3),
  rules jsonb not null default '[]'::jsonb check (public.gf_valid_rules(rules)),
  visibility text not null default 'friends' check (visibility in ('private', 'friends', 'public')),
  status text not null default 'published' check (status in ('published', 'hidden')),
  revision int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (kind <> 'photo' or photo_path is not null),
  check (kind <> 'text' or char_length(btrim(body)) > 0)
);
create index if not exists gf_artworks_gate on public.gf_artworks(gate_id, created_at);
create index if not exists gf_artworks_photo on public.gf_artworks(photo_path);
alter table public.gf_artworks enable row level security;

-- 作品を見てよいか：置いた本人はいつでも。ほかの人は、公開中で、その GATE に入場中で、公開範囲が合うとき。
create or replace function public.gf_can_see_artwork(a public.gf_artworks, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and (
    a.owner = viewer or (
      a.status = 'published'
      and not gf_blocked(viewer, a.owner)
      and gf_active_visit(a.gate_id, viewer) is not null
      and (a.visibility = 'public' or (a.visibility = 'friends' and gf_mutual(viewer, a.owner)))))
$$;

drop policy if exists "gf artworks read" on public.gf_artworks;
create policy "gf artworks read" on public.gf_artworks for select to authenticated
  using (public.gf_can_see_artwork(gf_artworks, auth.uid()));

-- 作品を置く（入場中だけ）
create or replace function public.gf_place_artwork(
  p_visit uuid, p_kind text, p_body text, p_photo_path text, p_color text,
  p_px real, p_py real, p_pz real, p_yaw real, p_scale real, p_rules jsonb, p_visibility text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v gf_visits;
  g gf_gates;
  aid uuid;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into v from gf_visits where id = p_visit and user_id = me;
  if not found or v.revoked_at is not null or v.expires_at <= now() then
    raise exception 'gf_visit_invalid' using errcode = 'P0001';
  end if;
  select * into g from gf_gates where id = v.gate_id for update;
  if not found or not gf_can_see_gate(g, me) then
    raise exception 'gf_visit_invalid' using errcode = 'P0001';
  end if;
  if p_photo_path is not null and split_part(p_photo_path, '/', 1) <> me::text then
    raise exception 'gf_bad_media_path' using errcode = 'P0001';
  end if;
  if not gf_valid_rules(coalesce(p_rules, '[]'::jsonb)) then
    raise exception 'gf_bad_rules' using errcode = 'P0001';
  end if;
  if (select count(*) from gf_artworks where gate_id = g.id and owner = me and status = 'published')
     >= gf_setting('artworks_per_user_gate') then
    raise exception 'gf_artwork_limit' using errcode = 'P0001';
  end if;
  if (select count(*) from gf_artworks where gate_id = g.id and status = 'published') >= gf_setting('artworks_per_gate') then
    raise exception 'gf_gate_full' using errcode = 'P0001';
  end if;
  perform gf_take_rate('artwork', gf_setting('artworks_per_day'), 86400);
  begin
    insert into gf_artworks (gate_id, owner, kind, body, photo_path, color, px, py, pz, yaw, scale, rules, visibility)
    values (g.id, me, p_kind, coalesce(p_body, ''), p_photo_path, coalesce(p_color, 'warm'),
            p_px, p_py, p_pz, coalesce(p_yaw, 0), coalesce(p_scale, 1), coalesce(p_rules, '[]'::jsonb),
            coalesce(p_visibility, 'friends'))
    returning id into aid;
  exception when check_violation then
    raise exception 'gf_bad_artwork' using errcode = 'P0001';
  end;
  return aid;
end $$;

-- 自分の作品を置き直す（入場中だけ。ほかの端末で先に動かしていたら断る＝revision が違う）
create or replace function public.gf_move_artwork(
  p_id uuid, p_visit uuid, p_px real, p_py real, p_pz real, p_yaw real, p_scale real, p_revision int)
returns int
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  a gf_artworks;
  next_revision int;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into a from gf_artworks where id = p_id and owner = me for update;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  if not exists (select 1 from gf_visits where id = p_visit and user_id = me and gate_id = a.gate_id
                 and revoked_at is null and expires_at > now()) then
    raise exception 'gf_visit_invalid' using errcode = 'P0001';
  end if;
  if a.revision <> p_revision then raise exception 'gf_revision_conflict' using errcode = 'P0001'; end if;
  begin
    update gf_artworks set px = p_px, py = p_py, pz = p_pz, yaw = coalesce(p_yaw, yaw), scale = coalesce(p_scale, scale),
                           revision = revision + 1, updated_at = now()
    where id = p_id
    returning revision into next_revision;
  exception when check_violation then
    raise exception 'gf_bad_artwork' using errcode = 'P0001';
  end;
  return next_revision;
end $$;

-- 自分の作品を隠す・出し直す（遠くからでもよい）
create or replace function public.gf_set_artwork_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_status not in ('published', 'hidden') then raise exception 'gf_bad_artwork' using errcode = 'P0001'; end if;
  update gf_artworks set status = p_status, updated_at = now() where id = p_id and owner = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- 自分の作品を消す（遠くからでもよい）
create or replace function public.gf_delete_artwork(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_artworks where id = p_id and owner = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- 写真を見てよいか（0001 のものに、作品の写真を足す）
create or replace function public.gf_can_read_media(p_path text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    split_part(p_path, '/', 1) = auth.uid()::text
    or exists (select 1 from gf_gates g where g.cover_path = p_path and gf_can_see_gate(g, auth.uid()))
    or exists (select 1 from gf_graffiti x where x.photo_path = p_path
               and (gf_can_see_graffiti(x, auth.uid()) or gf_feed_visible(x, auth.uid())))
    or exists (select 1 from gf_artworks a where a.photo_path = p_path and gf_can_see_artwork(a, auth.uid())))
$$;

revoke all on function public.gf_can_see_artwork(public.gf_artworks, uuid) from public, anon;
grant execute on function public.gf_can_see_artwork(public.gf_artworks, uuid) to authenticated;
revoke all on function public.gf_place_artwork(uuid, text, text, text, text, real, real, real, real, real, jsonb, text) from public, anon;
revoke all on function public.gf_move_artwork(uuid, uuid, real, real, real, real, real, int) from public, anon;
revoke all on function public.gf_set_artwork_status(uuid, text) from public, anon;
revoke all on function public.gf_delete_artwork(uuid) from public, anon;
grant execute on function public.gf_place_artwork(uuid, text, text, text, text, real, real, real, real, real, jsonb, text) to authenticated;
grant execute on function public.gf_move_artwork(uuid, uuid, real, real, real, real, real, int) to authenticated;
grant execute on function public.gf_set_artwork_status(uuid, text) to authenticated;
grant execute on function public.gf_delete_artwork(uuid) to authenticated;
revoke all on function public.gf_can_read_media(text) from public, anon;
grant execute on function public.gf_can_read_media(text) to authenticated;
