-- 0018：カードのお気に入り・返信、掲示板の「解決しました」、GATE と TRAIL を名前で探す、友達の TRAIL、
-- TRAIL を直す・リンクで開く、自分の訪問の記録、お知らせの設定。
-- 何度実行しても大丈夫な書き方（run.sh が 2 回流して確かめる）。
-- ここで作り直した関数（あとで足すときは、ここ以降で作り直す）：gf_notify・gf_report・gf_can_read_media・gf_export_me_social。

insert into public.gf_settings (key, value, note) values
  ('card_comments_per_hour', 30, '1 時間に書けるカードへの返信の数（1 人）'),
  ('searches_per_minute', 30, '1 分に名前で探せる回数（1 人）'),
  ('trail_search_radius_m', 5000, '近くの TRAIL を探す広さ（m）')
on conflict (key) do nothing;

-- ============ お知らせの種類の「最後の一覧」（0008・0017・0019 と同じ。足したら 4 か所とも直す） ============
alter table public.gf_notifications drop constraint if exists gf_notifications_kind_check;
alter table public.gf_notifications add constraint gf_notifications_kind_check
  check (kind in ('gate_graffiti', 'gate_artwork', 'board_thread', 'board_reply', 'letter', 'letter_opened',
                  'memory_invite', 'memory_photo', 'like', 'place_map_stale', 'card_link', 'card_comment',
                  'gate_manager'));

-- ============ お知らせの設定（種類ごとに止める。止めた種類は作らない） ============
create table if not exists public.gf_notify_prefs (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  muted text[] not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.gf_notify_prefs enable row level security;
drop policy if exists "gf notify prefs own read" on public.gf_notify_prefs;
create policy "gf notify prefs own read" on public.gf_notify_prefs for select to authenticated using (user_id = auth.uid());

create or replace function public.gf_notify(p_user uuid, p_kind text, p_actor uuid, p_gate uuid, p_ref uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_user is null or p_actor is null or p_user = p_actor or gf_blocked(p_user, p_actor) then return; end if;
  -- 受け取る人が止めた種類は作らない
  if exists (select 1 from gf_notify_prefs n where n.user_id = p_user and p_kind = any(n.muted)) then return; end if;
  -- 同じことの重なり（いいねを押し直した など）は 1 つにする
  if exists (select 1 from gf_notifications n where n.user_id = p_user and n.kind = p_kind and n.actor = p_actor
             and n.ref_id is not distinct from p_ref and n.created_at > now() - interval '1 day') then
    return;
  end if;
  insert into gf_notifications (user_id, kind, actor, gate_id, ref_id) values (p_user, p_kind, p_actor, p_gate, p_ref);
end $$;

create or replace function public.gf_my_notify_mutes() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce((select n.muted from gf_notify_prefs n where n.user_id = auth.uid()), '{}'::text[])
$$;

create or replace function public.gf_set_notify_mute(p_kinds text[], p_muted boolean) returns text[]
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  result text[];
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_kinds is null or cardinality(p_kinds) = 0 or cardinality(p_kinds) > 12
     or exists (select 1 from unnest(p_kinds) k
                where k not in ('gate_graffiti', 'gate_artwork', 'board_thread', 'board_reply', 'letter', 'letter_opened',
                                'memory_invite', 'memory_photo', 'like', 'place_map_stale', 'card_link', 'card_comment')) then
    raise exception 'gf_bad_kind' using errcode = 'P0001';
  end if;
  insert into gf_notify_prefs as n (user_id, muted) values (me, case when coalesce(p_muted, false) then p_kinds else '{}' end)
  on conflict (user_id) do update
    set muted = case when coalesce(p_muted, false)
                     then array(select distinct x from unnest(n.muted || p_kinds) x order by x)
                     else array(select x from unnest(n.muted) x where x <> all(p_kinds) order by x) end,
        updated_at = now()
  returning n.muted into result;
  return result;
end $$;

-- ============ カードのお気に入り（自分だけの印。いいね・図鑑とは別） ============
create table if not exists public.gf_card_saves (
  user_id uuid not null references public.profiles(id) on delete cascade,
  graffiti_id uuid not null references public.gf_graffiti(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, graffiti_id)
);
create index if not exists gf_card_saves_card on public.gf_card_saves(graffiti_id);
alter table public.gf_card_saves enable row level security;
drop policy if exists "gf card saves own read" on public.gf_card_saves;
create policy "gf card saves own read" on public.gf_card_saves for select to authenticated using (user_id = auth.uid());

-- お気に入りにしたカードの写真を、遠くから見てよいか。図鑑と同じ考え：現地だけ・写真なしのカードは出さない。
-- 書いた人の公開範囲・ブロック・GATE が見えるかは、いまの状態で毎回決め直す。文は返さない（現地だけ）。
create or replace function public.gf_saved_card_visible(x public.gf_graffiti, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and x.deleted_at is null and x.photo_path is not null and (
    x.author = viewer or (
      not x.local_only
      and exists (select 1 from gf_card_saves s where s.user_id = viewer and s.graffiti_id = x.id)
      and not gf_blocked(viewer, x.author)
      and gf_visible_to(x.visibility, x.author, viewer)
      and exists (select 1 from gf_gates g where g.id = x.gate_id and gf_can_see_gate(g, viewer))))
$$;

-- お気に入りにする・外す。付けるのは、そのカードがいま見えるとき（GATE の中）だけ。外すのはいつでも。
create or replace function public.gf_save_card(p_card uuid, p_on boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  x public.gf_graffiti;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if coalesce(p_on, false) then
    select * into x from gf_graffiti g where g.id = p_card;
    if x.id is null or not gf_can_see_graffiti(x, me) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
    if (select count(*) from gf_card_saves s where s.user_id = me) >= 1000 then
      raise exception 'gf_too_many' using errcode = 'P0001';
    end if;
    insert into gf_card_saves (user_id, graffiti_id) values (me, p_card) on conflict do nothing;
    return true;
  end if;
  delete from gf_card_saves s where s.user_id = me and s.graffiti_id = p_card;
  return false;
end $$;

-- 自分のお気に入り：GATE の名前・おおよその場所・日付・写真（見てよいときだけ）。文は自分のカードだけ。
create or replace function public.gf_my_saved_cards()
returns table (id uuid, gate_id uuid, gate_title text, author uuid, author_name text, body text, photo_path text,
               mine boolean, created_at timestamptz, saved_at timestamptz,
               approx_lat double precision, approx_lon double precision)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select x.id, x.gate_id, g.title, x.author, p.display_name,
           case when x.author = me then x.body end,
           case when gf_saved_card_visible(x, me) then x.photo_path end,
           x.author = me, x.created_at, s.created_at,
           round(g.lat::numeric, 3)::double precision, round(g.lon::numeric, 3)::double precision
    from gf_card_saves s
    join gf_graffiti x on x.id = s.graffiti_id and x.deleted_at is null
    join gf_gates g on g.id = x.gate_id and gf_can_see_gate(g, me)
    join profiles p on p.id = x.author
    where s.user_id = me and not gf_blocked(me, x.author)
    order by s.created_at desc
    limit 500;
end $$;

-- ============ カードへの返信（GATE の中の会話。読めるのはカードが見える人＝現地・書いた本人） ============
create table if not exists public.gf_card_comments (
  id uuid primary key default gen_random_uuid(),
  graffiti_id uuid not null references public.gf_graffiti(id) on delete cascade,
  author uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 200),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index if not exists gf_card_comments_card on public.gf_card_comments(graffiti_id, created_at);
create index if not exists gf_card_comments_author on public.gf_card_comments(author);
alter table public.gf_card_comments enable row level security;
-- 表は直接読ませない（gf_card_comments_of が返す）
drop trigger if exists gf_terms_guard on public.gf_card_comments;
create trigger gf_terms_guard before insert on public.gf_card_comments
  for each row execute function public.gf_terms_guard();

create or replace function public.gf_card_comment(p_card uuid, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  x public.gf_graffiti;
  cid uuid;
  other uuid;
  text_ text := btrim(coalesce(p_body, ''));
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into x from gf_graffiti g where g.id = p_card;
  -- カードが見える＝書いた本人か、その GATE の入場券がある人
  if x.id is null or not gf_can_see_graffiti(x, me) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  if char_length(text_) = 0 then raise exception 'gf_bad_body' using errcode = 'P0001'; end if;
  if char_length(text_) > 200 then raise exception 'gf_too_long' using errcode = 'P0001'; end if;
  perform gf_take_rate('card_comment', gf_setting('card_comments_per_hour'), 3600);
  insert into gf_card_comments (graffiti_id, author, body) values (x.id, me, text_) returning id into cid;
  if x.author <> me then
    perform gf_notify(x.author, 'card_comment', me, x.gate_id, x.id);
  else
    -- 書いた本人が返したときは、それまでに返信した人へ（本文は入れない。読むのは現地で）
    for other in select distinct c.author from gf_card_comments c
                 where c.graffiti_id = x.id and c.author <> me and c.deleted_at is null loop
      perform gf_notify(other, 'card_comment', me, x.gate_id, x.id);
    end loop;
  end if;
  return cid;
end $$;

create or replace function public.gf_card_comments_of(p_card uuid)
returns table (id uuid, author uuid, author_name text, body text, created_at timestamptz, mine boolean, can_delete boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  x public.gf_graffiti;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into x from gf_graffiti g where g.id = p_card;
  if x.id is null or not gf_can_see_graffiti(x, me) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return query
    select c.id, c.author, p.display_name, c.body, c.created_at, c.author = me, (c.author = me or x.author = me)
    from gf_card_comments c
    join profiles p on p.id = c.author
    where c.graffiti_id = x.id and c.deleted_at is null and not gf_blocked(me, c.author)
    order by c.created_at
    limit 300;
end $$;

-- 消せるのは、返信を書いた本人と、カードを書いた本人（遠くからでも）
create or replace function public.gf_delete_card_comment(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_card_comments c set deleted_at = now()
  where c.id = p_id and c.deleted_at is null
    and (c.author = me or exists (select 1 from gf_graffiti x where x.id = c.graffiti_id and x.author = me));
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- GATE の中のカードごとの、返信の数と、自分のお気に入りか
create or replace function public.gf_card_extras(p_gate uuid)
returns table (graffiti_id uuid, comments int, saved boolean)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select x.id,
           (select count(*)::int from gf_card_comments c
              where c.graffiti_id = x.id and c.deleted_at is null and not gf_blocked(me, c.author)),
           exists (select 1 from gf_card_saves s where s.user_id = me and s.graffiti_id = x.id)
    from gf_graffiti x
    where x.gate_id = p_gate and gf_can_see_graffiti(x, me);
end $$;

-- ============ 掲示板の「解決しました」（質問・調べるのスレッド。立てた本人と GATE を作った人） ============
alter table public.gf_board_threads add column if not exists resolved_at timestamptz;

create or replace function public.gf_board_resolve(p_thread uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_board_threads t
     set resolved_at = case when coalesce(p_on, false) then coalesce(t.resolved_at, now()) end
   where t.id = p_thread and t.deleted_at is null
     and (t.author = me or exists (select 1 from gf_gates g where g.id = t.gate_id and g.owner = me));
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

create or replace function public.gf_board_list3(p_gate uuid)
returns table (id uuid, author uuid, author_name text, topic text, title text, body text, pinned boolean,
               reply_count int, last_activity_at timestamptz, created_at timestamptz, unread boolean,
               edited_at timestamptz, resolved boolean)
language plpgsql security definer set search_path = public as $$
begin
  return query
    select l.id, l.author, l.author_name, l.topic, l.title, l.body, l.pinned, l.reply_count,
           l.last_activity_at, l.created_at, l.unread, l.edited_at, x.resolved_at is not null
    from gf_board_list2(p_gate) l
    join gf_board_threads x on x.id = l.id
    order by l.pinned desc, l.last_activity_at desc;
end $$;

-- ============ GATE を名前で探す（見てよい GATE の、名前・表紙・おおよその場所だけ。中身は現地だけ） ============
create or replace function public.gf_search_like(p_query text) returns text
language sql immutable as $$
  select '%' || replace(replace(replace(p_query, '\', '\\'), '%', '\%'), '_', '\_') || '%'
$$;

create or replace function public.gf_search_gates(p_query text, p_lat double precision default null,
                                                  p_lon double precision default null)
returns table (id uuid, title text, kind text, cover_path text, owner uuid, owner_name text, mine boolean,
               friend boolean, approx_lat double precision, approx_lon double precision, distance_m double precision,
               created_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  q text := btrim(coalesce(p_query, ''));
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if char_length(q) < 1 or char_length(q) > 40 then raise exception 'gf_bad_query' using errcode = 'P0001'; end if;
  perform gf_take_rate('search', gf_setting('searches_per_minute'), 60);
  return query
    select z.id, z.title, z.kind, z.cover_path, z.owner, z.owner_name, z.mine, z.friend, z.alat, z.alon,
           case when p_lat is null or p_lon is null then null
                else gf_distance_m(p_lat, p_lon, z.alat, z.alon) end as dist,
           z.created_at
    from (
      select g.id, g.title, g.kind, g.cover_path, g.owner, p.display_name as owner_name, g.owner = me as mine,
             gf_mutual(me, g.owner) as friend,
             round(g.lat::numeric, 3)::double precision as alat, round(g.lon::numeric, 3)::double precision as alon,
             g.created_at
      from gf_gates g
      join profiles p on p.id = g.owner
      where g.status = 'open' and gf_can_see_gate(g, me) and not gf_blocked(me, g.owner)
        and g.title ilike gf_search_like(q) escape '\'
    ) z
    order by z.mine desc, z.friend desc, dist nulls last, z.created_at desc
    limit 30;
end $$;

-- ============ TRAIL：一覧の行（gf_trail_list と同じ形）、友達の TRAIL、探す、リンクで開く、直す ============
create or replace function public.gf_trail_rows(p_ids uuid[])
returns table (id uuid, owner uuid, owner_name text, title text, note text, visibility text, created_at timestamptz,
               stop_count int, cover_path text, reached int, completed boolean, started boolean)
language sql stable security definer set search_path = public as $$
  select t.id, t.owner, p.display_name, t.title, t.note, t.visibility, t.created_at,
         (select count(*)::int from gf_trail_stops s where s.trail_id = t.id),
         (select g.cover_path from gf_trail_stops s join gf_gates g on g.id = s.gate_id
            where s.trail_id = t.id and gf_can_see_gate(g, auth.uid()) and g.cover_path is not null
            order by s.seq limit 1),
         coalesce(pr.reached, 0), pr.completed_at is not null, pr.user_id is not null
  from gf_trails t
  join profiles p on p.id = t.owner
  left join gf_trail_progress pr on pr.trail_id = t.id and pr.user_id = auth.uid()
  where t.id = any(p_ids) and gf_can_see_trail(t, auth.uid())
$$;

-- その人が作った TRAIL のうち、自分が見てよいもの（友達のプロフィール）
create or replace function public.gf_user_trails(p_user uuid)
returns table (id uuid, owner uuid, owner_name text, title text, note text, visibility text, created_at timestamptz,
               stop_count int, cover_path text, reached int, completed boolean, started boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select r.* from gf_trail_rows(array(select t.id from gf_trails t where t.owner = p_user)) r
    order by r.created_at desc
    limit 100;
end $$;

-- リンク（grafitygate://trail/<id>）で開いた TRAIL。見てよくなければ何も返さない
create or replace function public.gf_trail_get(p_trail uuid)
returns table (id uuid, owner uuid, owner_name text, title text, note text, visibility text, created_at timestamptz,
               stop_count int, cover_path text, reached int, completed boolean, started boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query select r.* from gf_trail_rows(array[p_trail]) r;
end $$;

-- 名前で探す。名前が空なら、いまいる所の近く（trail_search_radius_m）に地点がある TRAIL
create or replace function public.gf_trail_search(p_query text, p_lat double precision default null,
                                                  p_lon double precision default null)
returns table (id uuid, owner uuid, owner_name text, title text, note text, visibility text, created_at timestamptz,
               stop_count int, cover_path text, reached int, completed boolean, started boolean)
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  q text := btrim(coalesce(p_query, ''));
  ids uuid[];
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if char_length(q) > 40 then raise exception 'gf_bad_query' using errcode = 'P0001'; end if;
  if q = '' and (p_lat is null or p_lon is null) then return; end if;
  perform gf_take_rate('search', gf_setting('searches_per_minute'), 60);
  select array_agg(z.id order by z.d nulls last, z.created_at desc) into ids
  from (
    select t.id, t.created_at,
           min(case when p_lat is null or p_lon is null then null
                    else gf_distance_m(p_lat, p_lon, g.lat, g.lon) end) as d
    from gf_trails t
    join gf_trail_stops s on s.trail_id = t.id
    join gf_gates g on g.id = s.gate_id
    where gf_can_see_trail(t, me) and not gf_blocked(me, t.owner)
      and (q = '' or t.title ilike gf_search_like(q) escape '\')
    group by t.id, t.created_at
    having q <> '' or min(gf_distance_m(p_lat, p_lon, g.lat, g.lon)) <= gf_setting('trail_search_radius_m')
    order by d nulls last, t.created_at desc
    limit 30
  ) z;
  if ids is null then return; end if;
  return query select r.* from gf_trail_rows(ids) r order by array_position(ids, r.id);
end $$;

-- 作った本人が、名前・説明・公開範囲を直す（地点の並びは、歩いている人の進み具合が崩れるので変えない）
create or replace function public.gf_update_trail(p_trail uuid, p_title text, p_note text, p_visibility text)
returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  begin
    update gf_trails t
       set title = btrim(coalesce(p_title, '')), note = coalesce(p_note, ''),
           visibility = coalesce(p_visibility, t.visibility)
     where t.id = p_trail and t.owner = me;
  exception when check_violation then
    raise exception 'gf_bad_trail' using errcode = 'P0001';
  end;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- ============ 自分がその GATE に入った日（再訪の記録。本人だけ） ============
create or replace function public.gf_my_visit_history(p_gate uuid)
returns table (visited_at timestamptz)
language sql stable security definer set search_path = public as $$
  select v.created_at from gf_visits v
  where v.user_id = auth.uid() and v.gate_id = p_gate
  order by v.created_at desc
  limit 200
$$;

-- ============ 通報（カードへの返信を足した、ここまでの全部） ============
alter table public.gf_reports drop constraint if exists gf_reports_target_kind_check;
alter table public.gf_reports add constraint gf_reports_target_kind_check
  check (target_kind in ('gate', 'graffiti', 'artwork', 'thread', 'reply', 'memory', 'memory_item', 'letter', 'user',
                         'dm', 'trail', 'snapshot', 'card_comment'));

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
    when 'card_comment' then
      select c.author, c.body into who, what from gf_card_comments c join gf_graffiti x on x.id = c.graffiti_id
      where c.id = p_id and c.deleted_at is null and gf_can_see_graffiti(x, me);
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

-- ============ 写真を見てよいか（ここまでの全部。お気に入りにしたカードの写真を足す） ============
create or replace function public.gf_can_read_media(p_path text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    split_part(p_path, '/', 1) = auth.uid()::text
    or exists (select 1 from gf_gates g where g.cover_path = p_path and gf_can_see_gate(g, auth.uid()))
    or exists (select 1 from gf_graffiti x where x.photo_path = p_path
               and (gf_can_see_graffiti(x, auth.uid()) or gf_feed_visible(x, auth.uid())
                    or gf_atlas_card_visible(x, auth.uid()) or gf_saved_card_visible(x, auth.uid())))
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
    or exists (select 1 from gf_snapshots s where s.photo_path = p_path and gf_can_see_snapshot(s, auth.uid())))
$$;

-- ============ 書き出し（カードへの返信・お気に入り・お知らせの設定を足す） ============
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
                           where s.author = auth.uid()), '[]'),
    'card_comments', coalesce((select jsonb_agg(jsonb_build_object('card', c.graffiti_id, 'body', c.body, 'at', c.created_at)
                                                order by c.created_at)
                               from gf_card_comments c where c.author = auth.uid() and c.deleted_at is null), '[]'),
    'saved_cards', coalesce((select jsonb_agg(jsonb_build_object('card', s.graffiti_id, 'at', s.created_at)
                                              order by s.created_at)
                             from gf_card_saves s where s.user_id = auth.uid()), '[]'),
    'muted_notifications', to_jsonb(gf_my_notify_mutes()));
end $$;

-- ============ 呼べる関数を絞る ============
revoke all on function public.gf_saved_card_visible(public.gf_graffiti, uuid) from public, anon, authenticated;
revoke all on function public.gf_trail_rows(uuid[]) from public, anon, authenticated;
revoke all on function public.gf_search_like(text) from public, anon, authenticated;
revoke all on function public.gf_notify(uuid, text, uuid, uuid, uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'gf_my_notify_mutes()', 'gf_set_notify_mute(text[], boolean)',
    'gf_save_card(uuid, boolean)', 'gf_my_saved_cards()',
    'gf_card_comment(uuid, text)', 'gf_card_comments_of(uuid)', 'gf_delete_card_comment(uuid)', 'gf_card_extras(uuid)',
    'gf_board_resolve(uuid, boolean)', 'gf_board_list3(uuid)',
    'gf_search_gates(text, double precision, double precision)',
    'gf_user_trails(uuid)', 'gf_trail_get(uuid)', 'gf_trail_search(text, double precision, double precision)',
    'gf_update_trail(uuid, text, text, text)', 'gf_my_visit_history(uuid)',
    'gf_report(text, uuid, text, text)', 'gf_can_read_media(text)', 'gf_export_me_social()']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
