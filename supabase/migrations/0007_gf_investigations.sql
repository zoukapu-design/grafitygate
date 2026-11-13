-- Grafity Gate：共同調査（その場所の歴史や謎を、ここに来た人どうしで調べる）
--
-- 掲示板の話題の種類に「調べる」を足し、返信に「事実／観察／仮説／噂」のしるしと出典（URL・本の名前など）を付けられるようにする。
-- しるしは書いた人が選ぶ（確かさをサーバーが決めるのではない）。画面では、しるしごとに分けて見られる。
--
-- 使い方：0006 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

alter table public.gf_board_threads drop constraint if exists gf_board_threads_topic_check;
alter table public.gf_board_threads add constraint gf_board_threads_topic_check
  check (topic in ('memory', 'question', 'notice', 'investigation', 'other'));

alter table public.gf_board_replies add column if not exists label text;
alter table public.gf_board_replies add column if not exists source text;
alter table public.gf_board_replies drop constraint if exists gf_board_replies_label_check;
alter table public.gf_board_replies add constraint gf_board_replies_label_check
  check (label is null or label in ('fact', 'observation', 'hypothesis', 'rumor'));
alter table public.gf_board_replies drop constraint if exists gf_board_replies_source_check;
alter table public.gf_board_replies add constraint gf_board_replies_source_check
  check (source is null or char_length(source) between 1 and 300);

-- 返信する（しるしと出典つき。入場中だけ）。調べる話題でなければ、しるしは付けない
create or replace function public.gf_board_reply2(p_visit uuid, p_thread uuid, p_body text, p_label text, p_source text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  rid uuid;
  topic_of text;
begin
  rid := gf_board_reply(p_visit, p_thread, p_body);
  select t.topic into topic_of from gf_board_threads t where t.id = p_thread;
  if topic_of = 'investigation' and (p_label is not null or nullif(btrim(coalesce(p_source, '')), '') is not null) then
    begin
      update gf_board_replies set label = p_label, source = nullif(btrim(coalesce(p_source, '')), '') where id = rid;
    exception when check_violation then
      raise exception 'gf_bad_post' using errcode = 'P0001';
    end;
  end if;
  return rid;
end $$;

-- 返信の一覧（しるしと出典つき。読んだ印も付ける）
create or replace function public.gf_board_replies_of2(p_thread uuid)
returns table (id uuid, author uuid, author_name text, body text, created_at timestamptz, label text, source text)
language plpgsql security definer set search_path = public as $$
begin
  return query
    select r.id, r.author, r.author_name, r.body, r.created_at, x.label, x.source
    from gf_board_replies_of(p_thread) r
    join gf_board_replies x on x.id = r.id;
end $$;

-- 調べる話題の、しるしごとの数（話題の一覧に出す）
create or replace function public.gf_investigation_counts(p_thread uuid)
returns table (label text, n bigint)
language plpgsql stable security definer set search_path = public as $$
declare t gf_board_threads;
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into t from gf_board_threads where gf_board_threads.id = p_thread;
  if not found or not gf_can_see_thread(t, auth.uid()) then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  return query
    select r.label, count(*) from gf_board_replies r
    where r.thread_id = t.id and r.deleted_at is null and r.label is not null
      and (r.author = auth.uid() or (not gf_blocked(auth.uid(), r.author) and gf_active_visit(t.gate_id, auth.uid()) is not null))
    group by r.label;
end $$;

do $$
declare f text;
begin
  foreach f in array array['gf_board_reply2(uuid, uuid, text, text, text)', 'gf_board_replies_of2(uuid)',
                           'gf_investigation_counts(uuid)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
