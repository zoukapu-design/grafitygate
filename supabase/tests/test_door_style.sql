-- 扉の見た目（0028）のテスト。run.sh から実行する。
\set ON_ERROR_STOP on
\set alice '00000000-0000-0000-0000-00000000000a'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'

\echo '== 扉の見た目'
:as_admin
select id as dgate from gf_gates where owner = :'alice' and status = 'open' order by created_at limit 1 \gset
:as_alice
select t_ok((gf_gate_door(:'dgate') ->> 'style') = 'neon', 'はじめはネオン');
select gf_set_door_style(:'dgate', 'torii');
select t_ok((gf_gate_door(:'dgate') ->> 'style') = 'torii', '作った本人は見た目を変えられる');
select t_throws(format('select gf_set_door_style(%L, %L)', :'dgate', 'castle'), 'gf_bad_style', '決まった見た目だけ');
:as_bob
select t_throws(format('select gf_set_door_style(%L, %L)', :'dgate', 'heart'), 'gf_not_found', 'ほかの人は変えられない');
:as_alice
select gf_set_door_style(:'dgate', 'neon');
