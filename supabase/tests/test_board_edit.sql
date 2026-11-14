-- 掲示板を直す（0014）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'

\echo '== 掲示板を直す'
:as_admin
delete from gf_rate;
-- アリスの話題と、その話題へのボブの返信を使う
select t.id as t1, t.title as t1_title, t.body as t1_body from gf_board_threads t
  where t.author = :'alice' and t.deleted_at is null
    and exists (select 1 from gf_board_replies r where r.thread_id = t.id and r.author = :'bob' and r.deleted_at is null)
  order by t.created_at limit 1 \gset
select id as r1, body as r1_body from gf_board_replies
  where thread_id = :'t1' and author = :'bob' and deleted_at is null order by created_at limit 1 \gset

:as_bob
select t_throws(format('select gf_board_edit(%L, %L, %L, %L)', 'thread', :'t1', '乗っ取り', ''), 'gf_not_found',
  'ほかの人の話題は直せない');

:as_alice
select t_throws(format('select gf_board_edit(%L, %L, %L, %L)', 'reply', :'r1', null, '書きかえ'), 'gf_not_found',
  'ほかの人の返信は直せない（話題を立てた人でも）');
select t_throws(format('select gf_board_edit(%L, %L, %L, %L)', 'thread', :'t1', '   ', 'x'), 'gf_bad_title',
  '題を空にはできない');
select t_throws(format('select gf_board_edit(%L, %L, %L, %L)', 'thread', :'t1', repeat('あ', 61), 'x'), 'gf_bad_title',
  '題は 60 文字まで');
select t_throws(format('select gf_board_edit(%L, %L, %L, %L)', 'thread', :'t1', '題', repeat('あ', 1001)), 'gf_too_long',
  '本文は 1000 文字まで');
select t_throws(format('select gf_board_edit(%L, %L, %L, %L)', 'memo', :'t1', '題', ''), 'gf_bad_kind',
  '決まっていない種類は直せない');
select gf_board_edit('thread', :'t1', :'t1_title', :'t1_body');
:as_admin
select t_ok((select edited_at from gf_board_threads where id = :'t1') is null, '何も変えなければ「直した」にならない');
select count(*) as n_notes from gf_notifications \gset

:as_alice
select gf_board_edit('thread', :'t1', '  去年の花見（訂正）  ', '集まったのは 4 月 2 日でした');
:as_admin
select t_ok((select title = '去年の花見（訂正）' and body = '集まったのは 4 月 2 日でした' and edited_at is not null
             from gf_board_threads where id = :'t1'), '書いた本人は話題を直せる（前後の空白は除く）');
select t_ok((select original_title = :'t1_title' and original_body = :'t1_body' from gf_board_threads where id = :'t1'),
  '直す前の文が残る');
:as_alice
select gf_board_edit('thread', :'t1', '去年の花見（再訂正）', '4 月 2 日の夕方でした');
:as_admin
select t_ok((select original_title = :'t1_title' from gf_board_threads where id = :'t1'),
  '2 回直しても、残るのは最初の文');
select t_ok((select count(*) from gf_notifications) = :n_notes, '直してもお知らせは出ない');
:as_alice
select t_ok((select edited_at is not null from gf_board_list2((select gate_id from gf_board_threads where id = :'t1'))
             where id = :'t1'), '話題の一覧に、直した時刻が出る');

:as_bob
select t_throws(format('select gf_board_edit(%L, %L, %L, %L)', 'reply', :'r1', null, '  '), 'gf_bad_body',
  '返信を空にはできない');
select gf_board_edit('reply', :'r1', null, '行きたかった！来年は行く');
:as_admin
select t_ok((select body = '行きたかった！来年は行く' and edited_at is not null and original_body = :'r1_body'
             from gf_board_replies where id = :'r1'), '書いた本人は返信を直せる。直す前の文が残る');

\echo '== 規約・回数・消したもの'
:as_admin
update gf_settings set value = 2 where key = 'terms_version';
:as_bob
select t_throws(format('select gf_board_edit(%L, %L, %L, %L)', 'reply', :'r1', null, 'もう一度'), 'gf_terms_required',
  'いまの規約に同意していないと直せない');
:as_admin
update gf_settings set value = 1 where key = 'terms_version';
update gf_settings set value = 2 where key = 'board_edits_per_hour';
delete from gf_rate;
:as_bob
select gf_board_edit('reply', :'r1', null, '一回め');
select gf_board_edit('reply', :'r1', null, '二回め');
select t_throws(format('select gf_board_edit(%L, %L, %L, %L)', 'reply', :'r1', null, '三回め'), 'gf_rate_limited',
  '直す回数にも上限がある');
:as_admin
update gf_settings set value = 30 where key = 'board_edits_per_hour';
delete from gf_rate;
update gf_board_replies set deleted_at = now() where id = :'r1';
:as_bob
select t_throws(format('select gf_board_edit(%L, %L, %L, %L)', 'reply', :'r1', null, '消したあと'), 'gf_not_found',
  '消した返信は直せない');
:as_admin
update gf_board_replies set deleted_at = null where id = :'r1';
