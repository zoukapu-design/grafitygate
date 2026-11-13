-- Grafity Gate：AR の作品に「映像パネル」（15 秒までの動画）と「声の玉」（60 秒までの声）
--
-- ファイルは gf-media の自分のフォルダ（photo_path に動画・声、映像パネルの表紙の絵は thumb_path）。
-- 触れたとき・近づいたときに流す動き「play」を足す。長さと形の決まりは表の check で守る。
-- 見てよい人は、ほかの作品と同じ（置いた本人と、入場中で公開範囲が合う人）。
--
-- 使い方：0009 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

alter table public.gf_artworks add column if not exists thumb_path text;
alter table public.gf_artworks add column if not exists duration real;
create index if not exists gf_artworks_thumb on public.gf_artworks(thumb_path);

-- 種類の一覧（最後の一覧。あとで種類を足すときも、ここを全部ふくむ形で作り直す）
alter table public.gf_artworks drop constraint if exists gf_artworks_kind_check;
alter table public.gf_artworks add constraint gf_artworks_kind_check
  check (kind in ('photo', 'text', 'petals', 'light', 'video', 'voice'));

-- 映像：ファイル・表紙の絵・0.5〜15 秒。声：ファイル・0.5〜60 秒（表紙なし）。ほかの種類は長さも表紙もなし。
alter table public.gf_artworks drop constraint if exists gf_artworks_media_check;
alter table public.gf_artworks add constraint gf_artworks_media_check check (
  case kind
    when 'video' then photo_path is not null and thumb_path is not null
                      and duration is not null and duration between 0.5 and 15.5
    when 'voice' then photo_path is not null and thumb_path is null
                      and duration is not null and duration between 0.5 and 60.5
    else thumb_path is null and duration is null
  end);

-- 反応のルール（0003 の一覧に「play 流す」を足した、最後の一覧）
create or replace function public.gf_valid_rules(r jsonb) returns boolean
language sql immutable as $$
  select r is not null and jsonb_typeof(r) = 'array' and jsonb_array_length(r) <= 6 and not exists (
    select 1 from jsonb_array_elements(r) as e(x)
    where case
      when jsonb_typeof(x) <> 'object' then true
      when coalesce(x ->> 'trigger', '') not in ('approach', 'touch', 'tap', 'open') then true
      when coalesce(x ->> 'action', '') not in ('glow', 'sway', 'ripple', 'burst', 'bounce', 'chime', 'play') then true
      when x ? 'cooldown_ms' and jsonb_typeof(x -> 'cooldown_ms') <> 'number' then true
      when x ? 'cooldown_ms' and (x ->> 'cooldown_ms')::numeric not between 0 and 10000 then true
      when exists (select 1 from jsonb_object_keys(x) as k(name) where name not in ('trigger', 'action', 'cooldown_ms')) then true
      else false
    end)
$$;

-- 作品を置く（入場中だけ）。映像・声は p_path にファイル、映像は p_thumb に表紙の絵、p_duration に長さ（秒）。
create or replace function public.gf_place_artwork2(
  p_visit uuid, p_kind text, p_body text, p_path text, p_thumb text, p_duration real, p_color text,
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
  if (select count(*) from gf_artworks where gate_id = g.id and owner = me and status = 'published')
     >= gf_setting('artworks_per_user_gate') then
    raise exception 'gf_artwork_limit' using errcode = 'P0001';
  end if;
  if (select count(*) from gf_artworks where gate_id = g.id and status = 'published') >= gf_setting('artworks_per_gate') then
    raise exception 'gf_gate_full' using errcode = 'P0001';
  end if;
  perform gf_take_rate('artwork', gf_setting('artworks_per_day'), 86400);
  begin
    insert into gf_artworks (gate_id, owner, kind, body, photo_path, thumb_path, duration, color,
                             px, py, pz, yaw, scale, rules, visibility)
    values (g.id, me, p_kind, coalesce(p_body, ''), p_path, p_thumb, p_duration, coalesce(p_color, 'warm'),
            p_px, p_py, p_pz, coalesce(p_yaw, 0), coalesce(p_scale, 1), coalesce(p_rules, '[]'::jsonb),
            coalesce(p_visibility, 'friends'))
    returning id into aid;
  exception when check_violation then
    raise exception 'gf_bad_artwork' using errcode = 'P0001';
  end;
  return aid;
end $$;

-- 前の形（アプリの前の版が使う）は、新しい形に渡すだけにする（決まりを 1 か所にまとめる）
create or replace function public.gf_place_artwork(
  p_visit uuid, p_kind text, p_body text, p_photo_path text, p_color text,
  p_px real, p_py real, p_pz real, p_yaw real, p_scale real, p_rules jsonb, p_visibility text)
returns uuid
language plpgsql security definer set search_path = public as $$
begin
  return gf_place_artwork2(p_visit, p_kind, p_body, p_photo_path, null, null, p_color,
                           p_px, p_py, p_pz, p_yaw, p_scale, p_rules, p_visibility);
end $$;

-- 写真・動画・声を見てよいか（0009 のものに、作品の表紙の絵を足す）
create or replace function public.gf_can_read_media(p_path text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    split_part(p_path, '/', 1) = auth.uid()::text
    or exists (select 1 from gf_gates g where g.cover_path = p_path and gf_can_see_gate(g, auth.uid()))
    or exists (select 1 from gf_graffiti x where x.photo_path = p_path
               and (gf_can_see_graffiti(x, auth.uid()) or gf_feed_visible(x, auth.uid())))
    or exists (select 1 from gf_artworks a where (a.photo_path = p_path or a.thumb_path = p_path)
               and gf_can_see_artwork(a, auth.uid()))
    or exists (select 1 from gf_letters l where l.photo_path = p_path and l.recipient = auth.uid()
               and l.opened_at is not null and not gf_blocked(l.author, l.recipient))
    or exists (select 1 from gf_memory_items i join gf_memories m on m.id = i.memory_id
               where (i.photo_path = p_path or i.thumb_path = p_path)
                 and gf_can_see_memory(m, auth.uid()) and not gf_blocked(auth.uid(), i.author))
    or exists (select 1 from gf_snapshots s where s.photo_path = p_path and gf_can_see_snapshot(s, auth.uid())))
$$;

-- 自分の作品を消す。消したファイルの名前を返す（映像は表紙の絵も。アプリがファイルも消す）
create or replace function public.gf_delete_artwork2(p_id uuid) returns text[]
language plpgsql security definer set search_path = public as $$
declare
  main_path text;
  thumb text;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_artworks where id = p_id and owner = auth.uid() returning photo_path, thumb_path into main_path, thumb;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return array_remove(array[main_path, thumb], null);
end $$;

revoke all on function public.gf_place_artwork2(uuid, text, text, text, text, real, text, real, real, real, real, real, jsonb, text) from public, anon;
grant execute on function public.gf_place_artwork2(uuid, text, text, text, text, real, text, real, real, real, real, real, jsonb, text) to authenticated;
revoke all on function public.gf_place_artwork(uuid, text, text, text, text, real, real, real, real, real, jsonb, text) from public, anon;
grant execute on function public.gf_place_artwork(uuid, text, text, text, text, real, real, real, real, real, jsonb, text) to authenticated;
revoke all on function public.gf_delete_artwork2(uuid) from public, anon;
grant execute on function public.gf_delete_artwork2(uuid) to authenticated;
revoke all on function public.gf_can_read_media(text) from public, anon;
grant execute on function public.gf_can_read_media(text) to authenticated;
