-- Grafity Gate：AR の作品の「下書き」（置いた本人だけに見える・現地で試せる）と「置き直しが必要」
--
-- 公開の流れ：下書き → 公開 → 非公開 →（消す）。下書きは、ほかの人には見えない（gf_can_see_artwork は公開だけを見せる）。
-- 作った人が場所の記憶を撮り直したら、その GATE の作品に「置き直しが必要」の印を付ける（本人が置き直すか「このままでよい」で外れる）。
--
-- 使い方：0010 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

alter table public.gf_artworks add column if not exists needs_replace boolean not null default false;

-- 状態の一覧（最後の一覧。あとで状態を足すときも、ここを全部ふくむ形で作り直す）
alter table public.gf_artworks drop constraint if exists gf_artworks_status_check;
alter table public.gf_artworks add constraint gf_artworks_status_check
  check (status in ('draft', 'published', 'hidden'));

-- 作品を置く（入場中だけ）。p_status は 'published'（すぐ公開）か 'draft'（下書き）。
create or replace function public.gf_place_artwork3(
  p_visit uuid, p_kind text, p_body text, p_path text, p_thumb text, p_duration real, p_color text,
  p_px real, p_py real, p_pz real, p_yaw real, p_scale real, p_rules jsonb, p_visibility text, p_status text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v gf_visits;
  g gf_gates;
  aid uuid;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if coalesce(p_status, 'published') not in ('published', 'draft') then
    raise exception 'gf_bad_artwork' using errcode = 'P0001';
  end if;
  select * into v from gf_visits where id = p_visit and user_id = me;
  if not found or v.revoked_at is not null or v.expires_at <= now() then
    raise exception 'gf_visit_invalid' using errcode = 'P0001';
  end if;
  select * into g from gf_gates where id = v.gate_id for update;
  if not found or not gf_can_see_gate(g, me) then
    raise exception 'gf_visit_invalid' using errcode = 'P0001';
  end if;
  if (p_path is not null and split_part(p_path, '/', 1) <> me::text)
     or (p_thumb is not null and split_part(p_thumb, '/', 1) <> me::text) then
    raise exception 'gf_bad_media_path' using errcode = 'P0001';
  end if;
  -- 「流す」は映像・声だけ
  if not gf_valid_rules(coalesce(p_rules, '[]'::jsonb))
     or (p_kind not in ('video', 'voice') and exists (
           select 1 from jsonb_array_elements(coalesce(p_rules, '[]'::jsonb)) as e(x) where x ->> 'action' = 'play')) then
    raise exception 'gf_bad_rules' using errcode = 'P0001';
  end if;
  -- 下書きも数に入れる（下書きを並べて上限を超えないように）
  if (select count(*) from gf_artworks where gate_id = g.id and owner = me and status in ('published', 'draft'))
     >= gf_setting('artworks_per_user_gate') then
    raise exception 'gf_artwork_limit' using errcode = 'P0001';
  end if;
  if (select count(*) from gf_artworks where gate_id = g.id and status in ('published', 'draft'))
     >= gf_setting('artworks_per_gate') then
    raise exception 'gf_gate_full' using errcode = 'P0001';
  end if;
  perform gf_take_rate('artwork', gf_setting('artworks_per_day'), 86400);
  begin
    insert into gf_artworks (gate_id, owner, kind, body, photo_path, thumb_path, duration, color,
                             px, py, pz, yaw, scale, rules, visibility, status)
    values (g.id, me, p_kind, coalesce(p_body, ''), p_path, p_thumb, p_duration, coalesce(p_color, 'warm'),
            p_px, p_py, p_pz, coalesce(p_yaw, 0), coalesce(p_scale, 1), coalesce(p_rules, '[]'::jsonb),
            coalesce(p_visibility, 'friends'), coalesce(p_status, 'published'))
    returning id into aid;
  exception when check_violation then
    raise exception 'gf_bad_artwork' using errcode = 'P0001';
  end;
  return aid;
end $$;

-- 0010 の形は、すぐ公開で新しい形に渡すだけにする（決まりを 1 か所にまとめる）
create or replace function public.gf_place_artwork2(
  p_visit uuid, p_kind text, p_body text, p_path text, p_thumb text, p_duration real, p_color text,
  p_px real, p_py real, p_pz real, p_yaw real, p_scale real, p_rules jsonb, p_visibility text)
returns uuid
language plpgsql security definer set search_path = public as $$
begin
  return gf_place_artwork3(p_visit, p_kind, p_body, p_path, p_thumb, p_duration, p_color,
                           p_px, p_py, p_pz, p_yaw, p_scale, p_rules, p_visibility, 'published');
end $$;

-- 自分の作品の状態を変える（下書き・公開・非公開。遠くからでもよい）
create or replace function public.gf_set_artwork_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_status not in ('draft', 'published', 'hidden') then raise exception 'gf_bad_artwork' using errcode = 'P0001'; end if;
  update gf_artworks set status = p_status, updated_at = now() where id = p_id and owner = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- 自分の作品を置き直す（0003 のものに、「置き直しが必要」を外すのを足す）
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
                           revision = revision + 1, needs_replace = false, updated_at = now()
    where id = p_id
    returning revision into next_revision;
  exception when check_violation then
    raise exception 'gf_bad_artwork' using errcode = 'P0001';
  end;
  return next_revision;
end $$;

-- 「置き直しが必要」を、置き直さずに外す（いまの位置のままでよい。作った本人だけ）
create or replace function public.gf_keep_artwork_place(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_artworks set needs_replace = false, updated_at = now() where id = p_id and owner = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- 場所の記憶が撮り直されたら（2 回め以降の保存）、その GATE の作品に「置き直しが必要」を付ける
create or replace function public.gf_on_place_map_replaced() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.path is distinct from new.path or old.anchor_name is distinct from new.anchor_name
     or old.created_at is distinct from new.created_at then
    update gf_artworks set needs_replace = true where gate_id = new.gate_id and status <> 'hidden';
  end if;
  return new;
end $$;
drop trigger if exists gf_on_place_map_replaced on public.gf_place_maps;
create trigger gf_on_place_map_replaced after update on public.gf_place_maps
  for each row execute function public.gf_on_place_map_replaced();

-- 作品のお知らせは、公開したときだけ（下書きを置いたときは知らせない）
create or replace function public.gf_on_artwork() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner_id uuid;
begin
  if new.status <> 'published' then return new; end if;
  if tg_op = 'UPDATE' and old.status <> 'draft' then return new; end if;
  select owner into owner_id from gf_gates where id = new.gate_id;
  if gf_visible_to(new.visibility, new.owner, owner_id) then
    perform gf_notify(owner_id, 'gate_artwork', new.owner, new.gate_id, new.id);
  end if;
  return new;
end $$;
drop trigger if exists gf_on_artwork on public.gf_artworks;
create trigger gf_on_artwork after insert or update of status on public.gf_artworks
  for each row execute function public.gf_on_artwork();

revoke all on function public.gf_place_artwork3(uuid, text, text, text, text, real, text, real, real, real, real, real, jsonb, text, text) from public, anon;
grant execute on function public.gf_place_artwork3(uuid, text, text, text, text, real, text, real, real, real, real, real, jsonb, text, text) to authenticated;
revoke all on function public.gf_place_artwork2(uuid, text, text, text, text, real, text, real, real, real, real, real, jsonb, text) from public, anon;
grant execute on function public.gf_place_artwork2(uuid, text, text, text, text, real, text, real, real, real, real, real, jsonb, text) to authenticated;
revoke all on function public.gf_set_artwork_status(uuid, text) from public, anon;
grant execute on function public.gf_set_artwork_status(uuid, text) to authenticated;
revoke all on function public.gf_move_artwork(uuid, uuid, real, real, real, real, real, int) from public, anon;
grant execute on function public.gf_move_artwork(uuid, uuid, real, real, real, real, real, int) to authenticated;
revoke all on function public.gf_keep_artwork_place(uuid) from public, anon;
grant execute on function public.gf_keep_artwork_place(uuid) to authenticated;
revoke all on function public.gf_on_place_map_replaced() from public, anon, authenticated;
revoke all on function public.gf_on_artwork() from public, anon, authenticated;
