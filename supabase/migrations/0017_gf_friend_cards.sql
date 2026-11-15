-- Grafity Gate：友達の GATE・グラフィティ図鑑・「来たよ」カード
--
-- 1. 友達が作った GATE（gf_user_gates）：その人のプロフィールから、見てよい GATE の名前・表紙・種類・
--    おおよその位置（約 100m）・作った日を返す。中身（記憶・掲示板など）は今までどおり現地だけ。
-- 2. グラフィティ図鑑（2026-11-15 オーナーが A を選んだ）：カードを書いた本人が「図鑑に載せる」を選んだカードだけ、
--    お互いにフォローしている友達がプロフィールから、写真・GATE の名前・おおよその位置・日付まで見られる。
--    ひとことの文は返さない（現地だけ）。「現地だけ」のカード・写真の無いカード・見せる範囲が自分だけのカードは載らない。
--    前からあるカードは載せない（書いた本人が選び直すまで）。
-- 3. 「来たよ」カード（カード同士のリンク）：GATE の中で、友達（お互いにフォロー）のカードに、自分がこの GATE で
--    残したカードを添えてひとことを送る。届いた人は、どこにいても 2 枚のカードとひとことを見られる
--    （送った人が、自分のカードをその人に見せると決めたもの）。送った人がカードを消すと、リンクも消える。
--
-- 使い方：0016 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

insert into public.gf_settings (key, value, note) values
  ('card_links_per_day', 30, '1 日に送れる「来たよ」の数（1 人）')
on conflict (key) do nothing;

-- 図鑑に載せるか（書いた本人が選ぶ。前からあるカードは載せない）
alter table public.gf_graffiti add column if not exists in_atlas boolean not null default false;

-- ===== 1. 友達が作った GATE =====
create or replace function public.gf_user_gates(p_user uuid)
returns table (id uuid, title text, kind text, cover_path text, approx_lat double precision, approx_lon double precision,
               created_at timestamptz, graffiti_count bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select g.id, g.title, g.kind, g.cover_path,
           round(g.lat::numeric, 3)::double precision, round(g.lon::numeric, 3)::double precision,
           g.created_at,
           (select count(*) from gf_graffiti x where x.gate_id = g.id and x.deleted_at is null)
    from gf_gates g
    where g.owner = p_user and g.status = 'open' and gf_can_see_gate(g, auth.uid())
    order by g.created_at desc
    limit 300;
end $$;

-- ===== 2. グラフィティ図鑑 =====
-- 図鑑で見てよいカードか（書いた本人、または図鑑に載せたカードをお互いにフォローしている友達が）
create or replace function public.gf_atlas_card_visible(x public.gf_graffiti, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and x.deleted_at is null and (
    x.author = viewer
    or (x.in_atlas and not x.local_only and x.photo_path is not null and x.visibility in ('public', 'friends')
        and gf_mutual(x.author, viewer) and not gf_blocked(x.author, viewer)
        and exists (select 1 from gf_gates g where g.id = x.gate_id and gf_can_see_gate(g, viewer))))
$$;

-- 自分のカードを図鑑に載せる／外す
create or replace function public.gf_set_graffiti_atlas(p_id uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_graffiti set in_atlas = coalesce(p_on, false)
    where id = p_id and author = auth.uid() and deleted_at is null;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- その人のグラフィティ図鑑（写真・GATE の名前・おおよその位置・日付。文は返さない）
create or replace function public.gf_user_card_atlas(p_user uuid)
returns table (id uuid, gate_id uuid, gate_title text, gate_kind text, photo_path text,
               approx_lat double precision, approx_lon double precision, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select x.id, g.id, g.title, g.kind, x.photo_path,
           round(g.lat::numeric, 3)::double precision, round(g.lon::numeric, 3)::double precision, x.created_at
    from gf_graffiti x
    join gf_gates g on g.id = x.gate_id
    where x.author = p_user and x.photo_path is not null
      and gf_atlas_card_visible(x, auth.uid())
    order by x.created_at desc
    limit 300;
end $$;

-- ===== 3. 「来たよ」カード =====
create table if not exists public.gf_card_links (
  id uuid primary key default gen_random_uuid(),
  from_card uuid not null references public.gf_graffiti(id) on delete cascade,
  to_card uuid not null references public.gf_graffiti(id) on delete cascade,
  sender uuid not null references public.profiles(id) on delete cascade,
  recipient uuid not null references public.profiles(id) on delete cascade,
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  body text not null default '' check (char_length(body) <= 200),
  created_at timestamptz not null default now(),
  seen_at timestamptz,
  unique (from_card, to_card)
);
create index if not exists gf_card_links_recipient on public.gf_card_links(recipient, created_at desc);
alter table public.gf_card_links enable row level security;
-- 表は直接読ませない（関数で、ブロック・消したカードを確かめてから返す）
revoke all on public.gf_card_links from anon, authenticated;
drop trigger if exists gf_terms_guard on public.gf_card_links;
create trigger gf_terms_guard before insert on public.gf_card_links for each row execute function public.gf_terms_guard();

-- お知らせの種類（あとで足すときも、この「最後の一覧」に足す）
alter table public.gf_notifications drop constraint if exists gf_notifications_kind_check;
alter table public.gf_notifications add constraint gf_notifications_kind_check
  check (kind in ('gate_graffiti', 'gate_artwork', 'board_thread', 'board_reply', 'letter', 'letter_opened',
                  'memory_invite', 'memory_photo', 'like', 'place_map_stale', 'card_link', 'card_comment',
                  'gate_manager'));

-- 送る：自分がこの GATE で残したカードを、友達のカードに添えて
create or replace function public.gf_send_card_link(p_from uuid, p_to uuid, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  a gf_graffiti;
  b gf_graffiti;
  new_id uuid;
  msg text := btrim(coalesce(p_body, ''));
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into a from gf_graffiti where id = p_from and author = me and deleted_at is null;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  select * into b from gf_graffiti where id = p_to and deleted_at is null;
  -- 相手のカードは、いまこの GATE の中で見えているものだけ（現地の入場券が要る）
  if not found or b.author = me or b.gate_id <> a.gate_id or not gf_can_see_graffiti(b, me) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  if not gf_mutual(me, b.author) or gf_blocked(me, b.author) then raise exception 'gf_not_friends' using errcode = 'P0001'; end if;
  if char_length(msg) > 200 then raise exception 'gf_too_long' using errcode = 'P0001'; end if;
  if exists (select 1 from gf_card_links l where l.from_card = a.id and l.to_card = b.id) then
    raise exception 'gf_already_sent' using errcode = 'P0001';
  end if;
  perform gf_take_rate('card_link', gf_setting('card_links_per_day'), 86400);
  insert into gf_card_links (from_card, to_card, sender, recipient, gate_id, body)
    values (a.id, b.id, me, b.author, a.gate_id, msg)
    returning id into new_id;
  perform gf_notify(b.author, 'card_link', me, a.gate_id, new_id);
  return new_id;
end $$;

-- 届いた・送った「来たよ」（2 枚のカードとひとこと）
create or replace function public.gf_my_card_links()
returns table (id uuid, incoming boolean, other uuid, other_name text, gate_id uuid, gate_title text, body text,
               created_at timestamptz, seen boolean,
               from_card uuid, from_body text, from_photo text, from_created_at timestamptz,
               to_card uuid, to_body text, to_photo text, to_created_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select l.id, l.recipient = me,
           case when l.recipient = me then l.sender else l.recipient end,
           p.display_name, g.id, g.title, l.body, l.created_at, l.seen_at is not null,
           fa.id, fa.body, fa.photo_path, fa.created_at,
           tb.id, tb.body, tb.photo_path, tb.created_at
    from gf_card_links l
    join gf_graffiti fa on fa.id = l.from_card and fa.deleted_at is null
    join gf_graffiti tb on tb.id = l.to_card and tb.deleted_at is null
    join gf_gates g on g.id = l.gate_id
    join profiles p on p.id = case when l.recipient = me then l.sender else l.recipient end
    where (l.recipient = me or l.sender = me) and not gf_blocked(l.sender, l.recipient)
    order by l.created_at desc
    limit 200;
end $$;

-- この GATE で、自分が関わる「来たよ」（どのカードに、だれから・だれへ）
create or replace function public.gf_card_links_in(p_gate uuid)
returns table (id uuid, from_card uuid, to_card uuid, sender uuid, recipient uuid, body text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select l.id, l.from_card, l.to_card, l.sender, l.recipient, l.body, l.created_at
    from gf_card_links l
    join gf_graffiti fa on fa.id = l.from_card and fa.deleted_at is null
    join gf_graffiti tb on tb.id = l.to_card and tb.deleted_at is null
    where l.gate_id = p_gate and (l.sender = me or l.recipient = me) and not gf_blocked(l.sender, l.recipient)
    order by l.created_at;
end $$;

create or replace function public.gf_mark_card_links_seen() returns void
language sql security definer set search_path = public as $$
  update gf_card_links set seen_at = now() where recipient = auth.uid() and seen_at is null;
$$;

-- 写真を受け取ってよいか（0010 までの決まりに、図鑑のカードと「来たよ」で届いたカードを足す）
create or replace function public.gf_can_read_media(p_path text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    split_part(p_path, '/', 1) = auth.uid()::text
    or exists (select 1 from gf_gates g where g.cover_path = p_path and gf_can_see_gate(g, auth.uid()))
    or exists (select 1 from gf_graffiti x where x.photo_path = p_path
               and (gf_can_see_graffiti(x, auth.uid()) or gf_feed_visible(x, auth.uid())
                    or gf_atlas_card_visible(x, auth.uid())))
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

do $$
declare f text;
begin
  foreach f in array array['gf_user_gates(uuid)', 'gf_set_graffiti_atlas(uuid, boolean)', 'gf_user_card_atlas(uuid)',
                           'gf_send_card_link(uuid, uuid, text)', 'gf_my_card_links()', 'gf_card_links_in(uuid)',
                           'gf_mark_card_links_seen()', 'gf_can_read_media(text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
revoke all on function public.gf_atlas_card_visible(public.gf_graffiti, uuid) from public, anon, authenticated;
