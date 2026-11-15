-- 0020：近くにある友達のグラフィティカード（地図の別タブ。1 枚ずつ画面いっぱいに出して、スワイプで見ていく）。
-- 何度実行しても大丈夫な書き方（run.sh が 2 回流して確かめる）。
-- ここで作り直した関数（あとで足すときは、ここ以降で作り直す）：gf_can_read_media・gf_save_card。
--
-- 決まり（オーナー 2026-11-15）：
--  - 出すのは、お互いにフォローの友達のカードで、そのカードの GATE がいまいる所から 300m 以内のもの。
--  - 「この GATE の中だけ」のカード・自分だけのカード・見えない GATE のカードは出さない。
--  - 近くにいるあいだは、カードのひとことも読める（遠くからの図鑑では、ひとことは現地だけのまま）。
--  - GATE の場所はおおよそ（小数 3 けた）。そこまでの道案内は、おおよその場所まで。中の記憶は現地で扉を開けた人だけ。
--  - 見せたカードには 30 分の「近くの券」を出し、そのあいだだけ写真の受け取り・お気に入りができる。

insert into public.gf_settings (key, value, note) values
  ('nearby_cards_radius_m', 300, '近くにある友達のカードを出す広さ（m）'),
  ('nearby_cards_accuracy_m', 80, '近くの友達のカードを探すときの、位置の確かさの上限（m）'),
  ('nearby_cards_per_10min', 30, '10 分に近くの友達のカードを探せる回数（1 人）'),
  ('nearby_card_pass_minutes', 30, '近くで見たカードの写真・お気に入りを使える時間（分）')
on conflict (key) do nothing;

-- 見せたカードの「近くの券」（写真の受け取り・お気に入りに使う）
create table if not exists public.gf_card_nearby_passes (
  user_id uuid not null references public.profiles(id) on delete cascade,
  graffiti_id uuid not null references public.gf_graffiti(id) on delete cascade,
  expires_at timestamptz not null,
  primary key (user_id, graffiti_id)
);
create index if not exists gf_card_nearby_passes_card on public.gf_card_nearby_passes(graffiti_id);
alter table public.gf_card_nearby_passes enable row level security;
-- 表は直接読ませない

-- 近くの券があって、いまもそのカードを見せてよいか（公開範囲・ブロック・現地だけ・GATE が見えるかは毎回決め直す）
create or replace function public.gf_nearby_card_visible(x public.gf_graffiti, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and x.deleted_at is null and x.author <> viewer and not x.local_only
    and x.visibility in ('public', 'friends')
    and gf_mutual(viewer, x.author) and not gf_blocked(viewer, x.author)
    and exists (select 1 from gf_card_nearby_passes p
                where p.user_id = viewer and p.graffiti_id = x.id and p.expires_at > now())
    and exists (select 1 from gf_gates g where g.id = x.gate_id and gf_can_see_gate(g, viewer))
$$;

create or replace function public.gf_nearby_cards(p_lat double precision, p_lon double precision, p_accuracy real)
returns table (id uuid, gate_id uuid, gate_title text, gate_kind text, author uuid, author_name text, body text,
               photo_path text, created_at timestamptz, approx_lat double precision, approx_lon double precision,
               distance_m double precision)
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r double precision := gf_setting('nearby_cards_radius_m');
  rec record;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if not gf_valid_position(p_lat, p_lon) then raise exception 'gf_bad_position' using errcode = 'P0001'; end if;
  if p_accuracy is null or p_accuracy < 0 or p_accuracy > gf_setting('nearby_cards_accuracy_m') then
    raise exception 'gf_inaccurate' using errcode = 'P0001';
  end if;
  perform gf_take_rate('nearby_cards', gf_setting('nearby_cards_per_10min'), 600);

  -- 古い券は片づける
  delete from gf_card_nearby_passes c where c.user_id = me and c.expires_at < now() - interval '1 day';
  for rec in
    select x.id as cid, g.id as gid, g.title as gtitle, g.kind as gkind, x.author as aid, p.display_name as aname,
           x.body as abody, x.photo_path as ppath, x.created_at as cat,
           round(g.lat::numeric, 3)::double precision as alat, round(g.lon::numeric, 3)::double precision as alon
    from gf_graffiti x
    join gf_gates g on g.id = x.gate_id
    join profiles p on p.id = x.author
    where x.deleted_at is null and x.author <> me and not x.local_only and x.visibility in ('public', 'friends')
      and g.lat between p_lat - r / 111000.0 and p_lat + r / 111000.0
      and gf_distance_m(p_lat, p_lon, g.lat, g.lon) <= r
      and gf_mutual(me, x.author) and not gf_blocked(me, x.author) and gf_can_see_gate(g, me)
    order by gf_distance_m(p_lat, p_lon, g.lat, g.lon), x.created_at desc
    limit 40
  loop
    insert into gf_card_nearby_passes (user_id, graffiti_id, expires_at)
    values (me, rec.cid, now() + make_interval(mins => gf_setting('nearby_card_pass_minutes')::int))
    on conflict (user_id, graffiti_id) do update set expires_at = excluded.expires_at;
    id := rec.cid; gate_id := rec.gid; gate_title := rec.gtitle; gate_kind := rec.gkind;
    author := rec.aid; author_name := rec.aname; body := rec.abody; photo_path := rec.ppath; created_at := rec.cat;
    approx_lat := rec.alat; approx_lon := rec.alon;
    -- 距離はおおよその場所から（正確な位置を、距離の数字から割り出されないように）
    distance_m := gf_distance_m(p_lat, p_lon, rec.alat, rec.alon);
    return next;
  end loop;
end $$;

-- ============ お気に入り（GATE の中のほか、近くで見たカードにも付けられる） ============
create or replace function public.gf_save_card(p_card uuid, p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  x public.gf_graffiti;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if coalesce(p_on, false) then
    select * into x from gf_graffiti g where g.id = p_card;
    if x.id is null or not (gf_can_see_graffiti(x, me) or gf_nearby_card_visible(x, me)) then
      raise exception 'gf_not_found' using errcode = 'P0001';
    end if;
    if (select count(*) from gf_card_saves s where s.user_id = me) >= 1000 then
      raise exception 'gf_too_many' using errcode = 'P0001';
    end if;
    insert into gf_card_saves (user_id, graffiti_id) values (me, p_card) on conflict do nothing;
    return true;
  end if;
  delete from gf_card_saves s where s.user_id = me and s.graffiti_id = p_card;
  return false;
end $$;

-- ============ 写真を見てよいか（ここまでの全部。近くで見たカードの写真を足す） ============
create or replace function public.gf_can_read_media(p_path text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    split_part(p_path, '/', 1) = auth.uid()::text
    or exists (select 1 from gf_gates g where g.cover_path = p_path and gf_can_see_gate(g, auth.uid()))
    or exists (select 1 from gf_graffiti x where x.photo_path = p_path
               and (gf_can_see_graffiti(x, auth.uid()) or gf_feed_visible(x, auth.uid())
                    or gf_atlas_card_visible(x, auth.uid()) or gf_saved_card_visible(x, auth.uid())
                    or gf_nearby_card_visible(x, auth.uid())))
    or exists (select 1 from gf_card_links l join gf_graffiti x on x.id = l.from_card
               where x.photo_path = p_path and x.deleted_at is null
                 and l.recipient = auth.uid() and not gf_blocked(l.sender, l.recipient))
    or exists (select 1 from gf_artworks a where (a.photo_path = p_path or a.thumb_path = p_path)
               and gf_can_see_artwork(a, auth.uid()))
    or exists (select 1 from gf_letters l where l.photo_path = p_path and l.recipient = auth.uid()
               and l.opened_at is not null and not gf_blocked(l.author, l.recipient))
    or exists (select 1 from gf_memory_items i join gf_memories m on m.id = i.memory_id
               where (i.photo_path = p_path or i.thumb_path = p_path)
                 and gf_can_see_memory(m, auth.uid()) and not gf_blocked(auth.uid(), i.author))
    or exists (select 1 from gf_snapshots s where s.photo_path = p_path and gf_can_see_snapshot(s, auth.uid()))
    or exists (select 1 from gf_dm_messages d where d.photo_path = p_path and d.deleted_at is null
               and (d.sender = auth.uid() or d.recipient = auth.uid()) and not gf_blocked(d.sender, d.recipient)))
$$;

-- 通報：近くで見たカードも通報できるように（gf_report の 'graffiti' は、見えるカードだけを受け付ける）
create or replace function public.gf_report_nearby_card(p_id uuid, p_reason text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  x public.gf_graffiti;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into x from gf_graffiti g where g.id = p_id;
  if x.id is null or not gf_nearby_card_visible(x, me) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  perform gf_take_rate('report', gf_setting('reports_per_day'), 86400);
  begin
    insert into gf_reports (reporter, target_kind, target_id, target_user, reason, note, snapshot)
    values (me, 'graffiti', x.id, x.author, p_reason, nullif(btrim(coalesce(p_note, '')), ''), left(x.body, 500));
  exception when check_violation then
    raise exception 'gf_bad_report' using errcode = 'P0001';
  end;
end $$;

-- ============ 呼べる関数を絞る ============
revoke all on function public.gf_nearby_card_visible(public.gf_graffiti, uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'gf_nearby_cards(double precision, double precision, real)', 'gf_save_card(uuid, boolean)',
    'gf_can_read_media(text)', 'gf_report_nearby_card(uuid, text, text)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
