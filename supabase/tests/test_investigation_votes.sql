-- 掲示板の「調べる」の「なるほど」と進み具合（0023）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'
\set vlat50 35.83045
\set vlon 139.75000
\set day 'array_fill(0.25::real, array[16])'

\echo '== 調べる：「なるほど」と進み具合'
:as_admin
delete from gf_rate;
select id as vg from gf_gates where client_key = 'view-gate-0001' \gset
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'vg';
:as_bob
select challenge_id as c from gf_request_challenge() \gset
select (gf_enter(:'vg', :'c', :vlat50, :vlon, 10, :day, 2) ->> 'visit_id') as vb \gset
select gf_board_post(:'vb', 'investigation', 'この丘の名前の由来', '昔の地図で調べたい') as it \gset
:as_alice
select challenge_id as c from gf_request_challenge() \gset
select (gf_enter(:'vg', :'c', :vlat50, :vlon, 10, :day, 2) ->> 'visit_id') as va \gset
select gf_board_reply2(:'va', :'it', '昔は物見の場所だったのでは', 'hypothesis', null) as rep \gset
select t_throws(format('select gf_board_vote(%L, true)', :'rep'), 'gf_own_reply', '自分の返信には「なるほど」を付けられない');
:as_bob
select t_ok(gf_board_vote(:'rep', true) = 1, '話題が見える人は「なるほど」を付けられる');
select t_ok(gf_board_vote(:'rep', true) = 1, '2 回押しても 1 つ');
select t_ok((select votes = 1 and my_vote from gf_board_replies_of4(:'it') where id = :'rep'), '返信の一覧に数と自分の印が出る');
:as_carol
select t_throws(format('select gf_board_vote(%L, true)', :'rep'), 'gf_not_found', 'GATE の外の人は付けられない');
select t_throws(format('select gf_board_set_progress(%L, %L, null)', :'it', 'narrowing'), 'gf_not_found',
  'ほかの人は進み具合を変えられない');
:as_bob
select gf_board_set_progress(:'it', 'narrowing', null);
select t_ok((select progress = 'narrowing' and not resolved from gf_board_list4(:'vg') where id = :'it'),
  '話題を立てた人は「しぼれてきた」にできる');
select t_throws(format('select gf_board_set_progress(%L, %L, null)', :'it', 'done'), 'gf_bad_kind', '知らない進み具合は断る');
:as_alice
select gf_board_set_progress(:'it', 'concluded', '物見の場所だったと、図書館の資料で分かった');
:as_bob
select t_ok((select progress = 'concluded' and resolved and conclusion like '物見%' from gf_board_list4(:'vg') where id = :'it'),
  'GATE を作った人は「まとまった」とまとめを書ける（解決しましたにもなる）');
select t_ok(gf_board_vote(:'rep', false) = 0, '「なるほど」を外せる');

:as_admin
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'vg';
delete from gf_rate;
