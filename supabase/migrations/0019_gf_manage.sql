-- 0019：GATE を直す・閉じる、一緒に管理する人、カードを直す（公開範囲も）、メッセージに写真。
-- 何度実行しても大丈夫な書き方（run.sh が 2 回流して確かめる）。
-- ここで作り直した関数（あとで足すときは、ここ以降で作り直す）：gf_can_read_media・gf_board_pin・gf_board_delete・gf_board_resolve。

insert into public.gf_settings (key, value, note) values
  ('gate_managers_max', 5, '1 つの GATE を一緒に管理できる人の数（作った人のほか）'),
  ('gate_edits_per_hour', 30, '1 時間に GATE を直せる回数（1 人）'),
  ('graffiti_edits_per_hour', 30, '1 時間にカードを直せる回数（1 人）')
on conflict (key) do nothing;

-- ============ お知らせの種類の「最後の一覧」（0008・0017・0018 と同じ。足したら 4 か所とも直す） ============
alter table public.gf_notifications drop constraint if exists gf_notifications_kind_check;
alter table public.gf_notifications add constraint gf_notifications_kind_check
  check (kind in ('gate_graffiti', 'gate_artwork', 'board_thread', 'board_reply', 'letter', 'letter_opened',
                  'memory_invite', 'memory_photo', 'like', 'place_map_stale', 'card_link', 'card_comment',
                  'gate_manager'));

-- 0018 のお知らせの設定で止められる種類に、共同管理を足す
create or replace function public.gf_set_notify_mute(p_kinds text[], p_muted boolean) returns text[]
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  result text[];
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_kinds is null or cardinality(p_kinds) = 0 or cardinality(p_kinds) > 13
     or exists (select 1 from unnest(p_kinds) k
                where k not in ('gate_graffiti', 'gate_artwork', 'board_thread', 'board_reply', 'letter', 'letter_opened',
                                'memory_invite', 'memory_photo', 'like', 'place_map_stale', 'card_link', 'card_comment',
                                'gate_manager')) then
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

-- ============ 一緒に管理する人（作った人がお互いにフォローの友達を入れる。5 人まで） ============
create table if not exists public.gf_gate_managers (
  gate_id uuid not null references public.gf_gates(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (gate_id, user_id)
);
create index if not exists gf_gate_managers_user on public.gf_gate_managers(user_id);
alter table public.gf_gate_managers enable row level security;
-- 表は直接読ませない（gf_gate_managers_of・gf_my_managed_gates が返す）

-- 管理できるか：作った人か、作った人とお互いにフォローのままの共同管理者
create or replace function public.gf_is_gate_manager(p_gate uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_user is not null and exists (
    select 1 from gf_gates g
    where g.id = p_gate and (
      g.owner = p_user
      or exists (select 1 from gf_gate_managers m
                 where m.gate_id = g.id and m.user_id = p_user
                   and gf_mutual(m.user_id, g.owner) and not gf_blocked(m.user_id, g.owner))))
$$;

create or replace function public.gf_add_gate_manager(p_gate uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if not exists (select 1 from gf_gates g where g.id = p_gate and g.owner = me) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  if p_user is null or p_user = me or not gf_mutual(me, p_user) or gf_blocked(me, p_user) then
    raise exception 'gf_not_friends' using errcode = 'P0001';
  end if;
  if exists (select 1 from gf_gate_managers m where m.gate_id = p_gate and m.user_id = p_user) then return; end if;
  if (select count(*) from gf_gate_managers m where m.gate_id = p_gate) >= gf_setting('gate_managers_max') then
    raise exception 'gf_too_many' using errcode = 'P0001';
  end if;
  insert into gf_gate_managers (gate_id, user_id) values (p_gate, p_user);
  perform gf_notify(p_user, 'gate_manager', me, p_gate, p_gate);
end $$;

-- 外す：作った人はだれでも、共同管理者は自分だけ（抜ける）
create or replace function public.gf_remove_gate_manager(p_gate uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  delete from gf_gate_managers m
  where m.gate_id = p_gate and m.user_id = p_user
    and (p_user = me or exists (select 1 from gf_gates g where g.id = p_gate and g.owner = me));
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- だれが管理しているか（見てよい GATE なら分かる。GATE の画面の「作った人・一緒に管理する人」）
create or replace function public.gf_gate_managers_of(p_gate uuid)
returns table (user_id uuid, display_name text, added_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select m.user_id, p.display_name, m.added_at
    from gf_gate_managers m
    join gf_gates g on g.id = m.gate_id
    join profiles p on p.id = m.user_id
    where m.gate_id = p_gate and gf_can_see_gate(g, me)
      and gf_mutual(m.user_id, g.owner) and not gf_blocked(m.user_id, g.owner) and not gf_blocked(me, m.user_id)
    order by m.added_at;
end $$;

-- 自分が一緒に管理している GATE
create or replace function public.gf_my_managed_gates()
returns table (id uuid, title text, kind text, cover_path text, owner uuid, owner_name text, created_at timestamptz,
               added_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  return query
    select g.id, g.title, g.kind, g.cover_path, g.owner, p.display_name, g.created_at, m.added_at
    from gf_gate_managers m
    join gf_gates g on g.id = m.gate_id
    join profiles p on p.id = g.owner
    where m.user_id = me and gf_is_gate_manager(g.id, me) and gf_can_see_gate(g, me)
    order by m.added_at desc;
end $$;

-- ============ GATE を直す（名前・紹介・表紙は管理する人、見せる範囲は作った人だけ）・閉じる ============
-- 返すのは差し替える前の表紙（自分のフォルダのものなら、アプリが消す）
create or replace function public.gf_edit_gate(p_gate uuid, p_title text, p_note text, p_cover_path text,
                                               p_visibility text) returns text
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  g public.gf_gates;
  t text;
  n text;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into g from gf_gates x where x.id = p_gate;
  if g.id is null or not gf_is_gate_manager(p_gate, me) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  if p_visibility is not null and p_visibility <> g.visibility then
    if g.owner <> me then raise exception 'gf_not_owner' using errcode = 'P0001'; end if;
    if p_visibility not in ('private', 'friends', 'public') then raise exception 'gf_bad_kind' using errcode = 'P0001'; end if;
  end if;
  t := btrim(coalesce(p_title, g.title));
  if char_length(t) < 1 or char_length(t) > 60 then raise exception 'gf_bad_title' using errcode = 'P0001'; end if;
  n := coalesce(p_note, g.note);
  if char_length(n) > 400 then raise exception 'gf_too_long' using errcode = 'P0001'; end if;
  if p_cover_path is not null and p_cover_path is distinct from g.cover_path then
    -- 表紙は自分のフォルダに置いた写真だけ
    if split_part(p_cover_path, '/', 1) <> me::text or p_cover_path like '%..%' then
      raise exception 'gf_bad_media_path' using errcode = 'P0001';
    end if;
  end if;
  perform gf_take_rate('gate_edit', gf_setting('gate_edits_per_hour'), 3600);
  update gf_gates x set
    title = t, note = n,
    cover_path = coalesce(p_cover_path, x.cover_path),
    visibility = coalesce(p_visibility, x.visibility),
    updated_at = now()
  where x.id = p_gate;
  return case when p_cover_path is not null and p_cover_path is distinct from g.cover_path then g.cover_path end;
end $$;

-- 閉じる（作った人のほかには見えなくなる・入れなくなる）・開け直す。作った人だけ
create or replace function public.gf_set_gate_open(p_gate uuid, p_open boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_gates g set status = case when coalesce(p_open, true) then 'open' else 'closed' end, updated_at = now()
  where g.id = p_gate and g.owner = auth.uid();
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- ============ 掲示板の管理（作った人に加えて、一緒に管理する人も） ============
create or replace function public.gf_board_pin(p_thread uuid, p_pinned boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_board_threads t set pinned = coalesce(p_pinned, false)
  where t.id = p_thread and t.deleted_at is null and gf_is_gate_manager(t.gate_id, auth.uid());
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

create or replace function public.gf_board_delete(p_kind text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare tid uuid;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_kind = 'thread' then
    update gf_board_threads t set deleted_at = now()
    where t.id = p_id and t.deleted_at is null
      and (t.author = auth.uid() or gf_is_gate_manager(t.gate_id, auth.uid()))
    returning t.id into tid;
  elsif p_kind = 'reply' then
    update gf_board_replies r set deleted_at = now()
    from gf_board_threads t
    where r.id = p_id and r.deleted_at is null and t.id = r.thread_id
      and (r.author = auth.uid() or gf_is_gate_manager(t.gate_id, auth.uid()))
    returning r.thread_id into tid;
    if tid is not null then
      update gf_board_threads set reply_count = greatest(reply_count - 1, 0) where id = tid;
    end if;
  end if;
  if tid is null then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

create or replace function public.gf_board_resolve(p_thread uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  update gf_board_threads t
     set resolved_at = case when coalesce(p_on, false) then coalesce(t.resolved_at, now()) end
   where t.id = p_thread and t.deleted_at is null
     and (t.author = me or gf_is_gate_manager(t.gate_id, me));
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- ============ カードを直す（書いた本人。文を変えたら「直しました」。最初の文は 1 回だけ残す＝通報の確認用） ============
alter table public.gf_graffiti add column if not exists edited_at timestamptz;
alter table public.gf_graffiti add column if not exists original_body text;

create or replace function public.gf_edit_graffiti(p_id uuid, p_body text, p_visibility text, p_local_only boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  x public.gf_graffiti;
  b text;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into x from gf_graffiti g where g.id = p_id and g.author = me and g.deleted_at is null;
  if x.id is null then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  b := btrim(coalesce(p_body, x.body));
  if char_length(b) > 280 then raise exception 'gf_too_long' using errcode = 'P0001'; end if;
  if b = '' and x.photo_path is null then raise exception 'gf_bad_body' using errcode = 'P0001'; end if;
  if p_visibility is not null and p_visibility not in ('private', 'friends', 'public') then
    raise exception 'gf_bad_kind' using errcode = 'P0001';
  end if;
  perform gf_take_rate('graffiti_edit', gf_setting('graffiti_edits_per_hour'), 3600);
  update gf_graffiti g set
    body = b,
    visibility = coalesce(p_visibility, g.visibility),
    local_only = coalesce(p_local_only, g.local_only),
    original_body = case when g.original_body is null and b <> x.body then x.body else g.original_body end,
    edited_at = case when b <> x.body then now() else g.edited_at end
  where g.id = p_id;
end $$;

-- ============ メッセージに写真（自分のフォルダの写真。見られるのは送った人と受け取った人だけ） ============
alter table public.gf_dm_messages add column if not exists photo_path text;
alter table public.gf_dm_messages drop constraint if exists gf_dm_messages_body_check;
alter table public.gf_dm_messages drop constraint if exists gf_dm_messages_content_check;
alter table public.gf_dm_messages add constraint gf_dm_messages_content_check
  check (char_length(body) <= 1000 and (char_length(btrim(body)) >= 1 or photo_path is not null));
create index if not exists gf_dm_messages_photo on public.gf_dm_messages(photo_path) where photo_path is not null;

create or replace function public.gf_dm_send2(p_to uuid, p_body text, p_photo_path text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  mid uuid;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_to is null or p_to = me or not gf_mutual(me, p_to) or gf_blocked(me, p_to) then
    raise exception 'gf_bad_recipient' using errcode = 'P0001';
  end if;
  if p_photo_path is not null and (split_part(p_photo_path, '/', 1) <> me::text or p_photo_path like '%..%') then
    raise exception 'gf_bad_media_path' using errcode = 'P0001';
  end if;
  perform gf_take_rate('dm', gf_setting('dm_per_hour'), 3600);
  begin
    insert into gf_dm_messages (sender, recipient, body, photo_path)
    values (me, p_to, btrim(coalesce(p_body, '')), p_photo_path)
    returning id into mid;
  exception when check_violation then
    raise exception 'gf_bad_post' using errcode = 'P0001';
  end;
  return mid;
end $$;

create or replace function public.gf_dm_messages_with2(p_other uuid)
returns table (id uuid, sender uuid, body text, photo_path text, created_at timestamptz, read_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if gf_blocked(me, p_other) then return; end if;
  update gf_dm_messages d set read_at = now()
    where d.sender = p_other and d.recipient = me and d.read_at is null;
  return query
    select x.id, x.sender, x.body, x.photo_path, x.created_at, x.read_at from (
      select d.id, d.sender, d.body, d.photo_path, d.created_at, d.read_at
      from gf_dm_messages d
      where ((d.sender = me and d.recipient = p_other) or (d.sender = p_other and d.recipient = me))
        and d.deleted_at is null
      order by d.created_at desc limit 200) x
    order by x.created_at;
end $$;

-- ============ 写真を見てよいか（ここまでの全部。メッセージの写真を足す） ============
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
    or exists (select 1 from gf_snapshots s where s.photo_path = p_path and gf_can_see_snapshot(s, auth.uid()))
    or exists (select 1 from gf_dm_messages d where d.photo_path = p_path and d.deleted_at is null
               and (d.sender = auth.uid() or d.recipient = auth.uid()) and not gf_blocked(d.sender, d.recipient)))
$$;

-- ============ 呼べる関数を絞る ============
revoke all on function public.gf_is_gate_manager(uuid, uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'gf_set_notify_mute(text[], boolean)',
    'gf_add_gate_manager(uuid, uuid)', 'gf_remove_gate_manager(uuid, uuid)', 'gf_gate_managers_of(uuid)',
    'gf_my_managed_gates()', 'gf_edit_gate(uuid, text, text, text, text)', 'gf_set_gate_open(uuid, boolean)',
    'gf_board_pin(uuid, boolean)', 'gf_board_delete(text, uuid)', 'gf_board_resolve(uuid, boolean)',
    'gf_edit_graffiti(uuid, text, text, boolean)', 'gf_dm_send2(uuid, text, text)', 'gf_dm_messages_with2(uuid)',
    'gf_can_read_media(text)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
