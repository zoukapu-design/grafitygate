-- GRAFITYGATE：GATE の中の機能（掲示板・手紙とタイムカプセル・思い出）と、保存・図鑑・通報・ブロック・
-- データの書き出し・アカウントの削除。
--
-- 現地だけの中身（掲示板・思い出）は、その GATE の有効な入場券を持つ人だけが読める（書いた本人・仲間は別）。
-- 手紙は、閉じているあいだは「手紙がある」ことだけが分かり、開く条件（日時・現地）がそろうと宛先の本人だけが読める。
--
-- 使い方：0003 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

insert into public.gf_settings (key, value, note) values
  ('board_posts_per_hour', 10, '1 時間に立てられる掲示板の話題の数'),
  ('board_replies_per_hour', 40, '1 時間に書ける掲示板の返信の数'),
  ('letters_per_day', 10, '1 日に書ける手紙の数'),
  ('memories_per_day', 10, '1 日に作れる思い出の数'),
  ('memory_items_max', 40, '1 つの思い出に入れられる写真の数'),
  ('memory_items_per_person', 12, '1 人が 1 つの思い出に足せる写真の数'),
  ('memory_join_hours', 72, '思い出を作ってから、仲間が現地にいなくても写真を足せる時間'),
  ('reports_per_day', 30, '1 日に送れる通報の数')
on conflict (key) do nothing;

-- いま有効な、自分の入場券（だめなら gf_visit_invalid）
create or replace function public.gf_valid_visit(p_visit uuid) returns public.gf_visits
language plpgsql stable security definer set search_path = public as $$
declare
  v gf_visits;
  g gf_gates;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into v from gf_visits where id = p_visit and user_id = auth.uid();
  if not found or v.revoked_at is not null or v.expires_at <= now() then
    raise exception 'gf_visit_invalid' using errcode = 'P0001';
  end if;
  select * into g from gf_gates where id = v.gate_id;
  if not found or not gf_can_see_gate(g, auth.uid()) then
    raise exception 'gf_visit_invalid' using errcode = 'P0001';
  end if;
  return v;
end $$;

-- ============ 掲示板 ============
create table if not exists public.gf_board_threads (
  id uuid primary key default gen_random_uuid(),
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  author uuid not null references public.profiles(id) on delete cascade,
  topic text not null default 'memory' check (topic in ('memory', 'question', 'notice', 'other')),
  title text not null check (char_length(btrim(title)) between 1 and 60),
  body text not null default '' check (char_length(body) <= 1000),
  pinned boolean not null default false,
  reply_count int not null default 0,
  last_activity_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index if not exists gf_board_threads_gate on public.gf_board_threads(gate_id, last_activity_at desc);
alter table public.gf_board_threads enable row level security;

create table if not exists public.gf_board_replies (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.gf_board_threads(id) on delete cascade,
  author uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 1000),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index if not exists gf_board_replies_thread on public.gf_board_replies(thread_id, created_at);
alter table public.gf_board_replies enable row level security;

-- どこまで読んだか（未読の印）
create table if not exists public.gf_board_reads (
  user_id uuid not null references public.profiles(id) on delete cascade,
  thread_id uuid not null references public.gf_board_threads(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (user_id, thread_id)
);
alter table public.gf_board_reads enable row level security;

-- 掲示板の話題を見てよいか：書いた本人はいつでも。ほかの人は、その GATE の入場券が要る。
create or replace function public.gf_can_see_thread(t public.gf_board_threads, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and t.deleted_at is null and (
    t.author = viewer or (
      not gf_blocked(viewer, t.author)
      and gf_active_visit(t.gate_id, viewer) is not null))
$$;

drop policy if exists "gf board threads read" on public.gf_board_threads;
create policy "gf board threads read" on public.gf_board_threads for select to authenticated
  using (public.gf_can_see_thread(gf_board_threads, auth.uid()));

-- 返信：入場券があって話題が見えるとき（自分の返信は、話題が見えればいつでも）
drop policy if exists "gf board replies read" on public.gf_board_replies;
create policy "gf board replies read" on public.gf_board_replies for select to authenticated
  using (deleted_at is null and exists (
    select 1 from public.gf_board_threads t
    where t.id = thread_id and public.gf_can_see_thread(t, auth.uid())
      and (gf_board_replies.author = auth.uid()
           or (not public.gf_blocked(auth.uid(), gf_board_replies.author)
               and public.gf_active_visit(t.gate_id, auth.uid()) is not null))));

-- 話題を立てる（入場中だけ）
create or replace function public.gf_board_post(p_visit uuid, p_topic text, p_title text, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v gf_visits := gf_valid_visit(p_visit);
  tid uuid;
begin
  perform gf_take_rate('board_post', gf_setting('board_posts_per_hour'), 3600);
  begin
    insert into gf_board_threads (gate_id, author, topic, title, body)
    values (v.gate_id, auth.uid(), coalesce(p_topic, 'memory'), btrim(coalesce(p_title, '')), coalesce(p_body, ''))
    returning id into tid;
  exception when check_violation then
    raise exception 'gf_bad_post' using errcode = 'P0001';
  end;
  insert into gf_board_reads (user_id, thread_id) values (auth.uid(), tid) on conflict do nothing;
  return tid;
end $$;

-- 返信する（入場中だけ）
create or replace function public.gf_board_reply(p_visit uuid, p_thread uuid, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v gf_visits := gf_valid_visit(p_visit);
  t gf_board_threads;
  rid uuid;
begin
  select * into t from gf_board_threads where id = p_thread for update;
  if not found or t.gate_id <> v.gate_id or not gf_can_see_thread(t, auth.uid()) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  perform gf_take_rate('board_reply', gf_setting('board_replies_per_hour'), 3600);
  begin
    insert into gf_board_replies (thread_id, author, body) values (t.id, auth.uid(), btrim(coalesce(p_body, '')))
    returning id into rid;
  exception when check_violation then
    raise exception 'gf_bad_post' using errcode = 'P0001';
  end;
  update gf_board_threads set reply_count = reply_count + 1, last_activity_at = now() where id = t.id;
  insert into gf_board_reads (user_id, thread_id) values (auth.uid(), t.id)
  on conflict (user_id, thread_id) do update set read_at = now();
  return rid;
end $$;

-- GATE の掲示板の一覧（ピン留め → 新しく動いた順）。未読の印つき
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
    where t.gate_id = p_gate and gf_can_see_thread(t, auth.uid())
    order by t.pinned desc, t.last_activity_at desc
    limit 200;
end $$;

-- 話題の返信（読んだ印も付ける）
create or replace function public.gf_board_replies_of(p_thread uuid)
returns table (id uuid, author uuid, author_name text, body text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare t gf_board_threads;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into t from gf_board_threads where gf_board_threads.id = p_thread;
  if not found or not gf_can_see_thread(t, auth.uid()) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  insert into gf_board_reads (user_id, thread_id) values (auth.uid(), t.id)
  on conflict (user_id, thread_id) do update set read_at = now();
  return query
    select r.id, r.author, p.display_name, r.body, r.created_at
    from gf_board_replies r join profiles p on p.id = r.author
    where r.thread_id = t.id and r.deleted_at is null
      and (r.author = auth.uid()
           or (not gf_blocked(auth.uid(), r.author) and gf_active_visit(t.gate_id, auth.uid()) is not null))
    order by r.created_at
    limit 500;
end $$;

-- ピン留め（GATE を作った人だけ。遠くからでもよい）
create or replace function public.gf_board_pin(p_thread uuid, p_pinned boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_board_threads t set pinned = coalesce(p_pinned, false)
  where t.id = p_thread and t.deleted_at is null
    and exists (select 1 from gf_gates g where g.id = t.gate_id and g.owner = auth.uid());
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- 消す（書いた本人か、GATE を作った人。遠くからでもよい）。p_kind は thread / reply
create or replace function public.gf_board_delete(p_kind text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare tid uuid;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_kind = 'thread' then
    update gf_board_threads t set deleted_at = now()
    where t.id = p_id and t.deleted_at is null
      and (t.author = auth.uid() or exists (select 1 from gf_gates g where g.id = t.gate_id and g.owner = auth.uid()))
    returning t.id into tid;
  elsif p_kind = 'reply' then
    update gf_board_replies r set deleted_at = now()
    from gf_board_threads t
    where r.id = p_id and r.deleted_at is null and t.id = r.thread_id
      and (r.author = auth.uid() or exists (select 1 from gf_gates g where g.id = t.gate_id and g.owner = auth.uid()))
    returning r.thread_id into tid;
    if tid is not null then
      update gf_board_threads set reply_count = greatest(reply_count - 1, 0) where id = tid;
    end if;
  end if;
  if tid is null then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- ============ 手紙・タイムカプセル ============
create table if not exists public.gf_letters (
  id uuid primary key default gen_random_uuid(),
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  author uuid not null references public.profiles(id) on delete cascade,
  recipient uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  photo_path text,
  -- 開く条件：日時（なければいつでも）と、現地に来たときだけか
  open_at timestamptz,
  onsite boolean not null default true,
  opened_at timestamptz,
  created_at timestamptz not null default now(),
  check (onsite or open_at is not null)
);
create index if not exists gf_letters_recipient on public.gf_letters(recipient, created_at desc);
create index if not exists gf_letters_author on public.gf_letters(author, created_at desc);
create index if not exists gf_letters_gate on public.gf_letters(gate_id);
create index if not exists gf_letters_photo on public.gf_letters(photo_path);
alter table public.gf_letters enable row level security;
-- 表は直接読ませない（中身は開く条件がそろったときだけ、関数で返す）

-- 手紙を書く（入場中だけ。宛先は自分か、お互いにフォローしている友達で、その GATE を見られる人）
create or replace function public.gf_write_letter(p_visit uuid, p_recipient uuid, p_body text, p_photo_path text,
                                                  p_open_at timestamptz, p_onsite boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v gf_visits := gf_valid_visit(p_visit);
  me uuid := auth.uid();
  to_whom uuid := coalesce(p_recipient, auth.uid());
  g gf_gates;
  lid uuid;
begin
  if to_whom <> me and (not gf_mutual(me, to_whom) or gf_blocked(me, to_whom)) then
    raise exception 'gf_bad_recipient' using errcode = 'P0001';
  end if;
  select * into g from gf_gates where id = v.gate_id;
  if not gf_can_see_gate(g, to_whom) then
    raise exception 'gf_recipient_cannot_see' using errcode = 'P0001';
  end if;
  if p_open_at is not null and (p_open_at < now() - interval '1 minute' or p_open_at > now() + interval '10 years') then
    raise exception 'gf_bad_open_at' using errcode = 'P0001';
  end if;
  if p_photo_path is not null and split_part(p_photo_path, '/', 1) <> me::text then
    raise exception 'gf_bad_media_path' using errcode = 'P0001';
  end if;
  perform gf_take_rate('letter', gf_setting('letters_per_day'), 86400);
  begin
    insert into gf_letters (gate_id, author, recipient, body, photo_path, open_at, onsite)
    values (v.gate_id, me, to_whom, coalesce(p_body, ''), p_photo_path, p_open_at, coalesce(p_onsite, true))
    returning id into lid;
  exception when check_violation then
    raise exception 'gf_bad_letter' using errcode = 'P0001';
  end;
  return lid;
end $$;

-- 自分あての手紙と、自分が書いた手紙の一覧（中身は返さない）。p_gate を渡すとその GATE のものだけ
create or replace function public.gf_my_letters(p_gate uuid default null)
returns table (id uuid, gate_id uuid, gate_title text, author uuid, author_name text, recipient uuid,
               recipient_name text, open_at timestamptz, onsite boolean, opened_at timestamptz,
               created_at timestamptz, sent boolean, time_ok boolean, here boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select l.id, l.gate_id, g.title, l.author, pa.display_name, l.recipient, pr.display_name,
           l.open_at, l.onsite, l.opened_at, l.created_at,
           l.author = auth.uid() and l.recipient <> auth.uid(),
           l.open_at is null or l.open_at <= now(),
           gf_active_visit(l.gate_id, auth.uid()) is not null
    from gf_letters l
    join gf_gates g on g.id = l.gate_id
    join profiles pa on pa.id = l.author
    join profiles pr on pr.id = l.recipient
    where (l.recipient = auth.uid() or l.author = auth.uid())
      and (p_gate is null or l.gate_id = p_gate)
      and not gf_blocked(l.author, l.recipient)
      and (l.author = auth.uid() or gf_can_see_gate(g, auth.uid()))
    order by l.created_at desc
    limit 300;
end $$;

-- 手紙を開く（宛先の本人。日時が来ていて、現地のときは入場中であること）。書いた人はいつでも読める。
create or replace function public.gf_open_letter(p_letter uuid)
returns table (id uuid, author_name text, recipient_name text, body text, photo_path text,
               created_at timestamptz, opened_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  l gf_letters;
  g gf_gates;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into l from gf_letters where gf_letters.id = p_letter for update;
  if not found or (l.recipient <> auth.uid() and l.author <> auth.uid()) or gf_blocked(l.author, l.recipient) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  if l.recipient = auth.uid() and l.opened_at is null then
    select * into g from gf_gates where gf_gates.id = l.gate_id;
    if not gf_can_see_gate(g, auth.uid()) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
    if l.open_at is not null and l.open_at > now() then
      raise exception 'gf_letter_not_yet' using errcode = 'P0001';
    end if;
    if l.onsite and gf_active_visit(l.gate_id, auth.uid()) is null then
      raise exception 'gf_letter_onsite' using errcode = 'P0001';
    end if;
    update gf_letters set opened_at = now() where gf_letters.id = l.id returning * into l;
  end if;
  return query
    select l.id, pa.display_name, pr.display_name, l.body, l.photo_path, l.created_at, l.opened_at
    from profiles pa, profiles pr where pa.id = l.author and pr.id = l.recipient;
end $$;

-- 手紙を消す（書いた人は開かれる前まで。宛先の人は開いたあと）
create or replace function public.gf_delete_letter(p_letter uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_letters l
  where l.id = p_letter
    and ((l.author = auth.uid() and (l.opened_at is null or l.recipient = auth.uid()))
         or (l.recipient = auth.uid() and l.opened_at is not null));
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- ============ 思い出 ============
create table if not exists public.gf_memories (
  id uuid primary key default gen_random_uuid(),
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  owner uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 60),
  note text not null default '' check (char_length(note) <= 500),
  visibility text not null default 'friends' check (visibility in ('private', 'friends', 'public')),
  created_at timestamptz not null default now()
);
create index if not exists gf_memories_gate on public.gf_memories(gate_id, created_at desc);
alter table public.gf_memories enable row level security;

create table if not exists public.gf_memory_members (
  memory_id uuid not null references public.gf_memories(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  added_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (memory_id, user_id)
);
create index if not exists gf_memory_members_user on public.gf_memory_members(user_id);
alter table public.gf_memory_members enable row level security;

create table if not exists public.gf_memory_items (
  id uuid primary key default gen_random_uuid(),
  memory_id uuid not null references public.gf_memories(id) on delete cascade,
  author uuid not null references public.profiles(id) on delete cascade,
  photo_path text not null,
  caption text not null default '' check (char_length(caption) <= 200),
  created_at timestamptz not null default now()
);
create index if not exists gf_memory_items_memory on public.gf_memory_items(memory_id, created_at);
create index if not exists gf_memory_items_photo on public.gf_memory_items(photo_path);
alter table public.gf_memory_items enable row level security;

create or replace function public.gf_is_memory_member(p_memory uuid, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from gf_memories m where m.id = p_memory and m.owner = viewer)
      or exists (select 1 from gf_memory_members x where x.memory_id = p_memory and x.user_id = viewer)
$$;

-- 思い出を見てよいか：作った人と仲間はいつでも。ほかの人は、入場券と公開範囲が要る。
create or replace function public.gf_can_see_memory(m public.gf_memories, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select viewer is not null and (
    gf_is_memory_member(m.id, viewer) or (
      not gf_blocked(viewer, m.owner)
      and gf_active_visit(m.gate_id, viewer) is not null
      and (m.visibility = 'public' or (m.visibility = 'friends' and gf_mutual(viewer, m.owner)))))
$$;

drop policy if exists "gf memories read" on public.gf_memories;
create policy "gf memories read" on public.gf_memories for select to authenticated
  using (public.gf_can_see_memory(gf_memories, auth.uid()));
drop policy if exists "gf memory items read" on public.gf_memory_items;
create policy "gf memory items read" on public.gf_memory_items for select to authenticated
  using (exists (select 1 from public.gf_memories m where m.id = memory_id and public.gf_can_see_memory(m, auth.uid()))
         and not public.gf_blocked(auth.uid(), author));
drop policy if exists "gf memory members read" on public.gf_memory_members;
create policy "gf memory members read" on public.gf_memory_members for select to authenticated
  using (exists (select 1 from public.gf_memories m where m.id = memory_id and public.gf_can_see_memory(m, auth.uid())));

-- 思い出を作る（入場中だけ）
create or replace function public.gf_create_memory(p_visit uuid, p_title text, p_note text, p_visibility text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v gf_visits := gf_valid_visit(p_visit);
  mid uuid;
begin
  perform gf_take_rate('memory', gf_setting('memories_per_day'), 86400);
  begin
    insert into gf_memories (gate_id, owner, title, note, visibility)
    values (v.gate_id, auth.uid(), btrim(coalesce(p_title, '')), coalesce(p_note, ''), coalesce(p_visibility, 'friends'))
    returning id into mid;
  exception when check_violation then
    raise exception 'gf_bad_post' using errcode = 'P0001';
  end;
  return mid;
end $$;

-- 一緒にいた友達を仲間に入れる（作った人だけ。お互いにフォローしている人）
create or replace function public.gf_invite_to_memory(p_memory uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m gf_memories;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into m from gf_memories where id = p_memory and owner = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  if p_user = auth.uid() or not gf_mutual(auth.uid(), p_user) or gf_blocked(auth.uid(), p_user) then
    raise exception 'gf_bad_recipient' using errcode = 'P0001';
  end if;
  insert into gf_memory_members (memory_id, user_id, added_by) values (m.id, p_user, auth.uid())
  on conflict do nothing;
end $$;

-- 思い出に写真を足す（作った人・仲間。現地にいるか、作ってから 72 時間以内）
create or replace function public.gf_add_memory_item(p_memory uuid, p_photo_path text, p_caption text) returns uuid
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
  if p_photo_path is null or split_part(p_photo_path, '/', 1) <> auth.uid()::text then
    raise exception 'gf_bad_media_path' using errcode = 'P0001';
  end if;
  if (select count(*) from gf_memory_items where memory_id = m.id) >= gf_setting('memory_items_max') then
    raise exception 'gf_memory_full' using errcode = 'P0001';
  end if;
  if (select count(*) from gf_memory_items where memory_id = m.id and author = auth.uid())
     >= gf_setting('memory_items_per_person') then
    raise exception 'gf_memory_full' using errcode = 'P0001';
  end if;
  begin
    insert into gf_memory_items (memory_id, author, photo_path, caption)
    values (m.id, auth.uid(), p_photo_path, coalesce(p_caption, ''))
    returning id into iid;
  exception when check_violation then
    raise exception 'gf_bad_post' using errcode = 'P0001';
  end;
  return iid;
end $$;

-- GATE の思い出の一覧（見てよいものだけ）
create or replace function public.gf_memory_list(p_gate uuid)
returns table (id uuid, owner uuid, owner_name text, title text, note text, visibility text, created_at timestamptz,
               item_count bigint, cover_path text, member_count bigint, is_member boolean, can_add boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select m.id, m.owner, p.display_name, m.title, m.note, m.visibility, m.created_at,
           (select count(*) from gf_memory_items i where i.memory_id = m.id),
           (select i.photo_path from gf_memory_items i where i.memory_id = m.id
              and not gf_blocked(auth.uid(), i.author) order by i.created_at limit 1),
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

-- 自分が作った・仲間に入っている思い出（わたしの画面）
create or replace function public.gf_my_memories()
returns table (id uuid, gate_id uuid, gate_title text, owner uuid, owner_name text, title text,
               created_at timestamptz, item_count bigint, cover_path text)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select m.id, m.gate_id, g.title, m.owner, p.display_name, m.title, m.created_at,
           (select count(*) from gf_memory_items i where i.memory_id = m.id),
           (select i.photo_path from gf_memory_items i where i.memory_id = m.id
              and not gf_blocked(auth.uid(), i.author) order by i.created_at limit 1)
    from gf_memories m
    join gf_gates g on g.id = m.gate_id
    join profiles p on p.id = m.owner
    where gf_is_memory_member(m.id, auth.uid()) and not gf_blocked(auth.uid(), m.owner)
    order by m.created_at desc
    limit 200;
end $$;

create or replace function public.gf_delete_memory(p_memory uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_memories where id = p_memory and owner = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- 写真を消す（足した本人か、思い出を作った人）。消した写真の置き場所の名前を返す（アプリがファイルも消す）
create or replace function public.gf_delete_memory_item(p_item uuid) returns text
language plpgsql security definer set search_path = public as $$
declare path text;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_memory_items i
  where i.id = p_item
    and (i.author = auth.uid() or exists (select 1 from gf_memories m where m.id = i.memory_id and m.owner = auth.uid()))
  returning i.photo_path into path;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return path;
end $$;

create or replace function public.gf_leave_memory(p_memory uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_memory_members where memory_id = p_memory and user_id = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- ============ 保存と図鑑 ============
create table if not exists public.gf_bookmarks (
  user_id uuid not null references public.profiles(id) on delete cascade,
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, gate_id)
);
alter table public.gf_bookmarks enable row level security;
drop policy if exists "gf bookmarks own read" on public.gf_bookmarks;
create policy "gf bookmarks own read" on public.gf_bookmarks for select to authenticated using (user_id = auth.uid());

-- 図鑑：入場した GATE の記録（入場すると自動で付く）。本人が選んだものだけ友達に見せる
create table if not exists public.gf_atlas (
  user_id uuid not null references public.profiles(id) on delete cascade,
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  visits int not null default 1,
  shared boolean not null default false,
  primary key (user_id, gate_id)
);
alter table public.gf_atlas enable row level security;
drop policy if exists "gf atlas own read" on public.gf_atlas;
create policy "gf atlas own read" on public.gf_atlas for select to authenticated using (user_id = auth.uid());

create or replace function public.gf_atlas_on_visit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into gf_atlas (user_id, gate_id, first_at, last_at, visits)
  values (new.user_id, new.gate_id, new.created_at, new.created_at, 1)
  on conflict (user_id, gate_id) do update set last_at = excluded.last_at, visits = gf_atlas.visits + 1;
  return new;
end $$;
drop trigger if exists gf_atlas_on_visit on public.gf_visits;
create trigger gf_atlas_on_visit after insert on public.gf_visits
  for each row execute function public.gf_atlas_on_visit();

create or replace function public.gf_set_bookmark(p_gate uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare g gf_gates;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if coalesce(p_on, true) then
    select * into g from gf_gates where id = p_gate;
    if not found or not gf_can_see_gate(g, auth.uid()) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
    insert into gf_bookmarks (user_id, gate_id) values (auth.uid(), p_gate) on conflict do nothing;
  else
    delete from gf_bookmarks where user_id = auth.uid() and gate_id = p_gate;
  end if;
end $$;

create or replace function public.gf_set_atlas_shared(p_gate uuid, p_shared boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_atlas set shared = coalesce(p_shared, false) where user_id = auth.uid() and gate_id = p_gate;
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- GATE の一覧の形（保存・図鑑・友達の図鑑で共通）。位置は 3 けた（約 100m）に丸める
-- kind：saved（保存）／ visited（図鑑）
create or replace function public.gf_my_collection(p_kind text)
returns table (gate_id uuid, title text, owner uuid, owner_name text, cover_path text,
               approx_lat double precision, approx_lon double precision,
               first_at timestamptz, last_at timestamptz, visits int, shared boolean, saved_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_kind = 'saved' then
    return query
      select g.id, g.title, g.owner, p.display_name, g.cover_path,
             round(g.lat::numeric, 3)::double precision, round(g.lon::numeric, 3)::double precision,
             a.first_at, a.last_at, coalesce(a.visits, 0), coalesce(a.shared, false), b.created_at
      from gf_bookmarks b
      join gf_gates g on g.id = b.gate_id
      join profiles p on p.id = g.owner
      left join gf_atlas a on a.user_id = b.user_id and a.gate_id = b.gate_id
      where b.user_id = auth.uid() and gf_can_see_gate(g, auth.uid())
      order by b.created_at desc limit 500;
  else
    return query
      select g.id, g.title, g.owner, p.display_name, g.cover_path,
             round(g.lat::numeric, 3)::double precision, round(g.lon::numeric, 3)::double precision,
             a.first_at, a.last_at, a.visits, a.shared,
             (select b.created_at from gf_bookmarks b where b.user_id = a.user_id and b.gate_id = a.gate_id)
      from gf_atlas a
      join gf_gates g on g.id = a.gate_id
      join profiles p on p.id = g.owner
      where a.user_id = auth.uid() and gf_can_see_gate(g, auth.uid())
      order by a.last_at desc limit 500;
  end if;
end $$;

-- 友達の図鑑（お互いにフォローしている友達の、本人が見せると選んだものだけ）
create or replace function public.gf_friend_atlas(p_user uuid)
returns table (gate_id uuid, title text, owner uuid, owner_name text, cover_path text,
               approx_lat double precision, approx_lon double precision, first_at timestamptz, visits int)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_user <> auth.uid() and (not gf_mutual(auth.uid(), p_user) or gf_blocked(auth.uid(), p_user)) then
    return;
  end if;
  return query
    select g.id, g.title, g.owner, p.display_name, g.cover_path,
           round(g.lat::numeric, 3)::double precision, round(g.lon::numeric, 3)::double precision,
           a.first_at, a.visits
    from gf_atlas a
    join gf_gates g on g.id = a.gate_id
    join profiles p on p.id = g.owner
    where a.user_id = p_user and a.shared and gf_can_see_gate(g, auth.uid())
    order by a.first_at desc limit 500;
end $$;

-- ============ 通報とブロック ============
-- 通報（App Store の決まり 1.2）。読めるのは運営だけ（Supabase の管理画面）。
create table if not exists public.gf_reports (
  id uuid primary key default gen_random_uuid(),
  reporter uuid not null references public.profiles(id) on delete cascade,
  target_kind text not null check (target_kind in ('gate', 'graffiti', 'artwork', 'thread', 'reply', 'memory',
                                                   'memory_item', 'letter', 'user')),
  target_id uuid not null,
  target_user uuid references public.profiles(id) on delete set null,
  reason text not null check (reason in ('harassment', 'inappropriate', 'privacy', 'dangerous', 'spam', 'other')),
  note text check (note is null or char_length(note) <= 500),
  snapshot text check (snapshot is null or char_length(snapshot) <= 500),
  status text not null default 'open' check (status in ('open', 'reviewing', 'closed')),
  created_at timestamptz not null default now()
);
create index if not exists gf_reports_created on public.gf_reports(created_at desc);
alter table public.gf_reports enable row level security;

-- 通報する。だれのものか・そのときの文は、サーバーが埋める（見られないものは通報できない＝あるかも知らせない）
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

-- ブロック（Lyric Path と共通の表 lp_blocks に書く＝両方のアプリで効く）。入場券も見てよいかの判定ですぐ使えなくなる
create or replace function public.gf_block(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_user is null or p_user = auth.uid() then return; end if;
  insert into lp_blocks (blocker, blocked) values (auth.uid(), p_user) on conflict do nothing;
  delete from gf_memory_members x using gf_memories m
    where x.memory_id = m.id and ((m.owner = auth.uid() and x.user_id = p_user)
                                  or (m.owner = p_user and x.user_id = auth.uid()));
end $$;

create or replace function public.gf_unblock(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from lp_blocks where blocker = auth.uid() and blocked = p_user;
end $$;

create or replace function public.gf_my_blocks()
returns table (user_id uuid, display_name text, handle text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select p.id, p.display_name, p.handle, b.created_at
    from lp_blocks b join profiles p on p.id = b.blocked
    where b.blocker = auth.uid()
    order by b.created_at desc;
end $$;

-- ============ 自分のデータ ============
-- 書き出し：自分が作った・書いたもの（自分の GATE は正確な位置も）を 1 つの JSON にする
create or replace function public.gf_export_me() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return jsonb_build_object(
    'exported_at', now(),
    'profile', (select to_jsonb(p) from profiles p where p.id = me),
    'gates', coalesce((select jsonb_agg(to_jsonb(g) order by g.created_at) from gf_gates g where g.owner = me), '[]'),
    'graffiti', coalesce((select jsonb_agg(to_jsonb(x) - 'visit_id' order by x.created_at) from gf_graffiti x
                          where x.author = me and x.deleted_at is null), '[]'),
    'artworks', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from gf_artworks a where a.owner = me), '[]'),
    'board_threads', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at) from gf_board_threads t
                               where t.author = me and t.deleted_at is null), '[]'),
    'board_replies', coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at) from gf_board_replies r
                               where r.author = me and r.deleted_at is null), '[]'),
    'letters_written', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at) from gf_letters l
                                 where l.author = me), '[]'),
    'letters_received', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at) from gf_letters l
                                  where l.recipient = me and l.author <> me and l.opened_at is not null), '[]'),
    'memories', coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at) from gf_memories m where m.owner = me), '[]'),
    'memory_items', coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at) from gf_memory_items i
                              where i.author = me), '[]'),
    'bookmarks', coalesce((select jsonb_agg(to_jsonb(b) order by b.created_at) from gf_bookmarks b where b.user_id = me), '[]'),
    'atlas', coalesce((select jsonb_agg(to_jsonb(a) order by a.first_at) from gf_atlas a where a.user_id = me), '[]'));
end $$;

-- アカウントの削除（App Store の決まり）。アプリが先に自分のファイル（写真・場所の記憶）を消してから呼ぶ。
-- auth.users を消すと、profiles から先（gf_ の表すべて）は on delete cascade で消える。
create or replace function public.gf_delete_me() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from auth.users where id = auth.uid();
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
               where i.photo_path = p_path and gf_can_see_memory(m, auth.uid()) and not gf_blocked(auth.uid(), i.author)))
$$;

-- ============ 呼べる関数を絞る ============
revoke all on function public.gf_valid_visit(uuid) from public, anon, authenticated;

revoke all on function public.gf_can_see_thread(public.gf_board_threads, uuid) from public, anon;
revoke all on function public.gf_can_see_memory(public.gf_memories, uuid) from public, anon;
revoke all on function public.gf_is_memory_member(uuid, uuid) from public, anon;
revoke all on function public.gf_can_read_media(text) from public, anon;
grant execute on function public.gf_can_see_thread(public.gf_board_threads, uuid) to authenticated;
grant execute on function public.gf_can_see_memory(public.gf_memories, uuid) to authenticated;
grant execute on function public.gf_is_memory_member(uuid, uuid) to authenticated;
grant execute on function public.gf_can_read_media(text) to authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'gf_board_post(uuid, text, text, text)', 'gf_board_reply(uuid, uuid, text)', 'gf_board_list(uuid)',
    'gf_board_replies_of(uuid)', 'gf_board_pin(uuid, boolean)', 'gf_board_delete(text, uuid)',
    'gf_write_letter(uuid, uuid, text, text, timestamptz, boolean)', 'gf_my_letters(uuid)', 'gf_open_letter(uuid)',
    'gf_delete_letter(uuid)',
    'gf_create_memory(uuid, text, text, text)', 'gf_invite_to_memory(uuid, uuid)',
    'gf_add_memory_item(uuid, text, text)', 'gf_memory_list(uuid)', 'gf_my_memories()', 'gf_delete_memory(uuid)',
    'gf_delete_memory_item(uuid)', 'gf_leave_memory(uuid)',
    'gf_set_bookmark(uuid, boolean)', 'gf_set_atlas_shared(uuid, boolean)', 'gf_my_collection(text)',
    'gf_friend_atlas(uuid)',
    'gf_report(text, uuid, text, text)', 'gf_block(uuid)', 'gf_unblock(uuid)', 'gf_my_blocks()',
    'gf_export_me()', 'gf_delete_me()']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
revoke all on function public.gf_atlas_on_visit() from public, anon, authenticated;
