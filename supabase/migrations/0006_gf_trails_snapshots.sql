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
