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
