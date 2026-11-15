-- 0023：掲示板の「調べる」（共同調査）に、返信への「なるほど」と、調べ方の進み具合・まとめを足す。
-- 「なるほど」は、話題が見える人（現地で扉を開けた人・書いた本人）が、ほかの人の返信に 1 人 1 回。
-- 進み具合（調べ中／しぼれてきた／まとまった）とまとめは、話題を立てた人と GATE を管理する人が決める。
-- 「まとまった」にすると「解決しました」にもなる。何度実行しても大丈夫な書き方。

create table if not exists public.gf_board_reply_votes (
  reply_id uuid not null references public.gf_board_replies(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (reply_id, user_id)
);
create index if not exists gf_board_reply_votes_user on public.gf_board_reply_votes(user_id);
alter table public.gf_board_reply_votes enable row level security;
-- 表は直接読ませない（返信の一覧に数と自分の印を付けて返す）

alter table public.gf_board_threads add column if not exists progress text not null default 'open';
alter table public.gf_board_threads drop constraint if exists gf_board_threads_progress_check;
alter table public.gf_board_threads add constraint gf_board_threads_progress_check
  check (progress in ('open', 'narrowing', 'concluded'));
alter table public.gf_board_threads add column if not exists conclusion text;
alter table public.gf_board_threads drop constraint if exists gf_board_threads_conclusion_check;
alter table public.gf_board_threads add constraint gf_board_threads_conclusion_check
  check (conclusion is null or char_length(conclusion) between 1 and 600);

-- 「なるほど」を付ける・外す（調べる話題の、ほかの人の返信だけ）。返すのはその返信の数
create or replace function public.gf_board_vote(p_reply uuid, p_on boolean) returns int
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r public.gf_board_replies;
  t public.gf_board_threads;
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  select * into r from gf_board_replies x where x.id = p_reply and x.deleted_at is null;
  if r.id is null then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
  select * into t from gf_board_threads x where x.id = r.thread_id;
  if t.id is null or t.topic <> 'investigation' or not gf_can_see_thread(t, me) or gf_blocked(me, r.author) then
    raise exception 'gf_not_found' using errcode = 'P0001';
  end if;
  if r.author = me then raise exception 'gf_own_reply' using errcode = 'P0001'; end if;
  if coalesce(p_on, false) then
    insert into gf_board_reply_votes (reply_id, user_id) values (r.id, me) on conflict do nothing;
  else
    delete from gf_board_reply_votes v where v.reply_id = r.id and v.user_id = me;
  end if;
  return (select count(*)::int from gf_board_reply_votes v where v.reply_id = r.id);
end $$;

-- 返信の一覧（0014 の形に「なるほど」の数と自分の印を足す）
create or replace function public.gf_board_replies_of4(p_thread uuid)
returns table (id uuid, author uuid, author_name text, body text, created_at timestamptz, label text, source text,
               edited_at timestamptz, votes int, my_vote boolean)
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  return query
    select r.id, r.author, r.author_name, r.body, r.created_at, r.label, r.source, r.edited_at,
           (select count(*)::int from gf_board_reply_votes v where v.reply_id = r.id and not gf_blocked(me, v.user_id)),
           exists (select 1 from gf_board_reply_votes v where v.reply_id = r.id and v.user_id = me)
    from gf_board_replies_of3(p_thread) r
    order by r.created_at;
end $$;

-- 進み具合とまとめを決める（話題を立てた人と、GATE を管理する人）
create or replace function public.gf_board_set_progress(p_thread uuid, p_progress text, p_conclusion text) returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  c text := nullif(btrim(coalesce(p_conclusion, '')), '');
begin
  if me is null then raise exception 'gf_not_signed_in' using errcode = 'P0001'; end if;
  if p_progress not in ('open', 'narrowing', 'concluded') then raise exception 'gf_bad_kind' using errcode = 'P0001'; end if;
  if c is not null and char_length(c) > 600 then raise exception 'gf_too_long' using errcode = 'P0001'; end if;
  update gf_board_threads t
     set progress = p_progress,
         conclusion = c,
         resolved_at = case when p_progress = 'concluded' then coalesce(t.resolved_at, now())
                            else t.resolved_at end
   where t.id = p_thread and t.deleted_at is null and t.topic = 'investigation'
     and (t.author = me or gf_is_gate_manager(t.gate_id, me));
  if not found then raise exception 'gf_not_found' using errcode = 'P0001'; end if;
end $$;

-- 話題の一覧（0018 の形に、進み具合を足す）
create or replace function public.gf_board_list4(p_gate uuid)
returns table (id uuid, author uuid, author_name text, topic text, title text, body text, pinned boolean,
               reply_count int, last_activity_at timestamptz, created_at timestamptz, unread boolean,
               edited_at timestamptz, resolved boolean, progress text, conclusion text)
language plpgsql security definer set search_path = public as $$
begin
  return query
    select l.id, l.author, l.author_name, l.topic, l.title, l.body, l.pinned, l.reply_count,
           l.last_activity_at, l.created_at, l.unread, l.edited_at, l.resolved, x.progress, x.conclusion
    from gf_board_list3(p_gate) l
    join gf_board_threads x on x.id = l.id
    order by l.pinned desc, l.last_activity_at desc;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'gf_board_vote(uuid, boolean)', 'gf_board_replies_of4(uuid)', 'gf_board_set_progress(uuid, text, text)',
    'gf_board_list4(uuid)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
