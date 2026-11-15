-- 0022：グラフィティカードを友達に送る（メッセージにカードを添える）。
-- 送れるのは自分のカードだけ（ほかの人のカードは、書いた人の見せる範囲を越えて広げない）。
-- 受け取った人に見えるのは、送った人のカードの写真・ひとこと・GATE の名前・日付。書いた人が消したら見えなくなる。
-- GATE の中（ほかの人のカード・掲示板・アルバム）は、これまでどおり現地だけ。
-- 何度実行しても大丈夫な書き方。ここで作り直した関数：gf_can_read_media（あとで足すときは、ここ以降で作り直す）。

alter table public.gf_dm_messages add column if not exists card_id uuid references public.gf_graffiti(id) on delete set null;
alter table public.gf_dm_messages drop constraint if exists gf_dm_messages_content_check;
alter table public.gf_dm_messages add constraint gf_dm_messages_content_check
  check (char_length(body) <= 1000
         and (char_length(btrim(body)) >= 1 or photo_path is not null or card_id is not null));
create index if not exists gf_dm_messages_card on public.gf_dm_messages(card_id) where card_id is not null;

-- 自分のカードを、お互いにフォローの友達に送る
create or replace function public.gf_dm_send_card(p_to uuid, p_card uuid, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  mid uuid;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_to is null or p_to = me or not gf_mutual(me, p_to) or gf_blocked(me, p_to) then
    raise exception 'gf_bad_recipient' using errcode = 'P0001';
  end if;
  if not exists (select 1 from gf_graffiti x where x.id = p_card and x.author = me and x.deleted_at is null) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  perform gf_take_rate('dm', gf_setting('dm_per_hour'), 3600);
  begin
    insert into gf_dm_messages (sender, recipient, body, card_id)
    values (me, p_to, btrim(coalesce(p_body, '')), p_card)
    returning id into mid;
  exception when check_violation then
    raise exception 'gf_bad_post' using errcode = 'P0001';
  end;
  return mid;
end $$;

-- メッセージ（写真・カードつき）。カードは、送った人が書いた・消していないものだけ中身を返す
create or replace function public.gf_dm_messages_with3(p_other uuid)
returns table (id uuid, sender uuid, body text, photo_path text, created_at timestamptz, read_at timestamptz,
               card_id uuid, card_body text, card_photo text, card_gate_id uuid, card_gate_title text,
               card_created_at timestamptz, card_gone boolean)
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if gf_blocked(me, p_other) then return; end if;
  update gf_dm_messages d set read_at = now()
    where d.sender = p_other and d.recipient = me and d.read_at is null;
  return query
    select z.id, z.sender, z.body, z.photo_path, z.created_at, z.read_at,
           z.cid, z.cbody, z.cphoto, z.cgate, z.ctitle, z.ccreated, z.cgone
    from (
      select d.id, d.sender, d.body, d.photo_path, d.created_at, d.read_at,
             case when ok.id is not null then d.card_id end as cid,
             ok.body as cbody, ok.photo_path as cphoto, ok.gate_id as cgate, g.title as ctitle, ok.created_at as ccreated,
             (d.card_id is not null and ok.id is null) or (d.card_id is null and d.body = '' and d.photo_path is null) as cgone
      from gf_dm_messages d
      left join gf_graffiti ok on ok.id = d.card_id and ok.author = d.sender and ok.deleted_at is null
      left join gf_gates g on g.id = ok.gate_id
      where ((d.sender = me and d.recipient = p_other) or (d.sender = p_other and d.recipient = me))
        and d.deleted_at is null
      order by d.created_at desc
      limit 200
    ) z
    order by z.created_at;
end $$;

-- 相手ごとの一覧（いちばん新しいメッセージの種類つき：text・photo・card）
create or replace function public.gf_dm_threads2()
returns table (other uuid, other_name text, last_body text, last_at timestamptz, last_from_me boolean,
               unread bigint, can_send boolean, last_kind text)
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
      select distinct on (m.o) m.o, m.body, m.created_at, m.sender = me as from_me,
             case when m.card_id is not null then 'card' when m.photo_path is not null then 'photo' else 'text' end as kind
      from mine m order by m.o, m.created_at desc
    )
    select l.o, p.display_name, l.body, l.created_at, l.from_me,
           (select count(*) from mine m where m.o = l.o and m.recipient = me and m.read_at is null),
           gf_mutual(me, l.o), l.kind
    from lastmsg l join profiles p on p.id = l.o
    where not gf_blocked(me, l.o)
    order by l.created_at desc;
end $$;

-- ============ 写真を見てよいか（ここまでの全部。メッセージで受け取ったカードの写真を足す） ============
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
               and (d.sender = auth.uid() or d.recipient = auth.uid()) and not gf_blocked(d.sender, d.recipient))
    or exists (select 1 from gf_dm_messages d join gf_graffiti x on x.id = d.card_id
               where x.photo_path = p_path and x.author = d.sender and x.deleted_at is null and d.deleted_at is null
                 and d.recipient = auth.uid() and not gf_blocked(d.sender, d.recipient)))
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'gf_dm_send_card(uuid, uuid, text)', 'gf_dm_messages_with3(uuid)', 'gf_dm_threads2()', 'gf_can_read_media(text)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
