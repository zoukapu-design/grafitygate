-- Grafity Gate：AR の作品「切り抜いた人物の映像」（person）
--
-- 人が写った 10 秒までの動画から、iPhone の中で人だけを切り抜き（Apple の Vision）、
-- 透けるところのある動画（HEVC のアルファ付き・.mov）にして gf-media に置く。表紙の絵は thumb_path。
-- 扉の前の地面に、こちらを向いて立つように見せ、近づく・触れると流れる（動き play）。
--
-- 使い方：0011 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

-- 種類の一覧（最後の一覧。0010 の一覧に person を足した）
alter table public.gf_artworks drop constraint if exists gf_artworks_kind_check;
alter table public.gf_artworks add constraint gf_artworks_kind_check
  check (kind in ('photo', 'text', 'petals', 'light', 'video', 'voice', 'person'));

-- 映像：表紙の絵つき 15 秒まで。人物：表紙の絵つき 10 秒まで。声：60 秒まで。ほかは長さも表紙もなし（最後の一覧）
alter table public.gf_artworks drop constraint if exists gf_artworks_media_check;
alter table public.gf_artworks add constraint gf_artworks_media_check check (
  case kind
    when 'video' then photo_path is not null and thumb_path is not null
                      and duration is not null and duration between 0.5 and 15.5
    when 'person' then photo_path is not null and thumb_path is not null
                       and duration is not null and duration between 0.5 and 10.5
    when 'voice' then photo_path is not null and thumb_path is null
                      and duration is not null and duration between 0.5 and 60.5
    else thumb_path is null and duration is null
  end);

-- 「流す」を付けてよい種類（映像・声・人物）。あとで種類を足すときは、ここだけ直す
create or replace function public.gf_artwork_kind_plays(p_kind text) returns boolean
language sql immutable as $$
  select coalesce(p_kind in ('video', 'voice', 'person'), false)
$$;

-- 作品を置く（0011 のものの「流す」の確かめを、上の関数にする）
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
     or (not gf_artwork_kind_plays(p_kind) and exists (
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

revoke all on function public.gf_artwork_kind_plays(text) from public, anon;
grant execute on function public.gf_artwork_kind_plays(text) to authenticated;
revoke all on function public.gf_place_artwork3(uuid, text, text, text, text, real, text, real, real, real, real, real, jsonb, text, text) from public, anon;
grant execute on function public.gf_place_artwork3(uuid, text, text, text, text, real, text, real, real, real, real, real, jsonb, text, text) to authenticated;
