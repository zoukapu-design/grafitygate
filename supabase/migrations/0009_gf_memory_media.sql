-- Grafity Gate：思い出に短い動画（15 秒まで）と声（60 秒まで）
--
-- 思い出の 1 つ 1 つ（gf_memory_items）に種類（photo／video／voice）を足す。動画には表紙の絵（thumb_path）を付ける。
-- ファイルはアプリが iPhone の中で小さく作り直し、位置などの付加情報を消してから送る。
--
-- 使い方：0008 のあとに、Supabase の SQL Editor に貼って実行する（setup_all.sql にも入っている）。何度実行しても大丈夫。

-- 写真の置き場所に、動画と声のファイルも置けるようにする（1 つ 30MB まで）
update storage.buckets
   set file_size_limit = 31457280,
       allowed_mime_types = array['image/jpeg', 'image/heic', 'image/png', 'video/mp4', 'video/quicktime',
                                  'audio/mp4', 'audio/x-m4a', 'audio/m4a', 'audio/aac']
 where id = 'gf-media';

alter table public.gf_memory_items add column if not exists media_kind text not null default 'photo';
alter table public.gf_memory_items add column if not exists thumb_path text;
alter table public.gf_memory_items add column if not exists duration real;
alter table public.gf_memory_items drop constraint if exists gf_memory_items_media_check;
alter table public.gf_memory_items add constraint gf_memory_items_media_check check (
  (media_kind = 'photo' and thumb_path is null and duration is null)
  or (media_kind = 'video' and thumb_path is not null and duration between 0.5 and 15.5)
  or (media_kind = 'voice' and thumb_path is null and duration between 0.5 and 60.5));
create index if not exists gf_memory_items_thumb on public.gf_memory_items(thumb_path);

-- 思い出に動画・声を足す（写真のときと同じ決まり：作った人・仲間で、現地にいるか作ってから 72 時間以内）
create or replace function public.gf_add_memory_media(p_memory uuid, p_kind text, p_path text, p_thumb text,
                                                      p_duration real, p_caption text) returns uuid
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
  if p_path is null or split_part(p_path, '/', 1) <> auth.uid()::text
     or (p_thumb is not null and split_part(p_thumb, '/', 1) <> auth.uid()::text) then
    raise exception 'gf_bad_media_path' using errcode = 'P0001';
  end if;
  if (select count(*) from gf_memory_items where memory_id = m.id) >= gf_setting('memory_items_max')
     or (select count(*) from gf_memory_items where memory_id = m.id and author = auth.uid())
        >= gf_setting('memory_items_per_person') then
    raise exception 'gf_memory_full' using errcode = 'P0001';
  end if;
  begin
    insert into gf_memory_items (memory_id, author, photo_path, caption, media_kind, thumb_path, duration)
    values (m.id, auth.uid(), p_path, coalesce(p_caption, ''), coalesce(p_kind, 'photo'), p_thumb, p_duration)
    returning id into iid;
  exception when check_violation then
    raise exception 'gf_bad_media' using errcode = 'P0001';
  end;
  return iid;
end $$;

-- 表紙は、声ではないいちばん古いもの（動画なら表紙の絵）
create or replace function public.gf_memory_cover(p_memory uuid, viewer uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(i.thumb_path, i.photo_path) from gf_memory_items i
  where i.memory_id = p_memory and i.media_kind <> 'voice' and not gf_blocked(viewer, i.author)
  order by i.created_at limit 1
$$;

create or replace function public.gf_memory_list(p_gate uuid)
returns table (id uuid, owner uuid, owner_name text, title text, note text, visibility text, created_at timestamptz,
               item_count bigint, cover_path text, member_count bigint, is_member boolean, can_add boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select m.id, m.owner, p.display_name, m.title, m.note, m.visibility, m.created_at,
           (select count(*) from gf_memory_items i where i.memory_id = m.id),
           gf_memory_cover(m.id, auth.uid()),
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

create or replace function public.gf_my_memories()
returns table (id uuid, gate_id uuid, gate_title text, owner uuid, owner_name text, title text,
               created_at timestamptz, item_count bigint, cover_path text)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select m.id, m.gate_id, g.title, m.owner, p.display_name, m.title, m.created_at,
           (select count(*) from gf_memory_items i where i.memory_id = m.id),
           gf_memory_cover(m.id, auth.uid())
    from gf_memories m
    join gf_gates g on g.id = m.gate_id
    join profiles p on p.id = m.owner
    where gf_is_memory_member(m.id, auth.uid()) and not gf_blocked(auth.uid(), m.owner)
    order by m.created_at desc
    limit 200;
end $$;

-- 写真（と動画・声）を見てよいか（ここまでの全部。動画の表紙の絵も、思い出が見えれば見てよい）
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
               where (i.photo_path = p_path or i.thumb_path = p_path)
                 and gf_can_see_memory(m, auth.uid()) and not gf_blocked(auth.uid(), i.author))
    or exists (select 1 from gf_snapshots s where s.photo_path = p_path and gf_can_see_snapshot(s, auth.uid())))
$$;

-- 写真・動画・声を消す（足した本人か、思い出を作った人）。消したファイルの名前を返す（動画は表紙の絵も）
create or replace function public.gf_delete_memory_media(p_item uuid) returns text[]
language plpgsql security definer set search_path = public as $$
declare
  main_path text;
  thumb text;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_memory_items i
  where i.id = p_item
    and (i.author = auth.uid() or exists (select 1 from gf_memories m where m.id = i.memory_id and m.owner = auth.uid()))
  returning i.photo_path, i.thumb_path into main_path, thumb;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return array_remove(array[main_path, thumb], null);
end $$;

revoke all on function public.gf_memory_cover(uuid, uuid) from public, anon, authenticated;
revoke all on function public.gf_can_read_media(text) from public, anon;
grant execute on function public.gf_can_read_media(text) to authenticated;
do $$
declare f text;
begin
  foreach f in array array['gf_add_memory_media(uuid, text, text, text, real, text)', 'gf_memory_list(uuid)',
                           'gf_my_memories()', 'gf_delete_memory_media(uuid)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
