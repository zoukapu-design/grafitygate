-- Grafity Gate：掲示板の話題・返信を、書いた本人があとから直す
--
-- 直せるのは書いた本人だけ（GATE を作った人でも、ほかの人の文は直せない。消すことはできる）。
-- 遠くからでも直せる（消すのと同じ）。直したら edited_at を付け、一覧に「直しました」と出す。
-- 最初の文は original_title / original_body に 1 回だけ残す（通報を確かめるとき、直す前の文が分かるように）。
-- 調べる話題の返信の「しるし」と「出典」は変えない（直せるのは文だけ）。
--
-- 使い方：0013 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

insert into public.gf_settings (key, value, note) values
  ('board_edits_per_hour', 30, '1 時間に直せる掲示板の話題・返信の数')
on conflict (key) do nothing;

alter table public.gf_board_threads add column if not exists edited_at timestamptz;
alter table public.gf_board_threads add column if not exists original_title text;
alter table public.gf_board_threads add column if not exists original_body text;
alter table public.gf_board_replies add column if not exists edited_at timestamptz;
alter table public.gf_board_replies add column if not exists original_body text;

-- 直す。p_kind は thread / reply。返信のときは p_title を使わない。
create or replace function public.gf_board_edit(p_kind text, p_id uuid, p_title text, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare
  t gf_board_threads;
  r gf_board_replies;
  new_title text := btrim(coalesce(p_title, ''));
  new_body text := btrim(coalesce(p_body, ''));
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  -- いまの規約に同意していない人は、書き込みと同じく直せない
  if not exists (select 1 from gf_terms x where x.user_id = auth.uid() and x.version >= gf_terms_version()) then
    raise exception 'gf_terms_required' using errcode = 'P0001';
  end if;

  if p_kind = 'thread' then
    select * into t from gf_board_threads where id = p_id and deleted_at is null and author = auth.uid() for update;
    if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
    if char_length(new_title) not between 1 and 60 then raise exception 'gf_bad_title' using errcode = 'P0001'; end if;
    if char_length(new_body) > 1000 then raise exception 'gf_too_long' using errcode = 'P0001'; end if;
    if new_title = t.title and new_body = t.body then return; end if;
    perform gf_take_rate('board_edit', gf_setting('board_edits_per_hour'), 3600);
    update gf_board_threads
      set title = new_title, body = new_body, edited_at = now(),
          original_title = coalesce(original_title, t.title),
          original_body = coalesce(original_body, t.body)
      where id = t.id;
  elsif p_kind = 'reply' then
    select r2.* into r from gf_board_replies r2
      join gf_board_threads t2 on t2.id = r2.thread_id and t2.deleted_at is null
      where r2.id = p_id and r2.deleted_at is null and r2.author = auth.uid()
      for update of r2;
    if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
    if char_length(new_body) not between 1 and 1000 then raise exception 'gf_bad_body' using errcode = 'P0001'; end if;
    if new_body = r.body then return; end if;
    perform gf_take_rate('board_edit', gf_setting('board_edits_per_hour'), 3600);
    update gf_board_replies
      set body = new_body, edited_at = now(), original_body = coalesce(original_body, r.body)
      where id = r.id;
  else
    raise exception 'gf_bad_kind' using errcode = 'P0001';
  end if;
end $$;

-- 話題の一覧（gf_board_list と同じ見え方に、直した時刻を足す）
create or replace function public.gf_board_list2(p_gate uuid)
returns table (id uuid, author uuid, author_name text, topic text, title text, body text, pinned boolean,
               reply_count int, last_activity_at timestamptz, created_at timestamptz, unread boolean,
               edited_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  return query
    select l.id, l.author, l.author_name, l.topic, l.title, l.body, l.pinned, l.reply_count,
           l.last_activity_at, l.created_at, l.unread, x.edited_at
    from gf_board_list(p_gate) l
    join gf_board_threads x on x.id = l.id
    order by l.pinned desc, l.last_activity_at desc;
end $$;

-- 返信の一覧（gf_board_replies_of2 と同じ見え方に、直した時刻を足す）
create or replace function public.gf_board_replies_of3(p_thread uuid)
returns table (id uuid, author uuid, author_name text, body text, created_at timestamptz, label text, source text,
               edited_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  return query
    select r.id, r.author, r.author_name, r.body, r.created_at, r.label, r.source, x.edited_at
    from gf_board_replies_of2(p_thread) r
    join gf_board_replies x on x.id = r.id
    order by r.created_at;
end $$;

do $$
declare f text;
begin
  foreach f in array array['gf_board_edit(text, uuid, text, text)', 'gf_board_list2(uuid)',
                           'gf_board_replies_of3(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
