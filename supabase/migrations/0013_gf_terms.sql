-- Grafity Gate：利用規約・プライバシーポリシーへの同意
--
-- 人が書いたものを見せるアプリは、好ましくない内容や迷惑な行いを許さない規約に同意してもらってから
-- 書いてもらう（App Store の決まり 1.2）。同意した版を gf_terms に残し、
-- GATE・記憶・作品・掲示板・手紙・思い出・メッセージ・TRAIL・今と昔の写真を新しく作るとき、
-- いまの版に同意していなければサーバーが断る（gf_terms_required）。
-- 規約を変えて同意し直してもらうときは、gf_settings の terms_version を上げる。
--
-- 使い方：0012 のあとに、Supabase の SQL Editor に貼って実行する。何度実行しても大丈夫。

insert into public.gf_settings (key, value, note) values
  ('terms_version', 1, '利用規約・プライバシーポリシーの版（上げると、全員にもう一度同意してもらう）')
on conflict (key) do nothing;

create table if not exists public.gf_terms (
  user_id uuid primary key references auth.users(id) on delete cascade,
  version int not null check (version >= 1),
  accepted_at timestamptz not null default now()
);
alter table public.gf_terms enable row level security;
drop policy if exists gf_terms_own on public.gf_terms;
create policy gf_terms_own on public.gf_terms for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on public.gf_terms from anon, authenticated;

-- いまの版
create or replace function public.gf_terms_version() returns int
language sql stable security definer set search_path = public as $$
  select coalesce(gf_setting('terms_version'), 1)::int
$$;

-- 自分が同意した版と、いまの版（アプリが「同意の画面」を出すか決める）
create or replace function public.gf_my_terms() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'accepted', (select version from gf_terms where user_id = auth.uid()),
    'current', gf_terms_version())
$$;

-- 同意する（いまの版だけ。前の版や先の版には同意できない）
create or replace function public.gf_accept_terms(p_version int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'gf_not_signed_in'; end if;
  if p_version is distinct from gf_terms_version() then raise exception 'gf_bad_terms'; end if;
  insert into gf_terms (user_id, version, accepted_at) values (auth.uid(), p_version, now())
  on conflict (user_id) do update set version = excluded.version, accepted_at = excluded.accepted_at;
end $$;

-- 書く・作るときの見張り。ログインした人の操作（auth.uid() がある）だけを見る。
-- サーバーの中の処理（trigger からの書き込み・管理者）は止めない。
create or replace function public.gf_terms_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null
     and not exists (select 1 from gf_terms t where t.user_id = auth.uid() and t.version >= gf_terms_version()) then
    raise exception 'gf_terms_required';
  end if;
  return new;
end $$;

do $$
declare
  t text;
begin
  foreach t in array array['gf_gates', 'gf_graffiti', 'gf_artworks', 'gf_dm_messages', 'gf_board_threads',
                           'gf_board_replies', 'gf_letters', 'gf_memories', 'gf_memory_items', 'gf_trails',
                           'gf_snapshots'] loop
    execute format('drop trigger if exists gf_terms_guard on public.%I', t);
    execute format('create trigger gf_terms_guard before insert on public.%I for each row execute function public.gf_terms_guard()', t);
  end loop;
end $$;

revoke all on function public.gf_terms_version() from public, anon;
grant execute on function public.gf_terms_version() to authenticated;
revoke all on function public.gf_my_terms() from public, anon;
grant execute on function public.gf_my_terms() to authenticated;
revoke all on function public.gf_accept_terms(int) from public, anon;
grant execute on function public.gf_accept_terms(int) to authenticated;
revoke all on function public.gf_terms_guard() from public, anon, authenticated;
