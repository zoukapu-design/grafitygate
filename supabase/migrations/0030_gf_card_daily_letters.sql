-- グラフィティカードは 1 つの GATE に 1 人 1 日 1 枚（2026-11-19 オーナー「1 日に 1 人が 1 つのゲートに残せるカードは 1 つまで」）。
-- 「1 日」は日本時間の 0 時で切り替える（gf_card_day）。消したカードも数える（消して作り直すのを繰り返せないように）。
-- 手紙には写真ではなく、自分のグラフィティカードを添える（gf_letters.card_id・gf_write_letter2・gf_open_letter2）。

create or replace function public.gf_card_day(p_at timestamptz) returns date
language sql stable set search_path = public as $$
  select (p_at at time zone 'Asia/Tokyo')::date
$$;

-- 入場中のグラフィティカードを残す。1 回の入場で 1 枚、同じ GATE は 1 日 1 枚（日本時間。消したカードも数える）。
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
             and gf_card_day(created_at) = gf_card_day(now())) then
    raise exception 'gf_card_today' using errcode = 'P0001';
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

-- 今日この GATE にカードを残したか（残したカードの ID・次に残せる時刻）
create or replace function public.gf_my_card_today(p_gate uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  c gf_graffiti;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into c from gf_graffiti
  where author = me and gate_id = p_gate and gf_card_day(created_at) = gf_card_day(now())
  order by created_at desc limit 1;
  return jsonb_build_object(
    'posted', c.id is not null,
    'card_id', case when c.deleted_at is null then c.id end,
    'next_at', (gf_card_day(now()) + 1)::timestamp at time zone 'Asia/Tokyo');
end $$;

-- 自分のグラフィティカード（新しい順。手紙に添える・アルバムに入れるときに選ぶ）
create or replace function public.gf_my_cards(p_limit int default 60)
returns table (id uuid, gate_id uuid, gate_title text, body text, title text, photo_path text, finish text,
               created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select x.id, x.gate_id, g.title, x.body, x.title, x.photo_path, x.finish, x.created_at
    from gf_graffiti x join gf_gates g on g.id = x.gate_id
    where x.author = auth.uid() and x.deleted_at is null
    order by x.created_at desc
    limit least(greatest(coalesce(p_limit, 60), 1), 200);
end $$;

-- 手紙に添えるカード（書いた人の自分のカードだけ）
alter table public.gf_letters add column if not exists card_id uuid references public.gf_graffiti(id) on delete set null;
create index if not exists gf_letters_card on public.gf_letters(card_id);

create or replace function public.gf_write_letter2(p_visit uuid, p_recipient uuid, p_body text, p_card uuid,
                                                   p_open_at timestamptz, p_onsite boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  lid uuid;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_card is not null and not exists (select 1 from gf_graffiti where id = p_card and author = me and deleted_at is null) then
    raise exception 'gf_bad_card' using errcode = 'P0001';
  end if;
  -- 宛先・日時・数の決まりは前の手紙と同じ（写真は付けない）
  lid := gf_write_letter(p_visit, p_recipient, p_body, null, p_open_at, p_onsite);
  update gf_letters set card_id = p_card where id = lid;
  return lid;
end $$;

-- 手紙を開く（前の gf_open_letter と同じ決まり）。添えたカードも返す（書いた人が消したら card_gone）
create or replace function public.gf_open_letter2(p_letter uuid)
returns table (id uuid, author_name text, recipient_name text, body text, photo_path text,
               created_at timestamptz, opened_at timestamptz,
               card_id uuid, card_title text, card_body text, card_photo text, card_finish text,
               card_gate_id uuid, card_gate_title text, card_created_at timestamptz, card_gone boolean)
language plpgsql security definer set search_path = public as $$
begin
  perform * from gf_open_letter(p_letter);
  return query
    select l.id, pa.display_name, pr.display_name, l.body, l.photo_path, l.created_at, l.opened_at,
           case when x.deleted_at is null and x.author = l.author then x.id end,
           case when x.deleted_at is null and x.author = l.author then x.title end,
           case when x.deleted_at is null and x.author = l.author then x.body end,
           case when x.deleted_at is null and x.author = l.author then x.photo_path end,
           case when x.deleted_at is null and x.author = l.author then x.finish end,
           case when x.deleted_at is null and x.author = l.author then x.gate_id end,
           case when x.deleted_at is null and x.author = l.author then g.title end,
           case when x.deleted_at is null and x.author = l.author then x.created_at end,
           l.card_id is not null and (x.id is null or x.deleted_at is not null or x.author <> l.author)
    from gf_letters l
    join profiles pa on pa.id = l.author
    join profiles pr on pr.id = l.recipient
    left join gf_graffiti x on x.id = l.card_id
    left join gf_gates g on g.id = x.gate_id
    where l.id = p_letter;
end $$;

-- 写真を受け取ってよいか（0024 に、手紙に添えたカードの写真を足したもの。開けた宛先の人）
create or replace function public.gf_can_read_media(p_path text) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    split_part(p_path, '/', 1) = auth.uid()::text
    or exists (select 1 from gf_gates g where g.cover_path = p_path and gf_can_see_gate(g, auth.uid()))
    or exists (select 1 from gf_graffiti x where x.photo_path = p_path
               and (gf_can_read_graffiti(x, auth.uid()) or gf_feed_visible(x, auth.uid())
                    or gf_peek_card_visible(x, auth.uid())
                    or gf_atlas_card_visible(x, auth.uid()) or gf_saved_card_visible(x, auth.uid())
                    or gf_nearby_card_visible(x, auth.uid())))
    or exists (select 1 from gf_card_links l join gf_graffiti x on x.id = l.from_card
               where x.photo_path = p_path and x.deleted_at is null
                 and l.recipient = auth.uid() and not gf_blocked(l.sender, l.recipient))
    or exists (select 1 from gf_artworks a where (a.photo_path = p_path or a.thumb_path = p_path)
               and gf_can_see_artwork(a, auth.uid()))
    or exists (select 1 from gf_letters l where l.photo_path = p_path and l.recipient = auth.uid()
               and l.opened_at is not null and not gf_blocked(l.author, l.recipient))
    or exists (select 1 from gf_letters l join gf_graffiti x on x.id = l.card_id
               where x.photo_path = p_path and x.author = l.author and x.deleted_at is null
                 and l.recipient = auth.uid() and l.opened_at is not null and not gf_blocked(l.author, l.recipient))
    or exists (select 1 from gf_memory_items i join gf_memories m on m.id = i.memory_id
               where (i.photo_path = p_path or i.thumb_path = p_path)
                 and gf_can_see_memory(m, auth.uid()) and not gf_blocked(auth.uid(), i.author))
    or exists (select 1 from gf_snapshots s where s.photo_path = p_path and gf_can_see_snapshot(s, auth.uid()))
    or exists (select 1 from gf_dm_messages d where d.photo_path = p_path and d.deleted_at is null
               and (d.sender = auth.uid() or d.recipient = auth.uid()) and not gf_blocked(d.sender, d.recipient))
    or exists (select 1 from gf_dm_messages d join gf_graffiti x on x.id = d.card_id
               where x.photo_path = p_path and x.author = d.sender and x.deleted_at is null and d.deleted_at is null
                 and d.recipient = auth.uid() and not gf_blocked(d.sender, d.recipient)))
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'gf_card_day(timestamptz)', 'gf_my_card_today(uuid)', 'gf_my_cards(int)',
    'gf_write_letter2(uuid, uuid, text, uuid, timestamptz, boolean)', 'gf_open_letter2(uuid)', 'gf_can_read_media(text)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
