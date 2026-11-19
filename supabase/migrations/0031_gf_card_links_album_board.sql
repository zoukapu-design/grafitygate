-- グラフィティカードを、アルバムと掲示板にもつなげる（2026-11-19 オーナー「ほかの機能もカードとつなげて楽しめるように」）。
-- ・アルバムに「カードを入れる」（gf_add_memory_card）。入れられるのは自分のカードだけ。写真と同じ決まり（仲間・現地か 72 時間）。
--   ファイルはカードのものをそのまま使い、アルバムの欄 photo_path には 'card:<カードの ID>' を入れる
--   （前のアプリがアルバムを消すときに、カードの写真のファイルまで消さないように）。カードを消すと、アルバムからも外れる。
-- ・掲示板の話題・返信に「カードを添える」（gf_board_attach_card）。添えられるのは書いた本人の自分のカードだけ。
--   読めるのは話題を読める人（gf_can_read_thread）。

-- アルバム ----------------------------------------------------------------
alter table public.gf_memory_items add column if not exists card_id uuid references public.gf_graffiti(id) on delete cascade;
create index if not exists gf_memory_items_card on public.gf_memory_items(card_id);
alter table public.gf_memory_items drop constraint if exists gf_memory_items_media_check;
alter table public.gf_memory_items add constraint gf_memory_items_media_check check (
  (media_kind = 'photo' and thumb_path is null and duration is null and card_id is null)
  or (media_kind = 'video' and thumb_path is not null and duration between 0.5 and 15.5 and card_id is null)
  or (media_kind = 'voice' and thumb_path is null and duration between 0.5 and 60.5 and card_id is null)
  or (media_kind = 'card' and thumb_path is null and duration is null and card_id is not null));

create or replace function public.gf_add_memory_card(p_memory uuid, p_card uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  m gf_memories;
  c gf_graffiti;
  iid uuid;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into m from gf_memories where id = p_memory for update;
  if not found or not gf_is_memory_member(m.id, me) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  if gf_active_visit(m.gate_id, me) is null
     and m.created_at < now() - make_interval(hours => gf_setting('memory_join_hours')::int) then
    raise exception 'gf_visit_invalid' using errcode = 'P0001';
  end if;
  select * into c from gf_graffiti where id = p_card and author = me and deleted_at is null;
  if not found then raise exception 'gf_bad_card' using errcode = 'P0001'; end if;
  if exists (select 1 from gf_memory_items where memory_id = m.id and card_id = c.id) then
    raise exception 'gf_already_added' using errcode = 'P0001';
  end if;
  if (select count(*) from gf_memory_items where memory_id = m.id) >= gf_setting('memory_items_max')
     or (select count(*) from gf_memory_items where memory_id = m.id and author = me)
        >= gf_setting('memory_items_per_person') then
    raise exception 'gf_memory_full' using errcode = 'P0001';
  end if;
  insert into gf_memory_items (memory_id, author, photo_path, caption, media_kind, card_id)
  values (m.id, me, 'card:' || c.id::text, '', 'card', c.id)
  returning id into iid;
  return iid;
end $$;

-- アルバムに入れたカードの中身（アルバムが見える人だけ。カードを書いた本人が入れたものだけ）
create or replace function public.gf_memory_cards(p_memory uuid)
returns table (item_id uuid, card_id uuid, title text, body text, photo_path text, finish text,
               gate_title text, author_name text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select i.id, x.id, x.title, x.body, x.photo_path, x.finish, g.title, p.display_name, x.created_at
    from gf_memory_items i
    join gf_memories m on m.id = i.memory_id
    join gf_graffiti x on x.id = i.card_id
    join gf_gates g on g.id = x.gate_id
    join profiles p on p.id = x.author
    where i.memory_id = p_memory and gf_can_see_memory(m, auth.uid()) and not gf_blocked(auth.uid(), i.author)
      and x.deleted_at is null and x.author = i.author;
end $$;

-- 表紙は、声ではないいちばん古いもの（動画なら表紙の絵、カードならカードの写真）
create or replace function public.gf_memory_cover(p_memory uuid, viewer uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(i.thumb_path, case when i.media_kind = 'card' then x.photo_path else i.photo_path end)
  from gf_memory_items i left join gf_graffiti x on x.id = i.card_id
  where i.memory_id = p_memory and i.media_kind <> 'voice' and not gf_blocked(viewer, i.author)
    and (i.media_kind <> 'card' or (x.deleted_at is null and x.photo_path is not null))
  order by i.created_at limit 1
$$;

-- 消す：カードを外したときは、ファイルの名前を返さない（カードの写真は消さない）
create or replace function public.gf_delete_memory_media(p_item uuid) returns text[]
language plpgsql security definer set search_path = public as $$
declare
  main_path text;
  thumb text;
  kind text;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_memory_items i
  where i.id = p_item
    and (i.author = auth.uid() or exists (select 1 from gf_memories m where m.id = i.memory_id and m.owner = auth.uid()))
  returning i.photo_path, i.thumb_path, i.media_kind into main_path, thumb, kind;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  if kind = 'card' then return '{}'::text[]; end if;
  return array_remove(array[main_path, thumb], null);
end $$;

-- 前の消し方（gf_delete_memory_item）も、カードのときは名前を返さない
create or replace function public.gf_delete_memory_item(p_item uuid) returns text
language plpgsql security definer set search_path = public as $$
declare
  path text;
  kind text;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_memory_items i
  where i.id = p_item
    and (i.author = auth.uid() or exists (select 1 from gf_memories m where m.id = i.memory_id and m.owner = auth.uid()))
  returning i.photo_path, i.media_kind into path, kind;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return case when kind = 'card' then null else path end;
end $$;

-- 掲示板 ------------------------------------------------------------------
alter table public.gf_board_threads add column if not exists card_id uuid references public.gf_graffiti(id) on delete set null;
alter table public.gf_board_replies add column if not exists card_id uuid references public.gf_graffiti(id) on delete set null;
create index if not exists gf_board_threads_card on public.gf_board_threads(card_id);
create index if not exists gf_board_replies_card on public.gf_board_replies(card_id);

-- 話題・返信にカードを添える・付け替える・外す（p_card が null なら外す）。書いた本人だけ
create or replace function public.gf_board_attach_card(p_kind text, p_id uuid, p_card uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_card is not null and not exists (select 1 from gf_graffiti where id = p_card and author = me and deleted_at is null) then
    raise exception 'gf_bad_card' using errcode = 'P0001';
  end if;
  if p_kind = 'thread' then
    update gf_board_threads set card_id = p_card where id = p_id and author = me and deleted_at is null;
  elsif p_kind = 'reply' then
    update gf_board_replies set card_id = p_card where id = p_id and author = me and deleted_at is null;
  else
    raise exception 'gf_bad_kind' using errcode = 'P0001';
  end if;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- 添えたカード：p_thread が null なら GATE の話題のもの、話題を決めたらその話題と返信のもの（読める人だけ）
create or replace function public.gf_board_cards(p_gate uuid, p_thread uuid default null)
returns table (target_kind text, target_id uuid, thread_id uuid, card_id uuid, title text, body text, photo_path text,
               finish text, gate_title text, author_name text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select 'thread'::text, t.id, t.id, x.id, x.title, x.body, x.photo_path, x.finish, g.title, p.display_name, x.created_at
    from gf_board_threads t
    join gf_graffiti x on x.id = t.card_id
    join gf_gates g on g.id = x.gate_id
    join profiles p on p.id = x.author
    where t.gate_id = p_gate and (p_thread is null or t.id = p_thread)
      and gf_can_read_thread(t, me) and x.deleted_at is null and x.author = t.author
    union all
    select 'reply'::text, r.id, t.id, x.id, x.title, x.body, x.photo_path, x.finish, g.title, p.display_name, x.created_at
    from gf_board_replies r
    join gf_board_threads t on t.id = r.thread_id
    join gf_graffiti x on x.id = r.card_id
    join gf_gates g on g.id = x.gate_id
    join profiles p on p.id = x.author
    where p_thread is not null and t.id = p_thread and t.gate_id = p_gate
      and gf_can_read_thread(t, me) and r.deleted_at is null and not gf_blocked(me, r.author)
      and x.deleted_at is null and x.author = r.author;
end $$;

-- カードを消したら、入れたアルバムからも外す（写真のファイルはアプリが消す）
create or replace function public.gf_on_card_gone() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    delete from gf_memory_items where card_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists gf_on_card_gone on public.gf_graffiti;
create trigger gf_on_card_gone after update of deleted_at on public.gf_graffiti
  for each row execute function public.gf_on_card_gone();

-- 写真を受け取ってよいか（0030 に、アルバム・掲示板に入れたカードの写真を足したもの）
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
    or exists (select 1 from gf_memory_items i join gf_memories m on m.id = i.memory_id join gf_graffiti x on x.id = i.card_id
               where x.photo_path = p_path and x.author = i.author and x.deleted_at is null
                 and gf_can_see_memory(m, auth.uid()) and not gf_blocked(auth.uid(), i.author))
    or exists (select 1 from gf_board_threads t join gf_graffiti x on x.id = t.card_id
               where x.photo_path = p_path and x.author = t.author and x.deleted_at is null
                 and gf_can_read_thread(t, auth.uid()))
    or exists (select 1 from gf_board_replies r join gf_board_threads t on t.id = r.thread_id
               join gf_graffiti x on x.id = r.card_id
               where x.photo_path = p_path and x.author = r.author and x.deleted_at is null and r.deleted_at is null
                 and gf_can_read_thread(t, auth.uid()) and not gf_blocked(auth.uid(), r.author))
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
    'gf_add_memory_card(uuid, uuid)', 'gf_memory_cards(uuid)', 'gf_delete_memory_media(uuid)', 'gf_delete_memory_item(uuid)',
    'gf_board_attach_card(text, uuid, uuid)', 'gf_board_cards(uuid, uuid)', 'gf_can_read_media(text)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
