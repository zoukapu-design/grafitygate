-- 共同調査（0007）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set carol '00000000-0000-0000-0000-00000000000c'
\set dave  '00000000-0000-0000-0000-00000000000d'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_dave  'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000d'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'

\echo '== 共同調査'
:as_admin
select id as g4 from gf_gates where client_key = 'alice-gate-0101' \gset
select id as va from gf_visits where user_id = :'alice' and gate_id = :'g4' and expires_at > now() order by expires_at desc limit 1 \gset
select id as vc from gf_visits where user_id = :'carol' and gate_id = :'g4' and expires_at > now() order by expires_at desc limit 1 \gset
:as_alice
select gf_board_post(:'va', 'investigation', 'この桜はいつ植えられた？', '') as t3 \gset
select t_ok(:'t3' is not null, '「調べる」話題を立てられる');
:as_carol
select gf_board_reply2(:'vc', :'t3', '石碑に昭和 30 年とある', 'fact', '川沿いの石碑') as r1 \gset
select gf_board_reply2(:'vc', :'t3', '戦後の植樹かもしれない', 'hypothesis', null) as r2 \gset
select t_throws(format('select gf_board_reply2(%L, %L, %L, %L, null)', :'vc', :'t3', 'たぶん', 'guess'), 'gf_bad_post',
  '決まっていないしるしは付けられない');
select t_ok((select label from gf_board_replies_of2(:'t3') where id = :'r1') = 'fact', '返信に「事実」のしるしが付く');
select t_ok((select source from gf_board_replies_of2(:'t3') where id = :'r1') = '川沿いの石碑', '出典も残る');
select t_ok((select n from gf_investigation_counts(:'t3') where label = 'hypothesis') = 1, 'しるしごとの数が分かる');
:as_dave
select t_throws(format('select * from gf_investigation_counts(%L)', :'t3'), 'gf_not_found', '入場していない人には見えない');
reset role;
\echo '== 共同調査：すべて通りました'
