-- GRAFITYGATE のサーバーの準備（migrations をすべて番号の順につないだもの）。
-- Supabase の SQL Editor に全部貼って Run。何度実行しても大丈夫。
-- このファイルは tools/make_setup_sql.sh で作る（直接書き換えない）。

-- ======================================================================
-- 0001_gf_core.sql
-- ======================================================================
-- GRAFITYGATE 段階1：GATE を作る・見つける・入る・グラフィティを残す
--
-- 使い方：Supabase の SQL Editor に、このファイルの中身をそのまま貼って実行する。
-- 何度実行しても大丈夫（作り直し・if not exists）。
-- 前提：Lyric Path と同じ Supabase プロジェクト。共通の表 profiles・follows と、ブロックの表 lp_blocks があること。
--
-- 守るルール（旧 GRAFFOOT の決定。数値は gf_settings にあり、現場のデータを見てから変える）
--   発見は 100m 以内 / 入場は 120m 以内・位置の精度 35m 以内・合言葉は 90 秒で 1 回だけ / 入場券は 20 分
--   1 回の入場で新しいグラフィティは 1 枚 / 同じ人が同じ GATE に書けるのは 12 時間あけてから / 友達の新着は 24 時間
--   GPS だけでも写真だけでも入れない（位置と、写真の特徴の一致の両方が要る）
--   「友達」はお互いにフォローしている人（v0.7 と同じ）。ブロックはどちらからでも、すぐに効く。
--
-- 判定はすべてサーバーで行う。アプリから表を直接読めるのは、自分の GATE と、見てよいグラフィティ・反応だけ。
-- GATE の正確な位置・参照写真の特徴・合言葉・入場券は、下の関数を通してしか触れない。

-- ============ 設定 ============
create table if not exists public.gf_settings (
  key text primary key,
  value double precision not null,
  note text not null default ''
);
alter table public.gf_settings enable row level security;

insert into public.gf_settings (key, value, note) values
  ('discover_radius_m', 100, '発見の範囲（m）'),
  ('enter_radius_m', 120, '入場できる距離（m）'),
  ('max_accuracy_m', 35, '位置の精度がこれより悪いと、作成・入場できない（m）'),
  ('challenge_seconds', 90, '合言葉の有効時間（秒）'),
  ('visit_minutes', 20, '入場券の有効時間（分）'),
  ('repost_hours', 12, '同じ人が同じ GATE に次のグラフィティを書けるまで（時間）'),
  ('feed_hours', 24, '友達の新着に出る時間（時間）'),
  ('match_max_distance', 0.75, '写真の特徴の距離がこれ以下なら同じ対象とみなす（仮の値。現場の記録 gf_enter_attempts を見て決め直す）'),
  ('match_weak_distance', 1.0, '候補として「似ている」と見せる距離'),
  ('gates_per_day', 20, '1 日に作れる GATE の数'),
  ('graffiti_per_day', 10, '1 日に書けるグラフィティの数'),
  ('challenges_per_10min', 30, '10 分に出せる合言葉の数'),
  ('discover_per_10min', 120, '10 分に周りの GATE を探せる回数')
on conflict (key) do nothing;

create or replace function public.gf_setting(k text) returns double precision
language sql stable security definer set search_path = public as $$
  select value from gf_settings where key = k
$$;

-- ============ 計算 ============
create or replace function public.gf_valid_position(lat double precision, lon double precision) returns boolean
language sql immutable as $$
  -- NaN は PostgreSQL ではどの数より大きいので、範囲の確認で外れる
  select lat is not null and lon is not null and lat between -90 and 90 and lon between -180 and 180
$$;

create or replace function public.gf_distance_m(lat1 double precision, lon1 double precision,
                                                lat2 double precision, lon2 double precision)
returns double precision language sql immutable as $$
  select 2 * 6371008.8 * asin(least(1, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2))))
$$;

-- 写真の特徴（Apple の Vision が作る数の並び）どうしの距離。小さいほど似ている。長さが違えば比べない。
create or replace function public.gf_print_distance(a real[], b real[]) returns double precision
language sql immutable as $$
  select case
    when a is null or b is null or cardinality(a) = 0 or cardinality(a) <> cardinality(b) then null
    else (select sqrt(sum(power((x - y)::double precision, 2))) from unnest(a, b) as t(x, y))
  end
$$;

-- ============ 人と人の関係（Lyric Path と共通の表を読む） ============
create or replace function public.gf_blocked(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from lp_blocks where (blocker = a and blocked = b) or (blocker = b and blocked = a))
$$;

create or replace function public.gf_mutual(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from follows where follower = a and followee = b)
     and exists (select 1 from follows where follower = b and followee = a)
$$;

-- ============ 回数の上限 ============
create table if not exists public.gf_rate (
  user_id uuid not null references public.profiles(id) on delete cascade,
  action text not null,
  at timestamptz not null default now()
);
create index if not exists gf_rate_lookup on public.gf_rate(user_id, action, at);
alter table public.gf_rate enable row level security;

create or replace function public.gf_take_rate(p_action text, p_max double precision, p_seconds int) returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform pg_advisory_xact_lock(hashtext('gf_rate:' || auth.uid()::text || ':' || p_action));
  delete from gf_rate where user_id = auth.uid() and action = p_action
    and at < now() - make_interval(secs => p_seconds);
  select count(*) into n from gf_rate where user_id = auth.uid() and action = p_action;
  if n >= p_max then
    raise exception 'gf_rate_limited' using errcode = 'P0001', detail = p_action;
  end if;
  insert into gf_rate (user_id, action) values (auth.uid(), p_action);
end $$;

-- ============ GATE ============
create table if not exists public.gf_gates (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references public.profiles(id) on delete cascade,
  client_key text not null check (char_length(client_key) between 8 and 64),
  title text not null check (char_length(btrim(title)) between 1 and 60),
  note text not null default '' check (char_length(note) <= 400),
  kind text not null check (kind in ('place', 'object')),
  lat double precision not null check (lat between -90 and 90),
  lon double precision not null check (lon between -180 and 180),
  accuracy_m real not null check (accuracy_m >= 0),
  heading real check (heading >= 0 and heading < 360),
  visibility text not null default 'friends' check (visibility in ('private', 'friends', 'public')),
  cover_path text,
  status text not null default 'open' check (status in ('open', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner, client_key)
);
create index if not exists gf_gates_latlon on public.gf_gates(lat, lon);
create index if not exists gf_gates_owner on public.gf_gates(owner);
create index if not exists gf_gates_cover on public.gf_gates(cover_path);
alter table public.gf_gates enable row level security;

-- GATE を見分けるための参照写真の特徴。アプリには返さない（比べるのはサーバー）。
create table if not exists public.gf_gate_refs (
  id uuid primary key default gen_random_uuid(),
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  print real[] not null check (cardinality(print) between 16 and 4096),
  print_rev int not null,
  photo_path text,
  created_at timestamptz not null default now()
);
create index if not exists gf_gate_refs_gate on public.gf_gate_refs(gate_id);
alter table public.gf_gate_refs enable row level security;

-- GATE を見てよいか（概要まで）。持ち主はいつでも。閉じた GATE・ブロックの相手には見せない。
create or replace function public.gf_can_see_gate(g public.gf_gates, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and (
    g.owner = viewer or (
      g.status = 'open'
      and not gf_blocked(viewer, g.owner)
      and (g.visibility = 'public' or (g.visibility = 'friends' and gf_mutual(viewer, g.owner)))))
$$;

-- 自分の GATE だけは表から直接読める（正確な位置を含むため、ほかの人には関数で概要だけ返す）
drop policy if exists "gf gates own read" on public.gf_gates;
create policy "gf gates own read" on public.gf_gates for select to authenticated using (owner = auth.uid());
drop policy if exists "gf gates own delete" on public.gf_gates;
create policy "gf gates own delete" on public.gf_gates for delete to authenticated using (owner = auth.uid());

-- ============ 合言葉と入場券 ============
create table if not exists public.gf_challenges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz
);
create index if not exists gf_challenges_user on public.gf_challenges(user_id, created_at);
alter table public.gf_challenges enable row level security;

create table if not exists public.gf_visits (
  id uuid primary key default gen_random_uuid(),
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  challenge_id uuid not null unique references public.gf_challenges(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  distance_m real not null,
  accuracy_m real not null,
  match_distance real not null
);
create index if not exists gf_visits_user_gate on public.gf_visits(user_id, gate_id, expires_at);
alter table public.gf_visits enable row level security;

-- 入場の試みの記録（合わなかったときも残す）。写真の特徴の距離のしきい値を、現場のデータで決め直すため。
-- 位置そのものは残さない（GATE からの距離だけ）。
create table if not exists public.gf_enter_attempts (
  id bigserial primary key,
  gate_id uuid references public.gf_gates(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  result text not null,
  distance_m real,
  accuracy_m real,
  match_distance real,
  print_rev int
);
alter table public.gf_enter_attempts enable row level security;

-- いま有効な入場券（見てよい GATE で、期限内・取り消されていない）
create or replace function public.gf_active_visit(p_gate uuid, viewer uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select v.id
  from gf_visits v join gf_gates g on g.id = v.gate_id
  where v.gate_id = p_gate and v.user_id = viewer and v.revoked_at is null and v.expires_at > now()
    and gf_can_see_gate(g, viewer)
  order by v.expires_at desc
  limit 1
$$;

-- ============ グラフィティ ============
create table if not exists public.gf_graffiti (
  id uuid primary key default gen_random_uuid(),
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  author uuid not null references public.profiles(id) on delete cascade,
  visit_id uuid unique references public.gf_visits(id) on delete set null,
  body text not null default '' check (char_length(body) <= 280),
  photo_path text,
  visibility text not null default 'friends' check (visibility in ('private', 'friends', 'public')),
  local_only boolean not null default false,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (char_length(btrim(body)) > 0 or photo_path is not null)
);
create index if not exists gf_graffiti_gate on public.gf_graffiti(gate_id, created_at desc);
create index if not exists gf_graffiti_author on public.gf_graffiti(author, gate_id, created_at desc);
create index if not exists gf_graffiti_photo on public.gf_graffiti(photo_path);
alter table public.gf_graffiti enable row level security;

-- 現地でグラフィティを見てよいか：書いた本人はいつでも。ほかの人は、その GATE の有効な入場券と公開範囲が要る。
create or replace function public.gf_can_see_graffiti(p public.gf_graffiti, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and p.deleted_at is null and (
    p.author = viewer or (
      not gf_blocked(viewer, p.author)
      and gf_active_visit(p.gate_id, viewer) is not null
      and (p.visibility = 'public' or (p.visibility = 'friends' and gf_mutual(viewer, p.author)))))
$$;

-- 友達の新着（24 時間）に出してよいか：フォローしている人の、現地だけでないカード。GATE も見てよいこと。
create or replace function public.gf_feed_visible(p public.gf_graffiti, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and p.author <> viewer and p.deleted_at is null and not p.local_only
    and p.created_at > now() - make_interval(hours => gf_setting('feed_hours')::int)
    and exists (select 1 from follows where follower = viewer and followee = p.author)
    and not gf_blocked(viewer, p.author)
    and (p.visibility = 'public' or (p.visibility = 'friends' and gf_mutual(viewer, p.author)))
    and exists (select 1 from gf_gates g where g.id = p.gate_id and gf_can_see_gate(g, viewer))
$$;

drop policy if exists "gf graffiti read" on public.gf_graffiti;
create policy "gf graffiti read" on public.gf_graffiti for select to authenticated
  using (public.gf_can_see_graffiti(gf_graffiti, auth.uid()));

-- ============ 反応 ============
create table if not exists public.gf_reactions (
  graffiti_id uuid not null references public.gf_graffiti(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'like' check (kind in ('like')),
  created_at timestamptz not null default now(),
  primary key (graffiti_id, user_id, kind)
);
alter table public.gf_reactions enable row level security;
-- 見えるグラフィティへの反応だけ（中の select は gf_graffiti の権限がそのまま効く）
drop policy if exists "gf reactions read" on public.gf_reactions;
create policy "gf reactions read" on public.gf_reactions for select to authenticated
  using (exists (select 1 from public.gf_graffiti g where g.id = graffiti_id));
drop policy if exists "gf reactions insert" on public.gf_reactions;
create policy "gf reactions insert" on public.gf_reactions for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from public.gf_graffiti g where g.id = graffiti_id));
drop policy if exists "gf reactions delete" on public.gf_reactions;
create policy "gf reactions delete" on public.gf_reactions for delete to authenticated using (user_id = auth.uid());

-- ============ アプリから呼ぶ関数 ============

-- 合言葉を出す（入場・作成のたびに 1 つ。90 秒で切れ、1 回だけ使える）
create or replace function public.gf_request_challenge()
returns table (challenge_id uuid, expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare c gf_challenges;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  perform gf_take_rate('challenge', gf_setting('challenges_per_10min'), 600);
  delete from gf_challenges where user_id = auth.uid() and gf_challenges.expires_at < now() - interval '1 day';
  insert into gf_challenges (user_id, expires_at)
    values (auth.uid(), now() + make_interval(secs => gf_setting('challenge_seconds')))
    returning * into c;
  return query select c.id, c.expires_at;
end $$;

-- 合言葉を使う（本人のもので、まだ使っておらず、期限内なら使ったことにする）。だめなら理由を返す。
create or replace function public.gf_use_challenge(p_challenge uuid) returns text
language plpgsql security definer set search_path = public as $$
declare c gf_challenges;
begin
  select * into c from gf_challenges where id = p_challenge and user_id = auth.uid() for update;
  if not found then return 'challenge_invalid'; end if;
  if c.used_at is not null then return 'challenge_used'; end if;
  update gf_challenges set used_at = now() where id = c.id;
  if c.expires_at <= now() then return 'challenge_expired'; end if;
  return null;
end $$;

-- 周りの GATE（100m 以内で、見てよいもの）。位置は 4 けたに丸める（約 10m）。
create or replace function public.gf_discover(p_lat double precision, p_lon double precision)
returns table (id uuid, title text, kind text, owner uuid, owner_name text, distance_m real,
               approx_lat double precision, approx_lon double precision, cover_path text,
               visibility text, mine boolean)
language plpgsql stable security definer set search_path = public as $$
declare r double precision := gf_setting('discover_radius_m');
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if not gf_valid_position(p_lat, p_lon) then raise exception 'gf_bad_position' using errcode = 'P0001'; end if;
  return query
    select g.id, g.title, g.kind, g.owner, p.display_name,
           gf_distance_m(p_lat, p_lon, g.lat, g.lon)::real,
           round(g.lat::numeric, 4)::double precision, round(g.lon::numeric, 4)::double precision,
           g.cover_path, g.visibility, g.owner = auth.uid()
    from gf_gates g join profiles p on p.id = g.owner
    where g.lat between p_lat - r / 110000.0 * 1.1 and p_lat + r / 110000.0 * 1.1
      and g.lon between p_lon - r / (110000.0 * greatest(cos(radians(p_lat)), 0.01)) * 1.1
                    and p_lon + r / (110000.0 * greatest(cos(radians(p_lat)), 0.01)) * 1.1
      and gf_distance_m(p_lat, p_lon, g.lat, g.lon) <= r
      and gf_can_see_gate(g, auth.uid())
    order by 6;
end $$;

-- 発見の回数を数える版（アプリはこちらを呼ぶ。stable の関数の中では書き込めないので分けている）
create or replace function public.gf_discover_nearby(p_lat double precision, p_lon double precision)
returns table (id uuid, title text, kind text, owner uuid, owner_name text, distance_m real,
               approx_lat double precision, approx_lon double precision, cover_path text,
               visibility text, mine boolean)
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  perform gf_take_rate('discover', gf_setting('discover_per_10min'), 600);
  return query select * from gf_discover(p_lat, p_lon);
end $$;

-- 写真の特徴が近い、周りの GATE の候補（作る前の重なりの確認・入る GATE を選ぶため）。
-- 距離の数字は返さない（数字を手がかりに、合う特徴を探られないようにするため）。
create or replace function public.gf_match_candidates(p_lat double precision, p_lon double precision,
                                                      p_print real[], p_print_rev int)
returns table (id uuid, title text, owner_name text, distance_m real, cover_path text, similarity text)
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  perform gf_take_rate('discover', gf_setting('discover_per_10min'), 600);
  return query
    with near as (select * from gf_discover(p_lat, p_lon)),
         best as (
           select n.id, min(gf_print_distance(p_print, r.print)) as d
           from near n left join gf_gate_refs r on r.gate_id = n.id and r.print_rev = p_print_rev
           group by n.id)
    select n.id, n.title, n.owner_name, n.distance_m, n.cover_path,
           case when b.d is null then 'unknown'
                when b.d <= gf_setting('match_max_distance') then 'strong'
                when b.d <= gf_setting('match_weak_distance') then 'weak'
                else 'none' end
    from near n join best b on b.id = n.id
    order by b.d nulls last, n.distance_m;
end $$;

-- GATE を作る。同じ client_key で送り直しても 1 つしかできない（作ったものの ID を返す）。
-- p_refs：[{"print":[数...], "rev":2, "photo_path":"<自分のID>/..."}]（1〜8 個）
create or replace function public.gf_create_gate(
  p_client_key text, p_challenge uuid, p_title text, p_note text, p_kind text,
  p_lat double precision, p_lon double precision, p_accuracy real, p_heading real,
  p_visibility text, p_cover_path text, p_refs jsonb)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  existing uuid;
  why text;
  gid uuid;
  ref jsonb;
  pr real[];
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select id into existing from gf_gates where owner = me and client_key = p_client_key;
  if existing is not null then return existing; end if;

  why := gf_use_challenge(p_challenge);
  if why is not null then raise exception 'gf_%', why using errcode = 'P0001'; end if;
  if not gf_valid_position(p_lat, p_lon) then raise exception 'gf_bad_position' using errcode = 'P0001'; end if;
  if p_accuracy is null or p_accuracy < 0 or p_accuracy > gf_setting('max_accuracy_m') then
    raise exception 'gf_inaccurate' using errcode = 'P0001';
  end if;
  if p_refs is null or jsonb_typeof(p_refs) <> 'array' or jsonb_array_length(p_refs) not between 1 and 8 then
    raise exception 'gf_bad_references' using errcode = 'P0001';
  end if;
  if p_cover_path is not null and split_part(p_cover_path, '/', 1) <> me::text then
    raise exception 'gf_bad_media_path' using errcode = 'P0001';
  end if;
  perform gf_take_rate('gate_create', gf_setting('gates_per_day'), 86400);

  insert into gf_gates (owner, client_key, title, note, kind, lat, lon, accuracy_m, heading, visibility, cover_path)
  values (me, p_client_key, btrim(p_title), coalesce(p_note, ''), p_kind, p_lat, p_lon, p_accuracy,
          p_heading, coalesce(p_visibility, 'friends'), p_cover_path)
  returning id into gid;

  for ref in select * from jsonb_array_elements(p_refs) loop
    if jsonb_typeof(ref -> 'print') <> 'array' or (ref ->> 'rev') is null then
      raise exception 'gf_bad_references' using errcode = 'P0001';
    end if;
    if (ref ->> 'photo_path') is not null and split_part(ref ->> 'photo_path', '/', 1) <> me::text then
      raise exception 'gf_bad_media_path' using errcode = 'P0001';
    end if;
    select array_agg(x::real) into pr from jsonb_array_elements_text(ref -> 'print') as t(x);
    insert into gf_gate_refs (gate_id, print, print_rev, photo_path)
      values (gid, pr, (ref ->> 'rev')::int, ref ->> 'photo_path');
  end loop;
  return gid;
end $$;

-- GATE に入る。合言葉・位置（120m・精度）・写真の特徴の一致がそろえば、20 分の入場券を出す。
-- 合わなかった理由も返す（例外にしないのは、試みの記録を残すため）。合言葉は合否にかかわらず使ったことになる。
-- 返す値：{"ok":true,"visit_id":…,"expires_at":…} か {"ok":false,"reason":"too_far"} など
create or replace function public.gf_enter(
  p_gate uuid, p_challenge uuid, p_lat double precision, p_lon double precision, p_accuracy real,
  p_print real[], p_print_rev int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  why text;
  g gf_gates;
  dist double precision;
  best double precision;
  vid uuid;
  vexp timestamptz;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;

  why := gf_use_challenge(p_challenge);
  if why is null then
    select * into g from gf_gates where id = p_gate;
    -- 見てはいけない GATE は「ない」ものとして扱う（あるかどうかも知らせない）
    if not found or not gf_can_see_gate(g, me) then
      why := 'not_found';
    elsif not gf_valid_position(p_lat, p_lon) then
      why := 'bad_position';
    elsif p_accuracy is null or p_accuracy < 0 or p_accuracy > gf_setting('max_accuracy_m') then
      why := 'inaccurate';
    else
      dist := gf_distance_m(p_lat, p_lon, g.lat, g.lon);
      if dist > gf_setting('enter_radius_m') then
        why := 'too_far';
      else
        select min(gf_print_distance(p_print, r.print)) into best
        from gf_gate_refs r where r.gate_id = g.id and r.print_rev = p_print_rev;
        if best is null then
          why := 'no_reference';
        elsif best > gf_setting('match_max_distance') then
          why := 'no_match';
        end if;
      end if;
    end if;
  end if;

  insert into gf_enter_attempts (gate_id, user_id, result, distance_m, accuracy_m, match_distance, print_rev)
  values (case when why = 'not_found' or g.id is null then null else g.id end, me,
          coalesce(why, 'ok'), dist, p_accuracy, best, p_print_rev);

  if why is not null then
    return jsonb_build_object('ok', false, 'reason', why);
  end if;

  insert into gf_visits (gate_id, user_id, challenge_id, expires_at, distance_m, accuracy_m, match_distance)
  values (g.id, me, p_challenge, now() + make_interval(mins => gf_setting('visit_minutes')::int),
          dist, p_accuracy, best)
  returning id, expires_at into vid, vexp;
  return jsonb_build_object('ok', true, 'visit_id', vid, 'expires_at', vexp);
end $$;

-- 入場中のグラフィティを書く。1 回の入場で 1 枚、同じ GATE は 12 時間あけてから。
create or replace function public.gf_post_graffiti(
  p_visit uuid, p_body text, p_photo_path text, p_visibility text, p_local_only boolean)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v gf_visits;
  g gf_gates;
  pid uuid;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into v from gf_visits where id = p_visit and user_id = me;
  if not found or v.revoked_at is not null or v.expires_at <= now() then
    raise exception 'gf_visit_invalid' using errcode = 'P0001';
  end if;
  -- 同じ GATE への書き込みは 1 つずつ（同時に送っても 1 枚だけになるように、GATE の行を押さえる）
  select * into g from gf_gates where id = v.gate_id for update;
  if not found or not gf_can_see_gate(g, me) then
    raise exception 'gf_visit_invalid' using errcode = 'P0001';
  end if;
  if exists (select 1 from gf_graffiti where visit_id = p_visit) then
    raise exception 'gf_already_posted' using errcode = 'P0001';
  end if;
  if exists (select 1 from gf_graffiti where author = me and gate_id = g.id
             and created_at > now() - make_interval(hours => gf_setting('repost_hours')::int)) then
    raise exception 'gf_repost_cooldown' using errcode = 'P0001';
  end if;
  if p_photo_path is not null and split_part(p_photo_path, '/', 1) <> me::text then
    raise exception 'gf_bad_media_path' using errcode = 'P0001';
  end if;
  perform gf_take_rate('graffiti', gf_setting('graffiti_per_day'), 86400);
  insert into gf_graffiti (gate_id, author, visit_id, body, photo_path, visibility, local_only)
  values (g.id, me, p_visit, coalesce(p_body, ''), p_photo_path, coalesce(p_visibility, 'friends'),
          coalesce(p_local_only, false))
  returning id into pid;
  return pid;
end $$;

-- 自分のグラフィティを消す（フィード・GATE・写真の URL からも見えなくなる）
create or replace function public.gf_delete_graffiti(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_graffiti set deleted_at = now() where id = p_id and author = auth.uid() and deleted_at is null;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- 自分の GATE の名前・説明・公開範囲・開閉を変える（null は変えない）
create or replace function public.gf_update_gate(p_gate uuid, p_title text, p_note text,
                                                 p_visibility text, p_status text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_gates set
    title = coalesce(btrim(p_title), title),
    note = coalesce(p_note, note),
    visibility = coalesce(p_visibility, visibility),
    status = coalesce(p_status, status),
    updated_at = now()
  where id = p_gate and owner = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- GATE の概要（遠くからでも見てよい範囲：名前・作った人・表紙・おおよその位置・記録の数・自分の入場券）
-- 位置は 3 けたに丸める（約 100m）。中の記録は返さない。
create or replace function public.gf_gate_summary(p_gate uuid)
returns table (id uuid, title text, note text, kind text, owner uuid, owner_name text, cover_path text,
               approx_lat double precision, approx_lon double precision, visibility text, status text,
               graffiti_count bigint, created_at timestamptz, my_visit uuid, my_visit_expires_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select g.id, g.title, g.note, g.kind, g.owner, p.display_name, g.cover_path,
           round(g.lat::numeric, 3)::double precision, round(g.lon::numeric, 3)::double precision,
           g.visibility, g.status,
           (select count(*) from gf_graffiti x where x.gate_id = g.id and x.deleted_at is null),
           g.created_at, v.id, v.expires_at
    from gf_gates g
    join profiles p on p.id = g.owner
    left join lateral (
      select vv.id, vv.expires_at from gf_visits vv
      where vv.gate_id = g.id and vv.user_id = auth.uid() and vv.revoked_at is null and vv.expires_at > now()
      order by vv.expires_at desc limit 1) v on true
    where g.id = p_gate and gf_can_see_gate(g, auth.uid());
end $$;

-- 友達の新着（24 時間）。現地だけのカードは出さない。位置は 3 けた（約 100m）に丸める。
create or replace function public.gf_friend_feed()
returns table (id uuid, author uuid, author_name text, gate_id uuid, gate_title text,
               approx_lat double precision, approx_lon double precision,
               body text, photo_path text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select x.id, x.author, p.display_name, g.id, g.title,
           round(g.lat::numeric, 3)::double precision, round(g.lon::numeric, 3)::double precision,
           x.body, x.photo_path, x.created_at
    from gf_graffiti x
    join gf_gates g on g.id = x.gate_id
    join profiles p on p.id = x.author
    where gf_feed_visible(x, auth.uid())
    order by x.created_at desc
    limit 200;
end $$;

-- ============ 写真の置き場所 ============
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('gf-media', 'gf-media', false, 10485760, array['image/jpeg', 'image/heic', 'image/png'])
on conflict (id) do nothing;

-- 写真を見てよいか：自分のフォルダ／見てよい GATE の表紙／見てよいグラフィティ（現地 or 友達の新着）
-- 参照写真は持ち主だけ（自分のフォルダの決まりで足りる）
create or replace function public.gf_can_read_media(p_path text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    split_part(p_path, '/', 1) = auth.uid()::text
    or exists (select 1 from gf_gates g where g.cover_path = p_path and gf_can_see_gate(g, auth.uid()))
    or exists (select 1 from gf_graffiti x where x.photo_path = p_path
               and (gf_can_see_graffiti(x, auth.uid()) or gf_feed_visible(x, auth.uid()))))
$$;

drop policy if exists "gf media read" on storage.objects;
create policy "gf media read" on storage.objects for select to authenticated
  using (bucket_id = 'gf-media' and public.gf_can_read_media(name));
drop policy if exists "gf media insert" on storage.objects;
create policy "gf media insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'gf-media' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "gf media delete" on storage.objects;
create policy "gf media delete" on storage.objects for delete to authenticated
  using (bucket_id = 'gf-media' and (storage.foldername(name))[1] = auth.uid()::text);

-- ============ 呼べる関数を絞る ============
-- 中だけで使う関数は、アプリから直接呼ばせない
revoke all on function public.gf_setting(text) from public, anon, authenticated;
revoke all on function public.gf_take_rate(text, double precision, int) from public, anon, authenticated;
revoke all on function public.gf_use_challenge(uuid) from public, anon, authenticated;
revoke all on function public.gf_discover(double precision, double precision) from public, anon, authenticated;
revoke all on function public.gf_active_visit(uuid, uuid) from public, anon, authenticated;

-- 行の権限（RLS）の中で使う関数は、ログインした人なら呼べる必要がある
revoke all on function public.gf_can_see_gate(public.gf_gates, uuid) from public, anon;
revoke all on function public.gf_can_see_graffiti(public.gf_graffiti, uuid) from public, anon;
revoke all on function public.gf_feed_visible(public.gf_graffiti, uuid) from public, anon;
revoke all on function public.gf_can_read_media(text) from public, anon;
revoke all on function public.gf_blocked(uuid, uuid) from public, anon;
revoke all on function public.gf_mutual(uuid, uuid) from public, anon;
grant execute on function public.gf_can_see_gate(public.gf_gates, uuid) to authenticated;
grant execute on function public.gf_can_see_graffiti(public.gf_graffiti, uuid) to authenticated;
grant execute on function public.gf_feed_visible(public.gf_graffiti, uuid) to authenticated;
grant execute on function public.gf_can_read_media(text) to authenticated;
grant execute on function public.gf_blocked(uuid, uuid) to authenticated;
grant execute on function public.gf_mutual(uuid, uuid) to authenticated;

-- アプリから呼ぶ関数
revoke all on function public.gf_request_challenge() from public, anon;
revoke all on function public.gf_discover_nearby(double precision, double precision) from public, anon;
revoke all on function public.gf_match_candidates(double precision, double precision, real[], int) from public, anon;
revoke all on function public.gf_create_gate(text, uuid, text, text, text, double precision, double precision, real, real, text, text, jsonb) from public, anon;
revoke all on function public.gf_enter(uuid, uuid, double precision, double precision, real, real[], int) from public, anon;
revoke all on function public.gf_post_graffiti(uuid, text, text, text, boolean) from public, anon;
revoke all on function public.gf_delete_graffiti(uuid) from public, anon;
revoke all on function public.gf_update_gate(uuid, text, text, text, text) from public, anon;
revoke all on function public.gf_gate_summary(uuid) from public, anon;
revoke all on function public.gf_friend_feed() from public, anon;
grant execute on function public.gf_request_challenge() to authenticated;
grant execute on function public.gf_discover_nearby(double precision, double precision) to authenticated;
grant execute on function public.gf_match_candidates(double precision, double precision, real[], int) to authenticated;
grant execute on function public.gf_create_gate(text, uuid, text, text, text, double precision, double precision, real, real, text, text, jsonb) to authenticated;
grant execute on function public.gf_enter(uuid, uuid, double precision, double precision, real, real[], int) to authenticated;
grant execute on function public.gf_post_graffiti(uuid, text, text, text, boolean) to authenticated;
grant execute on function public.gf_delete_graffiti(uuid) to authenticated;
grant execute on function public.gf_update_gate(uuid, text, text, text, text) to authenticated;
grant execute on function public.gf_gate_summary(uuid) to authenticated;
grant execute on function public.gf_friend_feed() to authenticated;

-- ======================================================================
-- 0002_gf_place_maps.sql
-- ======================================================================
-- GRAFITYGATE：場所の記憶（ARWorldMap）
--
-- GATE を作った人が扉の前で保存した「場所の記憶」を、友達の iPhone に届けて、扉を同じ位置・向きに出すためのもの。
-- 場所の記憶には周りの景色の特徴が入るので、受け取れるのは「その GATE の有効な入場券を持つ人」と作った本人だけ。
-- GATE を消すと一緒に消える（ファイル本体は、アプリが GATE を消すときに消す）。
--
-- 使い方：0001 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

create table if not exists public.gf_place_maps (
  gate_id uuid primary key references public.gf_gates(id) on delete cascade,
  owner uuid not null references public.profiles(id) on delete cascade,
  path text not null,
  anchor_name text not null default 'gg.gate' check (char_length(anchor_name) between 1 and 64),
  byte_size int not null check (byte_size between 1 and 31457280),
  created_at timestamptz not null default now()
);
create index if not exists gf_place_maps_path on public.gf_place_maps(path);
-- 直接は読ませない（下の関数を通す）
alter table public.gf_place_maps enable row level security;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('gf-maps', 'gf-maps', false, 31457280, array['application/octet-stream'])
on conflict (id) do nothing;

-- 自分の GATE に場所の記憶を登録する（作り直したら置き換える）
create or replace function public.gf_register_place_map(p_gate uuid, p_path text, p_size int, p_anchor text)
returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if not exists (select 1 from gf_gates where id = p_gate and owner = me) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  if p_path is null or split_part(p_path, '/', 1) <> me::text then
    raise exception 'gf_bad_media_path' using errcode = 'P0001';
  end if;
  insert into gf_place_maps (gate_id, owner, path, anchor_name, byte_size)
  values (p_gate, me, p_path, coalesce(nullif(p_anchor, ''), 'gg.gate'), p_size)
  on conflict (gate_id) do update
    set path = excluded.path, anchor_name = excluded.anchor_name, byte_size = excluded.byte_size,
        created_at = now();
end $$;

-- 場所の記憶の置き場所（作った本人か、いま入場中の人だけに返す）
create or replace function public.gf_place_map(p_gate uuid)
returns table (path text, anchor_name text, byte_size int, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select m.path, m.anchor_name, m.byte_size, m.created_at
    from gf_place_maps m
    where m.gate_id = p_gate
      and (m.owner = auth.uid() or gf_active_visit(m.gate_id, auth.uid()) is not null);
end $$;

-- 場所の記憶のファイルを読んでよいか
create or replace function public.gf_can_read_map(p_path text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    split_part(p_path, '/', 1) = auth.uid()::text
    or exists (select 1 from gf_place_maps m
               where m.path = p_path and gf_active_visit(m.gate_id, auth.uid()) is not null))
$$;

drop policy if exists "gf maps read" on storage.objects;
create policy "gf maps read" on storage.objects for select to authenticated
  using (bucket_id = 'gf-maps' and public.gf_can_read_map(name));
drop policy if exists "gf maps insert" on storage.objects;
create policy "gf maps insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'gf-maps' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "gf maps update" on storage.objects;
create policy "gf maps update" on storage.objects for update to authenticated
  using (bucket_id = 'gf-maps' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "gf maps delete" on storage.objects;
create policy "gf maps delete" on storage.objects for delete to authenticated
  using (bucket_id = 'gf-maps' and (storage.foldername(name))[1] = auth.uid()::text);

revoke all on function public.gf_register_place_map(uuid, text, int, text) from public, anon;
revoke all on function public.gf_place_map(uuid) from public, anon;
revoke all on function public.gf_can_read_map(text) from public, anon;
grant execute on function public.gf_register_place_map(uuid, text, int, text) to authenticated;
grant execute on function public.gf_place_map(uuid) to authenticated;
grant execute on function public.gf_can_read_map(text) to authenticated;

-- ======================================================================
-- 0003_gf_artworks.sql
-- ======================================================================
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

-- ======================================================================
-- 0004_gf_inside.sql
-- ======================================================================
-- GRAFITYGATE：GATE の中の機能（掲示板・手紙とタイムカプセル・思い出）と、保存・図鑑・通報・ブロック・
-- データの書き出し・アカウントの削除。
--
-- 現地だけの中身（掲示板・思い出）は、その GATE の有効な入場券を持つ人だけが読める（書いた本人・仲間は別）。
-- 手紙は、閉じているあいだは「手紙がある」ことだけが分かり、開く条件（日時・現地）がそろうと宛先の本人だけが読める。
--
-- 使い方：0003 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

insert into public.gf_settings (key, value, note) values
  ('board_posts_per_hour', 10, '1 時間に立てられる掲示板の話題の数'),
  ('board_replies_per_hour', 40, '1 時間に書ける掲示板の返信の数'),
  ('letters_per_day', 10, '1 日に書ける手紙の数'),
  ('memories_per_day', 10, '1 日に作れる思い出の数'),
  ('memory_items_max', 40, '1 つの思い出に入れられる写真の数'),
  ('memory_items_per_person', 12, '1 人が 1 つの思い出に足せる写真の数'),
  ('memory_join_hours', 72, '思い出を作ってから、仲間が現地にいなくても写真を足せる時間'),
  ('reports_per_day', 30, '1 日に送れる通報の数')
on conflict (key) do nothing;

-- いま有効な、自分の入場券（だめなら gf_visit_invalid）
create or replace function public.gf_valid_visit(p_visit uuid) returns public.gf_visits
language plpgsql stable security definer set search_path = public as $$
declare
  v gf_visits;
  g gf_gates;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into v from gf_visits where id = p_visit and user_id = auth.uid();
  if not found or v.revoked_at is not null or v.expires_at <= now() then
    raise exception 'gf_visit_invalid' using errcode = 'P0001';
  end if;
  select * into g from gf_gates where id = v.gate_id;
  if not found or not gf_can_see_gate(g, auth.uid()) then
    raise exception 'gf_visit_invalid' using errcode = 'P0001';
  end if;
  return v;
end $$;

-- ============ 掲示板 ============
create table if not exists public.gf_board_threads (
  id uuid primary key default gen_random_uuid(),
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  author uuid not null references public.profiles(id) on delete cascade,
  topic text not null default 'memory' check (topic in ('memory', 'question', 'notice', 'other')),
  title text not null check (char_length(btrim(title)) between 1 and 60),
  body text not null default '' check (char_length(body) <= 1000),
  pinned boolean not null default false,
  reply_count int not null default 0,
  last_activity_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index if not exists gf_board_threads_gate on public.gf_board_threads(gate_id, last_activity_at desc);
alter table public.gf_board_threads enable row level security;

create table if not exists public.gf_board_replies (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.gf_board_threads(id) on delete cascade,
  author uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 1000),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index if not exists gf_board_replies_thread on public.gf_board_replies(thread_id, created_at);
alter table public.gf_board_replies enable row level security;

-- どこまで読んだか（未読の印）
create table if not exists public.gf_board_reads (
  user_id uuid not null references public.profiles(id) on delete cascade,
  thread_id uuid not null references public.gf_board_threads(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (user_id, thread_id)
);
alter table public.gf_board_reads enable row level security;

-- 掲示板の話題を見てよいか：書いた本人はいつでも。ほかの人は、その GATE の入場券が要る。
create or replace function public.gf_can_see_thread(t public.gf_board_threads, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and t.deleted_at is null and (
    t.author = viewer or (
      not gf_blocked(viewer, t.author)
      and gf_active_visit(t.gate_id, viewer) is not null))
$$;

drop policy if exists "gf board threads read" on public.gf_board_threads;
create policy "gf board threads read" on public.gf_board_threads for select to authenticated
  using (public.gf_can_see_thread(gf_board_threads, auth.uid()));

-- 返信：入場券があって話題が見えるとき（自分の返信は、話題が見えればいつでも）
drop policy if exists "gf board replies read" on public.gf_board_replies;
create policy "gf board replies read" on public.gf_board_replies for select to authenticated
  using (deleted_at is null and exists (
    select 1 from public.gf_board_threads t
    where t.id = thread_id and public.gf_can_see_thread(t, auth.uid())
      and (gf_board_replies.author = auth.uid()
           or (not public.gf_blocked(auth.uid(), gf_board_replies.author)
               and public.gf_active_visit(t.gate_id, auth.uid()) is not null))));

-- 話題を立てる（入場中だけ）
create or replace function public.gf_board_post(p_visit uuid, p_topic text, p_title text, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v gf_visits := gf_valid_visit(p_visit);
  tid uuid;
begin
  perform gf_take_rate('board_post', gf_setting('board_posts_per_hour'), 3600);
  begin
    insert into gf_board_threads (gate_id, author, topic, title, body)
    values (v.gate_id, auth.uid(), coalesce(p_topic, 'memory'), btrim(coalesce(p_title, '')), coalesce(p_body, ''))
    returning id into tid;
  exception when check_violation then
    raise exception 'gf_bad_post' using errcode = 'P0001';
  end;
  insert into gf_board_reads (user_id, thread_id) values (auth.uid(), tid) on conflict do nothing;
  return tid;
end $$;

-- 返信する（入場中だけ）
create or replace function public.gf_board_reply(p_visit uuid, p_thread uuid, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v gf_visits := gf_valid_visit(p_visit);
  t gf_board_threads;
  rid uuid;
begin
  select * into t from gf_board_threads where id = p_thread for update;
  if not found or t.gate_id <> v.gate_id or not gf_can_see_thread(t, auth.uid()) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  perform gf_take_rate('board_reply', gf_setting('board_replies_per_hour'), 3600);
  begin
    insert into gf_board_replies (thread_id, author, body) values (t.id, auth.uid(), btrim(coalesce(p_body, '')))
    returning id into rid;
  exception when check_violation then
    raise exception 'gf_bad_post' using errcode = 'P0001';
  end;
  update gf_board_threads set reply_count = reply_count + 1, last_activity_at = now() where id = t.id;
  insert into gf_board_reads (user_id, thread_id) values (auth.uid(), t.id)
  on conflict (user_id, thread_id) do update set read_at = now();
  return rid;
end $$;

-- GATE の掲示板の一覧（ピン留め → 新しく動いた順）。未読の印つき
create or replace function public.gf_board_list(p_gate uuid)
returns table (id uuid, author uuid, author_name text, topic text, title text, body text, pinned boolean,
               reply_count int, last_activity_at timestamptz, created_at timestamptz, unread boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select t.id, t.author, p.display_name, t.topic, t.title, t.body, t.pinned, t.reply_count,
           t.last_activity_at, t.created_at,
           coalesce(r.read_at < t.last_activity_at, true)
    from gf_board_threads t
    join profiles p on p.id = t.author
    left join gf_board_reads r on r.thread_id = t.id and r.user_id = auth.uid()
    where t.gate_id = p_gate and gf_can_see_thread(t, auth.uid())
    order by t.pinned desc, t.last_activity_at desc
    limit 200;
end $$;

-- 話題の返信（読んだ印も付ける）
create or replace function public.gf_board_replies_of(p_thread uuid)
returns table (id uuid, author uuid, author_name text, body text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare t gf_board_threads;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into t from gf_board_threads where gf_board_threads.id = p_thread;
  if not found or not gf_can_see_thread(t, auth.uid()) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  insert into gf_board_reads (user_id, thread_id) values (auth.uid(), t.id)
  on conflict (user_id, thread_id) do update set read_at = now();
  return query
    select r.id, r.author, p.display_name, r.body, r.created_at
    from gf_board_replies r join profiles p on p.id = r.author
    where r.thread_id = t.id and r.deleted_at is null
      and (r.author = auth.uid()
           or (not gf_blocked(auth.uid(), r.author) and gf_active_visit(t.gate_id, auth.uid()) is not null))
    order by r.created_at
    limit 500;
end $$;

-- ピン留め（GATE を作った人だけ。遠くからでもよい）
create or replace function public.gf_board_pin(p_thread uuid, p_pinned boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_board_threads t set pinned = coalesce(p_pinned, false)
  where t.id = p_thread and t.deleted_at is null
    and exists (select 1 from gf_gates g where g.id = t.gate_id and g.owner = auth.uid());
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- 消す（書いた本人か、GATE を作った人。遠くからでもよい）。p_kind は thread / reply
create or replace function public.gf_board_delete(p_kind text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare tid uuid;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_kind = 'thread' then
    update gf_board_threads t set deleted_at = now()
    where t.id = p_id and t.deleted_at is null
      and (t.author = auth.uid() or exists (select 1 from gf_gates g where g.id = t.gate_id and g.owner = auth.uid()))
    returning t.id into tid;
  elsif p_kind = 'reply' then
    update gf_board_replies r set deleted_at = now()
    from gf_board_threads t
    where r.id = p_id and r.deleted_at is null and t.id = r.thread_id
      and (r.author = auth.uid() or exists (select 1 from gf_gates g where g.id = t.gate_id and g.owner = auth.uid()))
    returning r.thread_id into tid;
    if tid is not null then
      update gf_board_threads set reply_count = greatest(reply_count - 1, 0) where id = tid;
    end if;
  end if;
  if tid is null then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- ============ 手紙・タイムカプセル ============
create table if not exists public.gf_letters (
  id uuid primary key default gen_random_uuid(),
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  author uuid not null references public.profiles(id) on delete cascade,
  recipient uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  photo_path text,
  -- 開く条件：日時（なければいつでも）と、現地に来たときだけか
  open_at timestamptz,
  onsite boolean not null default true,
  opened_at timestamptz,
  created_at timestamptz not null default now(),
  check (onsite or open_at is not null)
);
create index if not exists gf_letters_recipient on public.gf_letters(recipient, created_at desc);
create index if not exists gf_letters_author on public.gf_letters(author, created_at desc);
create index if not exists gf_letters_gate on public.gf_letters(gate_id);
create index if not exists gf_letters_photo on public.gf_letters(photo_path);
alter table public.gf_letters enable row level security;
-- 表は直接読ませない（中身は開く条件がそろったときだけ、関数で返す）

-- 手紙を書く（入場中だけ。宛先は自分か、お互いにフォローしている友達で、その GATE を見られる人）
create or replace function public.gf_write_letter(p_visit uuid, p_recipient uuid, p_body text, p_photo_path text,
                                                  p_open_at timestamptz, p_onsite boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v gf_visits := gf_valid_visit(p_visit);
  me uuid := auth.uid();
  to_whom uuid := coalesce(p_recipient, auth.uid());
  g gf_gates;
  lid uuid;
begin
  if to_whom <> me and (not gf_mutual(me, to_whom) or gf_blocked(me, to_whom)) then
    raise exception 'gf_bad_recipient' using errcode = 'P0001';
  end if;
  select * into g from gf_gates where id = v.gate_id;
  if not gf_can_see_gate(g, to_whom) then
    raise exception 'gf_recipient_cannot_see' using errcode = 'P0001';
  end if;
  if p_open_at is not null and (p_open_at < now() - interval '1 minute' or p_open_at > now() + interval '10 years') then
    raise exception 'gf_bad_open_at' using errcode = 'P0001';
  end if;
  if p_photo_path is not null and split_part(p_photo_path, '/', 1) <> me::text then
    raise exception 'gf_bad_media_path' using errcode = 'P0001';
  end if;
  perform gf_take_rate('letter', gf_setting('letters_per_day'), 86400);
  begin
    insert into gf_letters (gate_id, author, recipient, body, photo_path, open_at, onsite)
    values (v.gate_id, me, to_whom, coalesce(p_body, ''), p_photo_path, p_open_at, coalesce(p_onsite, true))
    returning id into lid;
  exception when check_violation then
    raise exception 'gf_bad_letter' using errcode = 'P0001';
  end;
  return lid;
end $$;

-- 自分あての手紙と、自分が書いた手紙の一覧（中身は返さない）。p_gate を渡すとその GATE のものだけ
create or replace function public.gf_my_letters(p_gate uuid default null)
returns table (id uuid, gate_id uuid, gate_title text, author uuid, author_name text, recipient uuid,
               recipient_name text, open_at timestamptz, onsite boolean, opened_at timestamptz,
               created_at timestamptz, sent boolean, time_ok boolean, here boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select l.id, l.gate_id, g.title, l.author, pa.display_name, l.recipient, pr.display_name,
           l.open_at, l.onsite, l.opened_at, l.created_at,
           l.author = auth.uid() and l.recipient <> auth.uid(),
           l.open_at is null or l.open_at <= now(),
           gf_active_visit(l.gate_id, auth.uid()) is not null
    from gf_letters l
    join gf_gates g on g.id = l.gate_id
    join profiles pa on pa.id = l.author
    join profiles pr on pr.id = l.recipient
    where (l.recipient = auth.uid() or l.author = auth.uid())
      and (p_gate is null or l.gate_id = p_gate)
      and not gf_blocked(l.author, l.recipient)
      and (l.author = auth.uid() or gf_can_see_gate(g, auth.uid()))
    order by l.created_at desc
    limit 300;
end $$;

-- 手紙を開く（宛先の本人。日時が来ていて、現地のときは入場中であること）。書いた人はいつでも読める。
create or replace function public.gf_open_letter(p_letter uuid)
returns table (id uuid, author_name text, recipient_name text, body text, photo_path text,
               created_at timestamptz, opened_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  l gf_letters;
  g gf_gates;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into l from gf_letters where gf_letters.id = p_letter for update;
  if not found or (l.recipient <> auth.uid() and l.author <> auth.uid()) or gf_blocked(l.author, l.recipient) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  if l.recipient = auth.uid() and l.opened_at is null then
    select * into g from gf_gates where gf_gates.id = l.gate_id;
    if not gf_can_see_gate(g, auth.uid()) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
    if l.open_at is not null and l.open_at > now() then
      raise exception 'gf_letter_not_yet' using errcode = 'P0001';
    end if;
    if l.onsite and gf_active_visit(l.gate_id, auth.uid()) is null then
      raise exception 'gf_letter_onsite' using errcode = 'P0001';
    end if;
    update gf_letters set opened_at = now() where gf_letters.id = l.id returning * into l;
  end if;
  return query
    select l.id, pa.display_name, pr.display_name, l.body, l.photo_path, l.created_at, l.opened_at
    from profiles pa, profiles pr where pa.id = l.author and pr.id = l.recipient;
end $$;

-- 手紙を消す（書いた人は開かれる前まで。宛先の人は開いたあと）
create or replace function public.gf_delete_letter(p_letter uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_letters l
  where l.id = p_letter
    and ((l.author = auth.uid() and (l.opened_at is null or l.recipient = auth.uid()))
         or (l.recipient = auth.uid() and l.opened_at is not null));
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- ============ 思い出 ============
create table if not exists public.gf_memories (
  id uuid primary key default gen_random_uuid(),
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  owner uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 60),
  note text not null default '' check (char_length(note) <= 500),
  visibility text not null default 'friends' check (visibility in ('private', 'friends', 'public')),
  created_at timestamptz not null default now()
);
create index if not exists gf_memories_gate on public.gf_memories(gate_id, created_at desc);
alter table public.gf_memories enable row level security;

create table if not exists public.gf_memory_members (
  memory_id uuid not null references public.gf_memories(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  added_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (memory_id, user_id)
);
create index if not exists gf_memory_members_user on public.gf_memory_members(user_id);
alter table public.gf_memory_members enable row level security;

create table if not exists public.gf_memory_items (
  id uuid primary key default gen_random_uuid(),
  memory_id uuid not null references public.gf_memories(id) on delete cascade,
  author uuid not null references public.profiles(id) on delete cascade,
  photo_path text not null,
  caption text not null default '' check (char_length(caption) <= 200),
  created_at timestamptz not null default now()
);
create index if not exists gf_memory_items_memory on public.gf_memory_items(memory_id, created_at);
create index if not exists gf_memory_items_photo on public.gf_memory_items(photo_path);
alter table public.gf_memory_items enable row level security;

create or replace function public.gf_is_memory_member(p_memory uuid, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from gf_memories m where m.id = p_memory and m.owner = viewer)
      or exists (select 1 from gf_memory_members x where x.memory_id = p_memory and x.user_id = viewer)
$$;

-- 思い出を見てよいか：作った人と仲間はいつでも。ほかの人は、入場券と公開範囲が要る。
create or replace function public.gf_can_see_memory(m public.gf_memories, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and (
    gf_is_memory_member(m.id, viewer) or (
      not gf_blocked(viewer, m.owner)
      and gf_active_visit(m.gate_id, viewer) is not null
      and (m.visibility = 'public' or (m.visibility = 'friends' and gf_mutual(viewer, m.owner)))))
$$;

drop policy if exists "gf memories read" on public.gf_memories;
create policy "gf memories read" on public.gf_memories for select to authenticated
  using (public.gf_can_see_memory(gf_memories, auth.uid()));
drop policy if exists "gf memory items read" on public.gf_memory_items;
create policy "gf memory items read" on public.gf_memory_items for select to authenticated
  using (exists (select 1 from public.gf_memories m where m.id = memory_id and public.gf_can_see_memory(m, auth.uid()))
         and not public.gf_blocked(auth.uid(), author));
drop policy if exists "gf memory members read" on public.gf_memory_members;
create policy "gf memory members read" on public.gf_memory_members for select to authenticated
  using (exists (select 1 from public.gf_memories m where m.id = memory_id and public.gf_can_see_memory(m, auth.uid())));

-- 思い出を作る（入場中だけ）
create or replace function public.gf_create_memory(p_visit uuid, p_title text, p_note text, p_visibility text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v gf_visits := gf_valid_visit(p_visit);
  mid uuid;
begin
  perform gf_take_rate('memory', gf_setting('memories_per_day'), 86400);
  begin
    insert into gf_memories (gate_id, owner, title, note, visibility)
    values (v.gate_id, auth.uid(), btrim(coalesce(p_title, '')), coalesce(p_note, ''), coalesce(p_visibility, 'friends'))
    returning id into mid;
  exception when check_violation then
    raise exception 'gf_bad_post' using errcode = 'P0001';
  end;
  return mid;
end $$;

-- 一緒にいた友達を仲間に入れる（作った人だけ。お互いにフォローしている人）
create or replace function public.gf_invite_to_memory(p_memory uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m gf_memories;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into m from gf_memories where id = p_memory and owner = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  if p_user = auth.uid() or not gf_mutual(auth.uid(), p_user) or gf_blocked(auth.uid(), p_user) then
    raise exception 'gf_bad_recipient' using errcode = 'P0001';
  end if;
  insert into gf_memory_members (memory_id, user_id, added_by) values (m.id, p_user, auth.uid())
  on conflict do nothing;
end $$;

-- 思い出に写真を足す（作った人・仲間。現地にいるか、作ってから 72 時間以内）
create or replace function public.gf_add_memory_item(p_memory uuid, p_photo_path text, p_caption text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  m gf_memories;
  iid uuid;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into m from gf_memories where id = p_memory for update;
  if not found or not gf_is_memory_member(m.id, auth.uid()) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  if gf_active_visit(m.gate_id, auth.uid()) is null
     and m.created_at < now() - make_interval(hours => gf_setting('memory_join_hours')::int) then
    raise exception 'gf_visit_invalid' using errcode = 'P0001';
  end if;
  if p_photo_path is null or split_part(p_photo_path, '/', 1) <> auth.uid()::text then
    raise exception 'gf_bad_media_path' using errcode = 'P0001';
  end if;
  if (select count(*) from gf_memory_items where memory_id = m.id) >= gf_setting('memory_items_max') then
    raise exception 'gf_memory_full' using errcode = 'P0001';
  end if;
  if (select count(*) from gf_memory_items where memory_id = m.id and author = auth.uid())
     >= gf_setting('memory_items_per_person') then
    raise exception 'gf_memory_full' using errcode = 'P0001';
  end if;
  begin
    insert into gf_memory_items (memory_id, author, photo_path, caption)
    values (m.id, auth.uid(), p_photo_path, coalesce(p_caption, ''))
    returning id into iid;
  exception when check_violation then
    raise exception 'gf_bad_post' using errcode = 'P0001';
  end;
  return iid;
end $$;

-- GATE の思い出の一覧（見てよいものだけ）
create or replace function public.gf_memory_list(p_gate uuid)
returns table (id uuid, owner uuid, owner_name text, title text, note text, visibility text, created_at timestamptz,
               item_count bigint, cover_path text, member_count bigint, is_member boolean, can_add boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select m.id, m.owner, p.display_name, m.title, m.note, m.visibility, m.created_at,
           (select count(*) from gf_memory_items i where i.memory_id = m.id),
           (select i.photo_path from gf_memory_items i where i.memory_id = m.id
              and not gf_blocked(auth.uid(), i.author) order by i.created_at limit 1),
           (select count(*) from gf_memory_members x where x.memory_id = m.id) + 1,
           gf_is_memory_member(m.id, auth.uid()),
           gf_is_memory_member(m.id, auth.uid())
             and (gf_active_visit(m.gate_id, auth.uid()) is not null
                  or m.created_at >= now() - make_interval(hours => gf_setting('memory_join_hours')::int))
    from gf_memories m join profiles p on p.id = m.owner
    where m.gate_id = p_gate and gf_can_see_memory(m, auth.uid())
    order by m.created_at desc
    limit 100;
end $$;

-- 自分が作った・仲間に入っている思い出（わたしの画面）
create or replace function public.gf_my_memories()
returns table (id uuid, gate_id uuid, gate_title text, owner uuid, owner_name text, title text,
               created_at timestamptz, item_count bigint, cover_path text)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select m.id, m.gate_id, g.title, m.owner, p.display_name, m.title, m.created_at,
           (select count(*) from gf_memory_items i where i.memory_id = m.id),
           (select i.photo_path from gf_memory_items i where i.memory_id = m.id
              and not gf_blocked(auth.uid(), i.author) order by i.created_at limit 1)
    from gf_memories m
    join gf_gates g on g.id = m.gate_id
    join profiles p on p.id = m.owner
    where gf_is_memory_member(m.id, auth.uid()) and not gf_blocked(auth.uid(), m.owner)
    order by m.created_at desc
    limit 200;
end $$;

create or replace function public.gf_delete_memory(p_memory uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_memories where id = p_memory and owner = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- 写真を消す（足した本人か、思い出を作った人）。消した写真の置き場所の名前を返す（アプリがファイルも消す）
create or replace function public.gf_delete_memory_item(p_item uuid) returns text
language plpgsql security definer set search_path = public as $$
declare path text;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_memory_items i
  where i.id = p_item
    and (i.author = auth.uid() or exists (select 1 from gf_memories m where m.id = i.memory_id and m.owner = auth.uid()))
  returning i.photo_path into path;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return path;
end $$;

create or replace function public.gf_leave_memory(p_memory uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_memory_members where memory_id = p_memory and user_id = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- ============ 保存と図鑑 ============
create table if not exists public.gf_bookmarks (
  user_id uuid not null references public.profiles(id) on delete cascade,
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, gate_id)
);
alter table public.gf_bookmarks enable row level security;
drop policy if exists "gf bookmarks own read" on public.gf_bookmarks;
create policy "gf bookmarks own read" on public.gf_bookmarks for select to authenticated using (user_id = auth.uid());

-- 図鑑：入場した GATE の記録（入場すると自動で付く）。本人が選んだものだけ友達に見せる
create table if not exists public.gf_atlas (
  user_id uuid not null references public.profiles(id) on delete cascade,
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  visits int not null default 1,
  shared boolean not null default false,
  primary key (user_id, gate_id)
);
alter table public.gf_atlas enable row level security;
drop policy if exists "gf atlas own read" on public.gf_atlas;
create policy "gf atlas own read" on public.gf_atlas for select to authenticated using (user_id = auth.uid());

create or replace function public.gf_atlas_on_visit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into gf_atlas (user_id, gate_id, first_at, last_at, visits)
  values (new.user_id, new.gate_id, new.created_at, new.created_at, 1)
  on conflict (user_id, gate_id) do update set last_at = excluded.last_at, visits = gf_atlas.visits + 1;
  return new;
end $$;
drop trigger if exists gf_atlas_on_visit on public.gf_visits;
create trigger gf_atlas_on_visit after insert on public.gf_visits
  for each row execute function public.gf_atlas_on_visit();

create or replace function public.gf_set_bookmark(p_gate uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare g gf_gates;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if coalesce(p_on, true) then
    select * into g from gf_gates where id = p_gate;
    if not found or not gf_can_see_gate(g, auth.uid()) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
    insert into gf_bookmarks (user_id, gate_id) values (auth.uid(), p_gate) on conflict do nothing;
  else
    delete from gf_bookmarks where user_id = auth.uid() and gate_id = p_gate;
  end if;
end $$;

create or replace function public.gf_set_atlas_shared(p_gate uuid, p_shared boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_atlas set shared = coalesce(p_shared, false) where user_id = auth.uid() and gate_id = p_gate;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- GATE の一覧の形（保存・図鑑・友達の図鑑で共通）。位置は 3 けた（約 100m）に丸める
-- kind：saved（保存）／ visited（図鑑）
create or replace function public.gf_my_collection(p_kind text)
returns table (gate_id uuid, title text, owner uuid, owner_name text, cover_path text,
               approx_lat double precision, approx_lon double precision,
               first_at timestamptz, last_at timestamptz, visits int, shared boolean, saved_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_kind = 'saved' then
    return query
      select g.id, g.title, g.owner, p.display_name, g.cover_path,
             round(g.lat::numeric, 3)::double precision, round(g.lon::numeric, 3)::double precision,
             a.first_at, a.last_at, coalesce(a.visits, 0), coalesce(a.shared, false), b.created_at
      from gf_bookmarks b
      join gf_gates g on g.id = b.gate_id
      join profiles p on p.id = g.owner
      left join gf_atlas a on a.user_id = b.user_id and a.gate_id = b.gate_id
      where b.user_id = auth.uid() and gf_can_see_gate(g, auth.uid())
      order by b.created_at desc limit 500;
  else
    return query
      select g.id, g.title, g.owner, p.display_name, g.cover_path,
             round(g.lat::numeric, 3)::double precision, round(g.lon::numeric, 3)::double precision,
             a.first_at, a.last_at, a.visits, a.shared,
             (select b.created_at from gf_bookmarks b where b.user_id = a.user_id and b.gate_id = a.gate_id)
      from gf_atlas a
      join gf_gates g on g.id = a.gate_id
      join profiles p on p.id = g.owner
      where a.user_id = auth.uid() and gf_can_see_gate(g, auth.uid())
      order by a.last_at desc limit 500;
  end if;
end $$;

-- 友達の図鑑（お互いにフォローしている友達の、本人が見せると選んだものだけ）
create or replace function public.gf_friend_atlas(p_user uuid)
returns table (gate_id uuid, title text, owner uuid, owner_name text, cover_path text,
               approx_lat double precision, approx_lon double precision, first_at timestamptz, visits int)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_user <> auth.uid() and (not gf_mutual(auth.uid(), p_user) or gf_blocked(auth.uid(), p_user)) then
    return;
  end if;
  return query
    select g.id, g.title, g.owner, p.display_name, g.cover_path,
           round(g.lat::numeric, 3)::double precision, round(g.lon::numeric, 3)::double precision,
           a.first_at, a.visits
    from gf_atlas a
    join gf_gates g on g.id = a.gate_id
    join profiles p on p.id = g.owner
    where a.user_id = p_user and a.shared and gf_can_see_gate(g, auth.uid())
    order by a.first_at desc limit 500;
end $$;

-- ============ 通報とブロック ============
-- 通報（App Store の決まり 1.2）。読めるのは運営だけ（Supabase の管理画面）。
create table if not exists public.gf_reports (
  id uuid primary key default gen_random_uuid(),
  reporter uuid not null references public.profiles(id) on delete cascade,
  target_kind text not null check (target_kind in ('gate', 'graffiti', 'artwork', 'thread', 'reply', 'memory',
                                                   'memory_item', 'letter', 'user')),
  target_id uuid not null,
  target_user uuid references public.profiles(id) on delete set null,
  reason text not null check (reason in ('harassment', 'inappropriate', 'privacy', 'dangerous', 'spam', 'other')),
  note text check (note is null or char_length(note) <= 500),
  snapshot text check (snapshot is null or char_length(snapshot) <= 500),
  status text not null default 'open' check (status in ('open', 'reviewing', 'closed')),
  created_at timestamptz not null default now()
);
create index if not exists gf_reports_created on public.gf_reports(created_at desc);
alter table public.gf_reports enable row level security;

-- 通報する。だれのものか・そのときの文は、サーバーが埋める（見られないものは通報できない＝あるかも知らせない）
create or replace function public.gf_report(p_kind text, p_id uuid, p_reason text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  who uuid;
  what text;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  case p_kind
    when 'gate' then
      select g.owner, g.title into who, what from gf_gates g where g.id = p_id and gf_can_see_gate(g, me);
    when 'graffiti' then
      select x.author, x.body into who, what from gf_graffiti x
      where x.id = p_id and (gf_can_see_graffiti(x, me) or gf_feed_visible(x, me));
    when 'artwork' then
      select a.owner, a.kind || ' ' || a.body into who, what from gf_artworks a where a.id = p_id and gf_can_see_artwork(a, me);
    when 'thread' then
      select t.author, t.title || ' ' || t.body into who, what from gf_board_threads t
      where t.id = p_id and gf_can_see_thread(t, me);
    when 'reply' then
      select r.author, r.body into who, what from gf_board_replies r join gf_board_threads t on t.id = r.thread_id
      where r.id = p_id and r.deleted_at is null and gf_can_see_thread(t, me);
    when 'memory' then
      select m.owner, m.title || ' ' || m.note into who, what from gf_memories m where m.id = p_id and gf_can_see_memory(m, me);
    when 'memory_item' then
      select i.author, i.caption into who, what from gf_memory_items i join gf_memories m on m.id = i.memory_id
      where i.id = p_id and gf_can_see_memory(m, me);
    when 'letter' then
      select l.author, l.body into who, what from gf_letters l
      where l.id = p_id and l.recipient = me and l.opened_at is not null;
    when 'user' then
      select p.id, p.display_name into who, what from profiles p where p.id = p_id;
    else
      raise exception 'gf_not_found' using errcode = 'P0001';
  end case;
  if who is null then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  perform gf_take_rate('report', gf_setting('reports_per_day'), 86400);
  begin
    insert into gf_reports (reporter, target_kind, target_id, target_user, reason, note, snapshot)
    values (me, p_kind, p_id, who, p_reason, nullif(btrim(coalesce(p_note, '')), ''), left(what, 500));
  exception when check_violation then
    raise exception 'gf_bad_report' using errcode = 'P0001';
  end;
end $$;

-- ブロック（Lyric Path と共通の表 lp_blocks に書く＝両方のアプリで効く）。入場券も見てよいかの判定ですぐ使えなくなる
create or replace function public.gf_block(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_user is null or p_user = auth.uid() then return; end if;
  insert into lp_blocks (blocker, blocked) values (auth.uid(), p_user) on conflict do nothing;
  delete from gf_memory_members x using gf_memories m
    where x.memory_id = m.id and ((m.owner = auth.uid() and x.user_id = p_user)
                                  or (m.owner = p_user and x.user_id = auth.uid()));
end $$;

create or replace function public.gf_unblock(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from lp_blocks where blocker = auth.uid() and blocked = p_user;
end $$;

create or replace function public.gf_my_blocks()
returns table (user_id uuid, display_name text, handle text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select p.id, p.display_name, p.handle, b.created_at
    from lp_blocks b join profiles p on p.id = b.blocked
    where b.blocker = auth.uid()
    order by b.created_at desc;
end $$;

-- ============ 自分のデータ ============
-- 書き出し：自分が作った・書いたもの（自分の GATE は正確な位置も）を 1 つの JSON にする
create or replace function public.gf_export_me() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return jsonb_build_object(
    'exported_at', now(),
    'profile', (select to_jsonb(p) from profiles p where p.id = me),
    'gates', coalesce((select jsonb_agg(to_jsonb(g) order by g.created_at) from gf_gates g where g.owner = me), '[]'),
    'graffiti', coalesce((select jsonb_agg(to_jsonb(x) - 'visit_id' order by x.created_at) from gf_graffiti x
                          where x.author = me and x.deleted_at is null), '[]'),
    'artworks', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from gf_artworks a where a.owner = me), '[]'),
    'board_threads', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at) from gf_board_threads t
                               where t.author = me and t.deleted_at is null), '[]'),
    'board_replies', coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at) from gf_board_replies r
                               where r.author = me and r.deleted_at is null), '[]'),
    'letters_written', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at) from gf_letters l
                                 where l.author = me), '[]'),
    'letters_received', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at) from gf_letters l
                                  where l.recipient = me and l.author <> me and l.opened_at is not null), '[]'),
    'memories', coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at) from gf_memories m where m.owner = me), '[]'),
    'memory_items', coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at) from gf_memory_items i
                              where i.author = me), '[]'),
    'bookmarks', coalesce((select jsonb_agg(to_jsonb(b) order by b.created_at) from gf_bookmarks b where b.user_id = me), '[]'),
    'atlas', coalesce((select jsonb_agg(to_jsonb(a) order by a.first_at) from gf_atlas a where a.user_id = me), '[]'));
end $$;

-- アカウントの削除（App Store の決まり）。アプリが先に自分のファイル（写真・場所の記憶）を消してから呼ぶ。
-- auth.users を消すと、profiles から先（gf_ の表すべて）は on delete cascade で消える。
create or replace function public.gf_delete_me() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- ============ 写真を見てよいか（ここまでの全部） ============
create or replace function public.gf_can_read_media(p_path text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    split_part(p_path, '/', 1) = auth.uid()::text
    or exists (select 1 from gf_gates g where g.cover_path = p_path and gf_can_see_gate(g, auth.uid()))
    or exists (select 1 from gf_graffiti x where x.photo_path = p_path
               and (gf_can_see_graffiti(x, auth.uid()) or gf_feed_visible(x, auth.uid())))
    or exists (select 1 from gf_artworks a where a.photo_path = p_path and gf_can_see_artwork(a, auth.uid()))
    or exists (select 1 from gf_letters l where l.photo_path = p_path and l.recipient = auth.uid()
               and l.opened_at is not null and not gf_blocked(l.author, l.recipient))
    or exists (select 1 from gf_memory_items i join gf_memories m on m.id = i.memory_id
               where i.photo_path = p_path and gf_can_see_memory(m, auth.uid()) and not gf_blocked(auth.uid(), i.author)))
$$;

-- ============ 呼べる関数を絞る ============
revoke all on function public.gf_valid_visit(uuid) from public, anon, authenticated;

revoke all on function public.gf_can_see_thread(public.gf_board_threads, uuid) from public, anon;
revoke all on function public.gf_can_see_memory(public.gf_memories, uuid) from public, anon;
revoke all on function public.gf_is_memory_member(uuid, uuid) from public, anon;
revoke all on function public.gf_can_read_media(text) from public, anon;
grant execute on function public.gf_can_see_thread(public.gf_board_threads, uuid) to authenticated;
grant execute on function public.gf_can_see_memory(public.gf_memories, uuid) to authenticated;
grant execute on function public.gf_is_memory_member(uuid, uuid) to authenticated;
grant execute on function public.gf_can_read_media(text) to authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'gf_board_post(uuid, text, text, text)', 'gf_board_reply(uuid, uuid, text)', 'gf_board_list(uuid)',
    'gf_board_replies_of(uuid)', 'gf_board_pin(uuid, boolean)', 'gf_board_delete(text, uuid)',
    'gf_write_letter(uuid, uuid, text, text, timestamptz, boolean)', 'gf_my_letters(uuid)', 'gf_open_letter(uuid)',
    'gf_delete_letter(uuid)',
    'gf_create_memory(uuid, text, text, text)', 'gf_invite_to_memory(uuid, uuid)',
    'gf_add_memory_item(uuid, text, text)', 'gf_memory_list(uuid)', 'gf_my_memories()', 'gf_delete_memory(uuid)',
    'gf_delete_memory_item(uuid)', 'gf_leave_memory(uuid)',
    'gf_set_bookmark(uuid, boolean)', 'gf_set_atlas_shared(uuid, boolean)', 'gf_my_collection(text)',
    'gf_friend_atlas(uuid)',
    'gf_report(text, uuid, text, text)', 'gf_block(uuid)', 'gf_unblock(uuid)', 'gf_my_blocks()',
    'gf_export_me()', 'gf_delete_me()']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
revoke all on function public.gf_atlas_on_visit() from public, anon, authenticated;

-- ======================================================================
-- 0005_gf_social.sql
-- ======================================================================
-- GRAFITYGATE：お知らせと DM（メッセージ）
--
-- お知らせ：自分の GATE に記憶・作品・話題が残された、返信・手紙・思い出の仲間・いいね・フォローなど。
--   GATE の正確な位置や、現地だけの中身（本文・写真）はお知らせに入れない（だれが・どの GATE か・何が起きたかだけ）。
-- DM：お互いにフォローしている友達とだけ。ブロックしたら送れない・見えない。
--
-- 使い方：0004 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

insert into public.gf_settings (key, value, note) values
  ('dm_per_hour', 60, '1 時間に送れるメッセージの数'),
  ('notification_days', 60, 'お知らせを残す日数')
on conflict (key) do nothing;

-- ============ お知らせ ============
create table if not exists public.gf_notifications (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('gate_graffiti', 'gate_artwork', 'board_thread', 'board_reply', 'letter',
                                     'letter_opened', 'memory_invite', 'memory_photo', 'like')),
  actor uuid not null references public.profiles(id) on delete cascade,
  gate_id uuid references public.gf_gates(id) on delete cascade,
  ref_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists gf_notifications_user on public.gf_notifications(user_id, created_at desc);
alter table public.gf_notifications enable row level security;
-- 表は直接読ませない（関数で、ブロック・見てよい GATE を確かめてから返す）

-- どこまで見たか（これより新しいものが「新しいお知らせ」）
create table if not exists public.gf_notification_seen (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  seen_at timestamptz not null default now()
);
alter table public.gf_notification_seen enable row level security;

create or replace function public.gf_notify(p_user uuid, p_kind text, p_actor uuid, p_gate uuid, p_ref uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_user is null or p_actor is null or p_user = p_actor or gf_blocked(p_user, p_actor) then return; end if;
  -- 同じことの重なり（いいねを押し直した など）は 1 つにする
  if exists (select 1 from gf_notifications n where n.user_id = p_user and n.kind = p_kind and n.actor = p_actor
             and n.ref_id is not distinct from p_ref and n.created_at > now() - interval '1 day') then
    return;
  end if;
  insert into gf_notifications (user_id, kind, actor, gate_id, ref_id) values (p_user, p_kind, p_actor, p_gate, p_ref);
end $$;

-- 書いた人の公開範囲で、受け取る人が見てよいか（自分だけ・友達でない人には知らせない）
create or replace function public.gf_visible_to(p_visibility text, p_author uuid, p_viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_visibility = 'public' or (p_visibility = 'friends' and gf_mutual(p_viewer, p_author))
$$;

create or replace function public.gf_on_graffiti() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner_id uuid;
begin
  select owner into owner_id from gf_gates where id = new.gate_id;
  if gf_visible_to(new.visibility, new.author, owner_id) then
    perform gf_notify(owner_id, 'gate_graffiti', new.author, new.gate_id, new.id);
  end if;
  return new;
end $$;
drop trigger if exists gf_on_graffiti on public.gf_graffiti;
create trigger gf_on_graffiti after insert on public.gf_graffiti for each row execute function public.gf_on_graffiti();

create or replace function public.gf_on_artwork() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner_id uuid;
begin
  select owner into owner_id from gf_gates where id = new.gate_id;
  if gf_visible_to(new.visibility, new.owner, owner_id) then
    perform gf_notify(owner_id, 'gate_artwork', new.owner, new.gate_id, new.id);
  end if;
  return new;
end $$;
drop trigger if exists gf_on_artwork on public.gf_artworks;
create trigger gf_on_artwork after insert on public.gf_artworks for each row execute function public.gf_on_artwork();

create or replace function public.gf_on_board_thread() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform gf_notify((select owner from gf_gates where id = new.gate_id), 'board_thread', new.author, new.gate_id, new.id);
  return new;
end $$;
drop trigger if exists gf_on_board_thread on public.gf_board_threads;
create trigger gf_on_board_thread after insert on public.gf_board_threads
  for each row execute function public.gf_on_board_thread();

create or replace function public.gf_on_board_reply() returns trigger
language plpgsql security definer set search_path = public as $$
declare t gf_board_threads;
begin
  select * into t from gf_board_threads where id = new.thread_id;
  perform gf_notify(t.author, 'board_reply', new.author, t.gate_id, t.id);
  return new;
end $$;
drop trigger if exists gf_on_board_reply on public.gf_board_replies;
create trigger gf_on_board_reply after insert on public.gf_board_replies
  for each row execute function public.gf_on_board_reply();

create or replace function public.gf_on_letter() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform gf_notify(new.recipient, 'letter', new.author, new.gate_id, new.id);
  elsif old.opened_at is null and new.opened_at is not null then
    perform gf_notify(new.author, 'letter_opened', new.recipient, new.gate_id, new.id);
  end if;
  return new;
end $$;
drop trigger if exists gf_on_letter on public.gf_letters;
create trigger gf_on_letter after insert or update of opened_at on public.gf_letters
  for each row execute function public.gf_on_letter();

create or replace function public.gf_on_memory_member() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform gf_notify(new.user_id, 'memory_invite', coalesce(new.added_by, (select owner from gf_memories where id = new.memory_id)),
                    (select gate_id from gf_memories where id = new.memory_id), new.memory_id);
  return new;
end $$;
drop trigger if exists gf_on_memory_member on public.gf_memory_members;
create trigger gf_on_memory_member after insert on public.gf_memory_members
  for each row execute function public.gf_on_memory_member();

create or replace function public.gf_on_memory_item() returns trigger
language plpgsql security definer set search_path = public as $$
declare m gf_memories;
begin
  select * into m from gf_memories where id = new.memory_id;
  perform gf_notify(m.owner, 'memory_photo', new.author, m.gate_id, m.id);
  return new;
end $$;
drop trigger if exists gf_on_memory_item on public.gf_memory_items;
create trigger gf_on_memory_item after insert on public.gf_memory_items
  for each row execute function public.gf_on_memory_item();

create or replace function public.gf_on_reaction() returns trigger
language plpgsql security definer set search_path = public as $$
declare x gf_graffiti;
begin
  select * into x from gf_graffiti where id = new.graffiti_id;
  perform gf_notify(x.author, 'like', new.user_id, x.gate_id, x.id);
  return new;
end $$;
drop trigger if exists gf_on_reaction on public.gf_reactions;
create trigger gf_on_reaction after insert on public.gf_reactions
  for each row execute function public.gf_on_reaction();

-- 自分のお知らせ（新しい順）。フォローされたことも混ぜる。ブロックした人・もう見られない GATE のものは出さない
create or replace function public.gf_my_notifications()
returns table (kind text, actor uuid, actor_name text, gate_id uuid, gate_title text, ref_id uuid,
               created_at timestamptz, unread boolean)
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  seen timestamptz;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_notifications n
    where n.user_id = me and n.created_at < now() - make_interval(days => gf_setting('notification_days')::int);
  select s.seen_at into seen from gf_notification_seen s where s.user_id = me;
  seen := coalesce(seen, '-infinity'::timestamptz);
  return query
    select x.kind, x.actor, p.display_name, x.gate_id, x.gate_title, x.ref_id, x.created_at, x.created_at > seen
    from (
      select n.kind, n.actor, n.gate_id, g.title as gate_title, n.ref_id, n.created_at
      from gf_notifications n
      left join gf_gates g on g.id = n.gate_id
      where n.user_id = me and (n.gate_id is null or gf_can_see_gate(g, me))
      union all
      select 'follow', f.follower, null, null, null, f.created_at
      from follows f
      where f.followee = me and f.created_at > now() - make_interval(days => gf_setting('notification_days')::int)
    ) x
    join profiles p on p.id = x.actor
    where not gf_blocked(me, x.actor)
    order by x.created_at desc
    limit 200;
end $$;

create or replace function public.gf_unread_counts()
returns table (notifications bigint, messages bigint)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  seen timestamptz;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select s.seen_at into seen from gf_notification_seen s where s.user_id = me;
  seen := coalesce(seen, '-infinity'::timestamptz);
  return query select
    (select count(*) from gf_notifications n left join gf_gates g on g.id = n.gate_id
       where n.user_id = me and n.created_at > seen and not gf_blocked(me, n.actor)
         and (n.gate_id is null or gf_can_see_gate(g, me)))
    + (select count(*) from follows f where f.followee = me and f.created_at > seen and not gf_blocked(me, f.follower)),
    (select count(*) from gf_dm_messages d where d.recipient = me and d.read_at is null and d.deleted_at is null
       and not gf_blocked(me, d.sender));
end $$;

create or replace function public.gf_mark_notifications_seen() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  insert into gf_notification_seen (user_id, seen_at) values (auth.uid(), now())
  on conflict (user_id) do update set seen_at = now();
end $$;

-- ============ DM ============
create table if not exists public.gf_dm_messages (
  id uuid primary key default gen_random_uuid(),
  sender uuid not null references public.profiles(id) on delete cascade,
  recipient uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 1000),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  deleted_at timestamptz,
  check (sender <> recipient)
);
create index if not exists gf_dm_pair on public.gf_dm_messages(least(sender, recipient), greatest(sender, recipient), created_at desc);
create index if not exists gf_dm_recipient on public.gf_dm_messages(recipient, read_at);
alter table public.gf_dm_messages enable row level security;
-- 表は直接読ませない（関数で、ブロックを確かめてから返す）

-- 送る（お互いにフォローしている友達にだけ）
create or replace function public.gf_dm_send(p_to uuid, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare mid uuid;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_to is null or p_to = auth.uid() or not gf_mutual(auth.uid(), p_to) or gf_blocked(auth.uid(), p_to) then
    raise exception 'gf_bad_recipient' using errcode = 'P0001';
  end if;
  perform gf_take_rate('dm', gf_setting('dm_per_hour'), 3600);
  begin
    insert into gf_dm_messages (sender, recipient, body) values (auth.uid(), p_to, btrim(coalesce(p_body, '')))
    returning id into mid;
  exception when check_violation then
    raise exception 'gf_bad_post' using errcode = 'P0001';
  end;
  return mid;
end $$;

-- 話している相手の一覧（最後のひとこと・まだ読んでいない数）
create or replace function public.gf_dm_threads()
returns table (other uuid, other_name text, last_body text, last_at timestamptz, last_from_me boolean,
               unread bigint, can_send boolean)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    with mine as (
      select case when d.sender = me then d.recipient else d.sender end as o, d.*
      from gf_dm_messages d
      where (d.sender = me or d.recipient = me) and d.deleted_at is null
    ), lastmsg as (
      select distinct on (m.o) m.o, m.body, m.created_at, m.sender = me as from_me
      from mine m order by m.o, m.created_at desc
    )
    select l.o, p.display_name, l.body, l.created_at, l.from_me,
           (select count(*) from mine m where m.o = l.o and m.recipient = me and m.read_at is null),
           gf_mutual(me, l.o)
    from lastmsg l join profiles p on p.id = l.o
    where not gf_blocked(me, l.o)
    order by l.created_at desc;
end $$;

-- ある相手とのメッセージ（古い順。最新 200 件）。相手からのものを読んだことにする
create or replace function public.gf_dm_messages_with(p_other uuid)
returns table (id uuid, sender uuid, body text, created_at timestamptz, read_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if gf_blocked(me, p_other) then return; end if;
  update gf_dm_messages d set read_at = now()
    where d.sender = p_other and d.recipient = me and d.read_at is null;
  return query
    select x.id, x.sender, x.body, x.created_at, x.read_at from (
      select d.id, d.sender, d.body, d.created_at, d.read_at
      from gf_dm_messages d
      where ((d.sender = me and d.recipient = p_other) or (d.sender = p_other and d.recipient = me))
        and d.deleted_at is null
      order by d.created_at desc limit 200) x
    order by x.created_at;
end $$;

-- 自分が送ったメッセージを消す（相手からも見えなくなる）
create or replace function public.gf_dm_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_dm_messages set deleted_at = now() where id = p_id and sender = auth.uid() and deleted_at is null;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- 通報の対象に DM を足す
alter table public.gf_reports drop constraint if exists gf_reports_target_kind_check;
alter table public.gf_reports add constraint gf_reports_target_kind_check
  check (target_kind in ('gate', 'graffiti', 'artwork', 'thread', 'reply', 'memory', 'memory_item', 'letter', 'user', 'dm'));

create or replace function public.gf_report_dm(p_id uuid, p_reason text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare d gf_dm_messages;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into d from gf_dm_messages where id = p_id and recipient = auth.uid() and deleted_at is null;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  perform gf_take_rate('report', gf_setting('reports_per_day'), 86400);
  begin
    insert into gf_reports (reporter, target_kind, target_id, target_user, reason, note, snapshot)
    values (auth.uid(), 'dm', d.id, d.sender, p_reason, nullif(btrim(coalesce(p_note, '')), ''), left(d.body, 500));
  exception when check_violation then
    raise exception 'gf_bad_report' using errcode = 'P0001';
  end;
end $$;

-- 書き出しに DM（自分が送ったもの）を足す
create or replace function public.gf_export_me_social() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return gf_export_me() || jsonb_build_object(
    'messages_sent', coalesce((select jsonb_agg(jsonb_build_object('to', d.recipient, 'body', d.body, 'at', d.created_at)
                                                order by d.created_at)
                               from gf_dm_messages d where d.sender = auth.uid() and d.deleted_at is null), '[]'));
end $$;

-- ============ 呼べる関数を絞る ============
revoke all on function public.gf_notify(uuid, text, uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.gf_visible_to(text, uuid, uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['gf_on_graffiti()', 'gf_on_artwork()', 'gf_on_board_thread()', 'gf_on_board_reply()',
                           'gf_on_letter()', 'gf_on_memory_member()', 'gf_on_memory_item()', 'gf_on_reaction()']
  loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['gf_my_notifications()', 'gf_unread_counts()', 'gf_mark_notifications_seen()',
                           'gf_dm_send(uuid, text)', 'gf_dm_threads()', 'gf_dm_messages_with(uuid)', 'gf_dm_delete(uuid)',
                           'gf_report_dm(uuid, text, text)', 'gf_export_me_social()']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ======================================================================
-- 0006_gf_trails_snapshots.sql
-- ======================================================================
-- GRAFITYGATE：TRAIL（GATE をつないだ「思い出を歩く道」）と、今と昔（同じ場所の写真を時の順に並べて比べる）
--
-- TRAIL：自分が扉を開けたことのある GATE を 2〜20 か所つなぐ。歩く人は、順番どおりに現地で扉を開けると進む
--        （進むのはサーバーが入場の記録を見て決める＝アプリが「着いた」と言うだけでは進まない）。
-- 今と昔：入場中に、カメラでいまの景色を撮って残す（1 回の入場で 1 枚）。見られるのは入場中の人と撮った本人。
--
-- 使い方：0005 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

insert into public.gf_settings (key, value, note) values
  ('trails_per_day', 10, '1 日に作れる TRAIL の数'),
  ('trail_max_stops', 20, '1 つの TRAIL の地点の数の上限')
on conflict (key) do nothing;

-- ============ TRAIL ============
create table if not exists public.gf_trails (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 60),
  note text not null default '' check (char_length(note) <= 500),
  visibility text not null default 'friends' check (visibility in ('private', 'friends', 'public')),
  created_at timestamptz not null default now()
);
create index if not exists gf_trails_owner on public.gf_trails(owner, created_at desc);
alter table public.gf_trails enable row level security;

create table if not exists public.gf_trail_stops (
  trail_id uuid not null references public.gf_trails(id) on delete cascade,
  seq int not null check (seq >= 1),
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  primary key (trail_id, seq)
);
create index if not exists gf_trail_stops_gate on public.gf_trail_stops(gate_id);
alter table public.gf_trail_stops enable row level security;

create table if not exists public.gf_trail_progress (
  user_id uuid not null references public.profiles(id) on delete cascade,
  trail_id uuid not null references public.gf_trails(id) on delete cascade,
  reached int not null default 0,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  last_visit_id uuid,
  primary key (user_id, trail_id)
);
alter table public.gf_trail_progress enable row level security;

create or replace function public.gf_can_see_trail(t public.gf_trails, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and (
    t.owner = viewer or (
      not gf_blocked(viewer, t.owner)
      and (t.visibility = 'public' or (t.visibility = 'friends' and gf_mutual(viewer, t.owner)))))
$$;

-- TRAIL を作る（自分が扉を開けたことのある、いまも見られる GATE を、歩く順に）
create or replace function public.gf_create_trail(p_title text, p_note text, p_visibility text, p_gates uuid[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  tid uuid;
  i int;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_gates is null or cardinality(p_gates) < 2 or cardinality(p_gates) > gf_setting('trail_max_stops')
     or (select count(distinct x) from unnest(p_gates) as x) <> cardinality(p_gates) then
    raise exception 'gf_bad_trail' using errcode = 'P0001';
  end if;
  if exists (select 1 from unnest(p_gates) as x
             where not exists (select 1 from gf_atlas a join gf_gates g on g.id = a.gate_id
                               where a.user_id = me and a.gate_id = x and gf_can_see_gate(g, me))) then
    raise exception 'gf_trail_not_visited' using errcode = 'P0001';
  end if;
  perform gf_take_rate('trail', gf_setting('trails_per_day'), 86400);
  begin
    insert into gf_trails (owner, title, note, visibility)
    values (me, btrim(coalesce(p_title, '')), coalesce(p_note, ''), coalesce(p_visibility, 'friends'))
    returning id into tid;
  exception when check_violation then
    raise exception 'gf_bad_trail' using errcode = 'P0001';
  end;
  for i in 1 .. cardinality(p_gates) loop
    insert into gf_trail_stops (trail_id, seq, gate_id) values (tid, i, p_gates[i]);
  end loop;
  return tid;
end $$;

-- TRAIL の一覧：自分の・友達の（見てよいもの）・歩いているもの。p_gate を渡すと、その GATE をふくむものだけ
create or replace function public.gf_trail_list(p_gate uuid default null)
returns table (id uuid, owner uuid, owner_name text, title text, note text, visibility text, created_at timestamptz,
               stop_count int, cover_path text, reached int, completed boolean, started boolean)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select t.id, t.owner, p.display_name, t.title, t.note, t.visibility, t.created_at,
           (select count(*)::int from gf_trail_stops s where s.trail_id = t.id),
           (select g.cover_path from gf_trail_stops s join gf_gates g on g.id = s.gate_id
              where s.trail_id = t.id and gf_can_see_gate(g, me) and g.cover_path is not null
              order by s.seq limit 1),
           coalesce(pr.reached, 0), pr.completed_at is not null, pr.user_id is not null
    from gf_trails t
    join profiles p on p.id = t.owner
    left join gf_trail_progress pr on pr.trail_id = t.id and pr.user_id = me
    where gf_can_see_trail(t, me)
      and (t.owner = me or pr.user_id is not null or gf_mutual(me, t.owner) or p_gate is not null)
      and (p_gate is null or exists (select 1 from gf_trail_stops s where s.trail_id = t.id and s.gate_id = p_gate))
    order by (pr.user_id is not null and pr.completed_at is null) desc, t.created_at desc
    limit 200;
end $$;

-- TRAIL の地点（見られない GATE は名前・位置を出さない）と、自分の進み具合
create or replace function public.gf_trail_stops_of(p_trail uuid)
returns table (seq int, gate_id uuid, title text, cover_path text, approx_lat double precision,
               approx_lon double precision, visible boolean, reached boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  t gf_trails;
  done int;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into t from gf_trails where gf_trails.id = p_trail;
  if not found or not gf_can_see_trail(t, me) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  select coalesce(pr.reached, 0) into done from gf_trail_progress pr where pr.trail_id = t.id and pr.user_id = me;
  done := coalesce(done, 0);
  return query
    select s.seq,
           case when gf_can_see_gate(g, me) then g.id end,
           case when gf_can_see_gate(g, me) then g.title else '見られない GATE' end,
           case when gf_can_see_gate(g, me) then g.cover_path end,
           case when gf_can_see_gate(g, me) then round(g.lat::numeric, 3)::double precision end,
           case when gf_can_see_gate(g, me) then round(g.lon::numeric, 3)::double precision end,
           gf_can_see_gate(g, me),
           s.seq <= done
    from gf_trail_stops s join gf_gates g on g.id = s.gate_id
    where s.trail_id = t.id
    order by s.seq;
end $$;

-- 歩き始める（もう始めていれば何もしない）
create or replace function public.gf_trail_start(p_trail uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t gf_trails;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into t from gf_trails where id = p_trail;
  if not found or not gf_can_see_trail(t, auth.uid()) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  insert into gf_trail_progress (user_id, trail_id) values (auth.uid(), t.id) on conflict do nothing;
end $$;

create or replace function public.gf_trail_quit(p_trail uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_trail_progress where user_id = auth.uid() and trail_id = p_trail;
end $$;

create or replace function public.gf_delete_trail(p_trail uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_trails where id = p_trail and owner = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- 入場したら、歩いている TRAIL の「次の地点」がその GATE なら 1 つ進める（サーバーが入場の記録で決める）
create or replace function public.gf_trail_on_visit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update gf_trail_progress pr
     set reached = pr.reached + 1,
         last_visit_id = new.id,
         completed_at = case when pr.reached + 1 >= (select count(*) from gf_trail_stops s where s.trail_id = pr.trail_id)
                             then now() end
   where pr.user_id = new.user_id and pr.completed_at is null
     and exists (select 1 from gf_trail_stops s where s.trail_id = pr.trail_id and s.seq = pr.reached + 1
                 and s.gate_id = new.gate_id)
     and exists (select 1 from gf_trails t where t.id = pr.trail_id and gf_can_see_trail(t, new.user_id));
  return new;
end $$;
drop trigger if exists gf_trail_on_visit on public.gf_visits;
create trigger gf_trail_on_visit after insert on public.gf_visits for each row execute function public.gf_trail_on_visit();

-- この入場で進んだ TRAIL（AR の画面で「TRAIL の 2/5 に着きました」と出す）
create or replace function public.gf_trails_reached_by(p_visit uuid)
returns table (trail_id uuid, title text, reached int, stop_count int, completed boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select t.id, t.title, pr.reached, (select count(*)::int from gf_trail_stops s where s.trail_id = t.id),
           pr.completed_at is not null
    from gf_trail_progress pr join gf_trails t on t.id = pr.trail_id
    where pr.user_id = auth.uid() and pr.last_visit_id = p_visit;
end $$;

-- ============ 今と昔 ============
create table if not exists public.gf_snapshots (
  id uuid primary key default gen_random_uuid(),
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  author uuid not null references public.profiles(id) on delete cascade,
  visit_id uuid unique references public.gf_visits(id) on delete set null,
  photo_path text not null,
  visibility text not null default 'friends' check (visibility in ('private', 'friends', 'public')),
  created_at timestamptz not null default now()
);
create index if not exists gf_snapshots_gate on public.gf_snapshots(gate_id, created_at);
create index if not exists gf_snapshots_photo on public.gf_snapshots(photo_path);
alter table public.gf_snapshots enable row level security;

create or replace function public.gf_can_see_snapshot(s public.gf_snapshots, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and (
    s.author = viewer or (
      not gf_blocked(viewer, s.author)
      and gf_active_visit(s.gate_id, viewer) is not null
      and gf_visible_to(s.visibility, s.author, viewer)))
$$;

drop policy if exists "gf snapshots read" on public.gf_snapshots;
create policy "gf snapshots read" on public.gf_snapshots for select to authenticated
  using (public.gf_can_see_snapshot(gf_snapshots, auth.uid()));

-- いまの景色を残す（入場中だけ・1 回の入場で 1 枚）
create or replace function public.gf_add_snapshot(p_visit uuid, p_photo_path text, p_visibility text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v gf_visits := gf_valid_visit(p_visit);
  sid uuid;
begin
  if p_photo_path is null or split_part(p_photo_path, '/', 1) <> auth.uid()::text then
    raise exception 'gf_bad_media_path' using errcode = 'P0001';
  end if;
  begin
    insert into gf_snapshots (gate_id, author, visit_id, photo_path, visibility)
    values (v.gate_id, auth.uid(), v.id, p_photo_path, coalesce(p_visibility, 'friends'))
    returning id into sid;
  exception
    when unique_violation then raise exception 'gf_already_posted' using errcode = 'P0001';
    when check_violation then raise exception 'gf_bad_post' using errcode = 'P0001';
  end;
  return sid;
end $$;

-- 消す（撮った本人）。消した写真の置き場所の名前を返す
create or replace function public.gf_delete_snapshot(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare path text;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_snapshots where id = p_id and author = auth.uid() returning photo_path into path;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return path;
end $$;

-- ============ 通報（TRAIL と今と昔を足した、ここまでの全部） ============
alter table public.gf_reports drop constraint if exists gf_reports_target_kind_check;
alter table public.gf_reports add constraint gf_reports_target_kind_check
  check (target_kind in ('gate', 'graffiti', 'artwork', 'thread', 'reply', 'memory', 'memory_item', 'letter', 'user',
                         'dm', 'trail', 'snapshot'));

create or replace function public.gf_report(p_kind text, p_id uuid, p_reason text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  who uuid;
  what text;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  case p_kind
    when 'gate' then
      select g.owner, g.title into who, what from gf_gates g where g.id = p_id and gf_can_see_gate(g, me);
    when 'graffiti' then
      select x.author, x.body into who, what from gf_graffiti x
      where x.id = p_id and (gf_can_see_graffiti(x, me) or gf_feed_visible(x, me));
    when 'artwork' then
      select a.owner, a.kind || ' ' || a.body into who, what from gf_artworks a where a.id = p_id and gf_can_see_artwork(a, me);
    when 'thread' then
      select t.author, t.title || ' ' || t.body into who, what from gf_board_threads t
      where t.id = p_id and gf_can_see_thread(t, me);
    when 'reply' then
      select r.author, r.body into who, what from gf_board_replies r join gf_board_threads t on t.id = r.thread_id
      where r.id = p_id and r.deleted_at is null and gf_can_see_thread(t, me);
    when 'memory' then
      select m.owner, m.title || ' ' || m.note into who, what from gf_memories m where m.id = p_id and gf_can_see_memory(m, me);
    when 'memory_item' then
      select i.author, i.caption into who, what from gf_memory_items i join gf_memories m on m.id = i.memory_id
      where i.id = p_id and gf_can_see_memory(m, me);
    when 'letter' then
      select l.author, l.body into who, what from gf_letters l
      where l.id = p_id and l.recipient = me and l.opened_at is not null;
    when 'user' then
      select p.id, p.display_name into who, what from profiles p where p.id = p_id;
    when 'trail' then
      select t.owner, t.title || ' ' || t.note into who, what from gf_trails t where t.id = p_id and gf_can_see_trail(t, me);
    when 'snapshot' then
      select s.author, '今と昔の写真' into who, what from gf_snapshots s where s.id = p_id and gf_can_see_snapshot(s, me);
    else
      raise exception 'gf_not_found' using errcode = 'P0001';
  end case;
  if who is null then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  perform gf_take_rate('report', gf_setting('reports_per_day'), 86400);
  begin
    insert into gf_reports (reporter, target_kind, target_id, target_user, reason, note, snapshot)
    values (me, p_kind, p_id, who, p_reason, nullif(btrim(coalesce(p_note, '')), ''), left(what, 500));
  exception when check_violation then
    raise exception 'gf_bad_report' using errcode = 'P0001';
  end;
end $$;

-- ============ 写真を見てよいか（ここまでの全部） ============
create or replace function public.gf_can_read_media(p_path text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    split_part(p_path, '/', 1) = auth.uid()::text
    or exists (select 1 from gf_gates g where g.cover_path = p_path and gf_can_see_gate(g, auth.uid()))
    or exists (select 1 from gf_graffiti x where x.photo_path = p_path
               and (gf_can_see_graffiti(x, auth.uid()) or gf_feed_visible(x, auth.uid())))
    or exists (select 1 from gf_artworks a where a.photo_path = p_path and gf_can_see_artwork(a, auth.uid()))
    or exists (select 1 from gf_letters l where l.photo_path = p_path and l.recipient = auth.uid()
               and l.opened_at is not null and not gf_blocked(l.author, l.recipient))
    or exists (select 1 from gf_memory_items i join gf_memories m on m.id = i.memory_id
               where i.photo_path = p_path and gf_can_see_memory(m, auth.uid()) and not gf_blocked(auth.uid(), i.author))
    or exists (select 1 from gf_snapshots s where s.photo_path = p_path and gf_can_see_snapshot(s, auth.uid())))
$$;

-- 書き出しに TRAIL と今と昔を足す
create or replace function public.gf_export_me_social() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return gf_export_me() || jsonb_build_object(
    'messages_sent', coalesce((select jsonb_agg(jsonb_build_object('to', d.recipient, 'body', d.body, 'at', d.created_at)
                                                order by d.created_at)
                               from gf_dm_messages d where d.sender = auth.uid() and d.deleted_at is null), '[]'),
    'trails', coalesce((select jsonb_agg(to_jsonb(t) || jsonb_build_object(
                          'stops', (select jsonb_agg(s.gate_id order by s.seq) from gf_trail_stops s where s.trail_id = t.id))
                        order by t.created_at) from gf_trails t where t.owner = auth.uid()), '[]'),
    'snapshots', coalesce((select jsonb_agg(to_jsonb(s) - 'visit_id' order by s.created_at) from gf_snapshots s
                           where s.author = auth.uid()), '[]'));
end $$;

-- ============ 呼べる関数を絞る ============
revoke all on function public.gf_trail_on_visit() from public, anon, authenticated;
revoke all on function public.gf_can_see_trail(public.gf_trails, uuid) from public, anon;
revoke all on function public.gf_can_see_snapshot(public.gf_snapshots, uuid) from public, anon;
grant execute on function public.gf_can_see_trail(public.gf_trails, uuid) to authenticated;
grant execute on function public.gf_can_see_snapshot(public.gf_snapshots, uuid) to authenticated;
revoke all on function public.gf_can_read_media(text) from public, anon;
grant execute on function public.gf_can_read_media(text) to authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'gf_create_trail(text, text, text, uuid[])', 'gf_trail_list(uuid)', 'gf_trail_stops_of(uuid)', 'gf_trail_start(uuid)',
    'gf_trail_quit(uuid)', 'gf_delete_trail(uuid)', 'gf_trails_reached_by(uuid)',
    'gf_add_snapshot(uuid, text, text)', 'gf_delete_snapshot(uuid)', 'gf_report(text, uuid, text, text)',
    'gf_export_me_social()']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ======================================================================
-- 0007_gf_investigations.sql
-- ======================================================================
-- GRAFITYGATE：共同調査（その場所の歴史や謎を、ここに来た人どうしで調べる）
--
-- 掲示板の話題の種類に「調べる」を足し、返信に「事実／観察／仮説／噂」のしるしと出典（URL・本の名前など）を付けられるようにする。
-- しるしは書いた人が選ぶ（確かさをサーバーが決めるのではない）。画面では、しるしごとに分けて見られる。
--
-- 使い方：0006 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

alter table public.gf_board_threads drop constraint if exists gf_board_threads_topic_check;
alter table public.gf_board_threads add constraint gf_board_threads_topic_check
  check (topic in ('memory', 'question', 'notice', 'investigation', 'other'));

alter table public.gf_board_replies add column if not exists label text;
alter table public.gf_board_replies add column if not exists source text;
alter table public.gf_board_replies drop constraint if exists gf_board_replies_label_check;
alter table public.gf_board_replies add constraint gf_board_replies_label_check
  check (label is null or label in ('fact', 'observation', 'hypothesis', 'rumor'));
alter table public.gf_board_replies drop constraint if exists gf_board_replies_source_check;
alter table public.gf_board_replies add constraint gf_board_replies_source_check
  check (source is null or char_length(source) between 1 and 300);

-- 返信する（しるしと出典つき。入場中だけ）。調べる話題でなければ、しるしは付けない
create or replace function public.gf_board_reply2(p_visit uuid, p_thread uuid, p_body text, p_label text, p_source text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  rid uuid;
  topic_of text;
begin
  rid := gf_board_reply(p_visit, p_thread, p_body);
  select t.topic into topic_of from gf_board_threads t where t.id = p_thread;
  if topic_of = 'investigation' and (p_label is not null or nullif(btrim(coalesce(p_source, '')), '') is not null) then
    begin
      update gf_board_replies set label = p_label, source = nullif(btrim(coalesce(p_source, '')), '') where id = rid;
    exception when check_violation then
      raise exception 'gf_bad_post' using errcode = 'P0001';
    end;
  end if;
  return rid;
end $$;

-- 返信の一覧（しるしと出典つき。読んだ印も付ける）
create or replace function public.gf_board_replies_of2(p_thread uuid)
returns table (id uuid, author uuid, author_name text, body text, created_at timestamptz, label text, source text)
language plpgsql security definer set search_path = public as $$
begin
  return query
    select r.id, r.author, r.author_name, r.body, r.created_at, x.label, x.source
    from gf_board_replies_of(p_thread) r
    join gf_board_replies x on x.id = r.id;
end $$;

-- 調べる話題の、しるしごとの数（話題の一覧に出す）
create or replace function public.gf_investigation_counts(p_thread uuid)
returns table (label text, n bigint)
language plpgsql stable security definer set search_path = public as $$
declare t gf_board_threads;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into t from gf_board_threads where gf_board_threads.id = p_thread;
  if not found or not gf_can_see_thread(t, auth.uid()) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return query
    select r.label, count(*) from gf_board_replies r
    where r.thread_id = t.id and r.deleted_at is null and r.label is not null
      and (r.author = auth.uid() or (not gf_blocked(auth.uid(), r.author) and gf_active_visit(t.gate_id, auth.uid()) is not null))
    group by r.label;
end $$;

do $$
declare f text;
begin
  foreach f in array array['gf_board_reply2(uuid, uuid, text, text, text)', 'gf_board_replies_of2(uuid)',
                           'gf_investigation_counts(uuid)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
