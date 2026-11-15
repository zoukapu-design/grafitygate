-- 扉の大きさ（0016）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'

\echo '== 扉の大きさ'
:as_admin
select id as pub from gf_gates where owner = :'alice' and visibility = 'public' and status = 'open' order by created_at limit 1 \gset
select t_ok((select door_scale from gf_gates where id = :'pub') = 1.0, 'はじめの扉の大きさは 1 倍（前に作った GATE もそのまま）');

:as_alice
select gf_set_door_scale(:'pub', 0.35);
select t_ok((gf_gate_door(:'pub') ->> 'scale')::real = 0.35::real, '作った本人は扉の大きさを変えられる');
select t_throws(format('select gf_set_door_scale(%L, 0.1)', :'pub'), 'gf_bad_scale', '小さすぎる大きさにはできない');
select t_throws(format('select gf_set_door_scale(%L, 2)', :'pub'), 'gf_bad_scale', '大きすぎる大きさにはできない');

:as_bob
select t_throws(format('select gf_set_door_scale(%L, 1.2)', :'pub'), 'gf_not_found', 'ほかの人は扉の大きさを変えられない');
select t_ok((gf_gate_door(:'pub') ->> 'scale')::real = 0.35::real, '見る人にも同じ大きさが届く');
