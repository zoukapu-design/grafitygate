-- 0024 グラフィティボード（扉を開けずに見る GATE の画面）で読めるもの（2026-11-17 オーナー）
-- ・一度扉を開けた GATE は、そのあと遠くからでもグラフィティカードと掲示板を全部読める（＝「鍵」を持っている）
-- ・まだ開けたことのない人には、新しいグラフィティカード 3 枚と、掲示板の話題の題名だけを見せる（チラ見せ）
-- ・書く・保存・返信・いいね・なるほどは、これまでどおり扉が開いているあいだだけ（gf_can_see_graffiti・gf_can_see_thread は変えない）
-- ・書いた人が「この GATE の中だけ」にしたカードは、扉が開いているあいだだけ（遠くからは読めない・チラ見せにも出ない）
-- ・見える人（友達・全員）とブロックの決まりはそのまま。GATE が閉じた・見えなくなったら、遠くからも読めない

-- 一度でも扉を開けたことがあるか（取り消された入場は数えない。いまも GATE が見えること）
create or replace function public.gf_has_opened(p_gate uuid, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and exists (
    select 1 from gf_visits v join gf_gates g on g.id = v.gate_id
    where v.gate_id = p_gate and v.user_id = viewer and v.revoked_at is null and gf_can_see_gate(g, viewer))
$$;

-- グラフィティカードを読めるか（扉の中で見える ＋ 一度開けた GATE の「この GATE の中だけ」でないカード）
create or replace function public.gf_can_read_graffiti(p public.gf_graffiti, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select gf_can_see_graffiti(p, viewer) or (
    viewer is not null and p.deleted_at is null and not p.local_only
    and not gf_blocked(viewer, p.author)
    and (p.visibility = 'public' or (p.visibility = 'friends' and gf_mutual(viewer, p.author)))
    and gf_has_opened(p.gate_id, viewer))
$$;

-- 掲示板の話題を読めるか（扉の中で見える ＋ 一度開けた GATE）
create or replace function public.gf_can_read_thread(t public.gf_board_threads, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select gf_can_see_thread(t, viewer) or (
    viewer is not null and t.deleted_at is null and not gf_blocked(viewer, t.author)
    and gf_has_opened(t.gate_id, viewer))
$$;

-- チラ見せに出すカード（新しい 3 枚。この GATE の中だけ・自分だけ・お互いにフォローでない友達限定・ブロックの相手は出さない）
create or replace function public.gf_peek_card_ids(p_gate uuid, viewer uuid) returns setof uuid
language sql stable security definer set search_path = public as $$
  select x.id from gf_graffiti x join gf_gates g on g.id = x.gate_id
  where x.gate_id = p_gate and viewer is not null and gf_can_see_gate(g, viewer)
    and x.deleted_at is null and not x.local_only and not gf_blocked(viewer, x.author)
    and (x.visibility = 'public' or (x.visibility = 'friends' and gf_mutual(viewer, x.author)))
  order by x.created_at desc
  limit 3
$$;

create or replace function public.gf_peek_card_visible(p public.gf_graffiti, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and p.id in (select gf_peek_card_ids(p.gate_id, viewer))
$$;

-- グラフィティボードに出すもの：鍵を持っているか、チラ見せのカード 3 枚、掲示板の話題の題名 5 つ（本文は出さない）
create or replace function public.gf_gate_peek(p_gate uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  g gf_gates;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into g from gf_gates where id = p_gate;
  if g.id is null or not gf_can_see_gate(g, me) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return jsonb_build_object(
    'opened', gf_has_opened(p_gate, me),
    'inside', gf_active_visit(p_gate, me) is not null,
    'cards', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'author', x.author, 'author_name', p.display_name,
                                          'body', x.body, 'photo_path', x.photo_path, 'created_at', x.created_at)
                       order by x.created_at desc)
      from gf_graffiti x join profiles p on p.id = x.author
      where x.id in (select gf_peek_card_ids(p_gate, me))), '[]'::jsonb),
    'threads', coalesce((
      select jsonb_agg(jsonb_build_object('id', t.id, 'topic', t.topic, 'title', t.title, 'reply_count', t.reply_count,
                                          'last_activity_at', t.last_activity_at, 'resolved', t.resolved_at is not null)
                       order by t.pinned desc, t.last_activity_at desc)
      from (select * from gf_board_threads t
            where t.gate_id = p_gate and t.deleted_at is null and not gf_blocked(me, t.author)
            order by t.pinned desc, t.last_activity_at desc limit 5) t), '[]'::jsonb),
    'thread_count', (select count(*) from gf_board_threads t
                     where t.gate_id = p_gate and t.deleted_at is null and not gf_blocked(me, t.author)));
end $$;

-- グラフィティカードの表：読めるもの（遠くから読めるのは、一度扉を開けた GATE のもの）
drop policy if exists "gf graffiti read" on public.gf_graffiti;
create policy "gf graffiti read" on public.gf_graffiti for select to authenticated
  using (public.gf_can_read_graffiti(gf_graffiti, auth.uid()));

-- いいねは扉が開いているあいだだけ（カードの表を遠くから読めるようになったので、ここで扉の中かを確かめる）
drop policy if exists "gf reactions insert" on public.gf_reactions;
create policy "gf reactions insert" on public.gf_reactions for insert to authenticated
  with check (user_id = auth.uid()
              and exists (select 1 from public.gf_graffiti g
                          where g.id = graffiti_id and public.gf_can_see_graffiti(g, auth.uid())));

-- 掲示板の一覧（一度開けた GATE は遠くからも読める。書く・返すは扉の中だけ）
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
    where t.gate_id = p_gate and gf_can_read_thread(t, auth.uid())
    order by t.pinned desc, t.last_activity_at desc
    limit 200;
end $$;

-- 話題の返信（一度開けた GATE は遠くからも読める。読んだ印も付ける）
create or replace function public.gf_board_replies_of(p_thread uuid)
returns table (id uuid, author uuid, author_name text, body text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare t gf_board_threads;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into t from gf_board_threads where gf_board_threads.id = p_thread;
  if not found or not gf_can_read_thread(t, auth.uid()) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  insert into gf_board_reads (user_id, thread_id) values (auth.uid(), t.id)
  on conflict (user_id, thread_id) do update set read_at = now();
  return query
    select r.id, r.author, p.display_name, r.body, r.created_at
    from gf_board_replies r join profiles p on p.id = r.author
    where r.thread_id = t.id and r.deleted_at is null
      and (r.author = auth.uid()
           or (not gf_blocked(auth.uid(), r.author)
               and (gf_active_visit(t.gate_id, auth.uid()) is not null or gf_has_opened(t.gate_id, auth.uid()))))
    order by r.created_at
    limit 500;
end $$;

-- 調べる話題の、しるしごとの数（読める人に）
create or replace function public.gf_investigation_counts(p_thread uuid)
returns table (label text, n bigint)
language plpgsql stable security definer set search_path = public as $$
declare t gf_board_threads;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into t from gf_board_threads where gf_board_threads.id = p_thread;
  if not found or not gf_can_read_thread(t, auth.uid()) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return query
    select r.label, count(*) from gf_board_replies r
    where r.thread_id = t.id and r.deleted_at is null and r.label is not null
      and (r.author = auth.uid()
           or (not gf_blocked(auth.uid(), r.author)
               and (gf_active_visit(t.gate_id, auth.uid()) is not null or gf_has_opened(t.gate_id, auth.uid()))))
    group by r.label;
end $$;

-- グラフィティカードへの返信を読む（読めるカードの返信。書くのは扉の中だけのまま）
create or replace function public.gf_card_comments_of(p_card uuid)
returns table (id uuid, author uuid, author_name text, body text, created_at timestamptz, mine boolean, can_delete boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  x public.gf_graffiti;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into x from gf_graffiti g where g.id = p_card;
  if x.id is null or not gf_can_read_graffiti(x, me) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return query
    select c.id, c.author, p.display_name, c.body, c.created_at, c.author = me, (c.author = me or x.author = me)
    from gf_card_comments c
    join profiles p on p.id = c.author
    where c.graffiti_id = x.id and c.deleted_at is null and not gf_blocked(me, c.author)
    order by c.created_at
    limit 300;
end $$;

-- 返信の数と保存の印（読めるカードの分）
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
    where x.gate_id = p_gate and gf_can_read_graffiti(x, me);
end $$;

-- 保存したカード（一度扉を開けた GATE のカードは、ひとことも出す）
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
           case when x.author = me or gf_can_read_graffiti(x, me) then x.body end,
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

-- 通報（遠くから読めるものも通報できる）
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
      where x.id = p_id and (gf_can_read_graffiti(x, me) or gf_feed_visible(x, me));
    when 'artwork' then
      select a.owner, a.kind || ' ' || a.body into who, what from gf_artworks a where a.id = p_id and gf_can_see_artwork(a, me);
    when 'thread' then
      select t.author, t.title || ' ' || t.body into who, what from gf_board_threads t
      where t.id = p_id and gf_can_read_thread(t, me);
    when 'reply' then
      select r.author, r.body into who, what from gf_board_replies r join gf_board_threads t on t.id = r.thread_id
      where r.id = p_id and r.deleted_at is null and gf_can_read_thread(t, me);
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
      where c.id = p_id and c.deleted_at is null and gf_can_read_graffiti(x, me);
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

-- ============ 写真を見てよいか（ここまでの全部。遠くから読めるカードと、チラ見せのカードの写真を足す） ============
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

revoke all on function public.gf_has_opened(uuid, uuid) from public, anon, authenticated;
revoke all on function public.gf_can_read_graffiti(public.gf_graffiti, uuid) from public, anon;
revoke all on function public.gf_can_read_thread(public.gf_board_threads, uuid) from public, anon;
revoke all on function public.gf_peek_card_ids(uuid, uuid) from public, anon, authenticated;
revoke all on function public.gf_peek_card_visible(public.gf_graffiti, uuid) from public, anon, authenticated;
grant execute on function public.gf_can_read_graffiti(public.gf_graffiti, uuid) to authenticated;
grant execute on function public.gf_can_read_thread(public.gf_board_threads, uuid) to authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'gf_gate_peek(uuid)', 'gf_board_list(uuid)', 'gf_board_replies_of(uuid)', 'gf_investigation_counts(uuid)',
    'gf_card_comments_of(uuid)', 'gf_card_extras(uuid)', 'gf_report(text, uuid, text, text)', 'gf_can_read_media(text)',
    'gf_my_saved_cards()']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
