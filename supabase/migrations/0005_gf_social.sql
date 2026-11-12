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
