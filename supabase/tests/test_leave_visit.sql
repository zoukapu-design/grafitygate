-- 扉を出る（0025）のテスト。run.sh から実行する。
\set ON_ERROR_STOP on
\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'

\echo '== 扉を出る'
:as_admin
select id as vg from gf_gates where client_key = 'view-gate-0001' \gset
select id as bv from gf_visits where gate_id = :'vg' and user_id = :'bob' and revoked_at is null
  order by created_at desc limit 1 \gset
update gf_visits set expires_at = now() + interval '10 minutes' where id = :'bv';
:as_alice
select gf_leave_visit(:'bv');
:as_admin
select t_ok((select expires_at > now() from gf_visits where id = :'bv'), 'ほかの人の入場は終わらせられない');
:as_bob
select t_ok((gf_gate_peek(:'vg') ->> 'inside')::boolean, '出る前は扉が開いている');
select gf_leave_visit(:'bv');
select t_ok(not (gf_gate_peek(:'vg') ->> 'inside')::boolean, '「扉を出る」で、その場で扉が閉じる');
select t_ok((gf_gate_peek(:'vg') ->> 'opened')::boolean, '出たあとも、一度開けた GATE として遠くから読める');
:as_admin
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'vg';
