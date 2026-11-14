-- 利用規約への同意（0013）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set frank '00000000-0000-0000-0000-0000000000f1'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_frank 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-0000000000f1'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'
\set same 'array_fill(0.25::real, array[16])'

\echo '== 利用規約への同意'
:as_admin
delete from gf_rate;
insert into auth.users values (:'frank') on conflict do nothing;
insert into profiles (id, display_name, handle) values (:'frank', 'フランク', 'frank') on conflict do nothing;
delete from gf_terms where user_id = :'frank';

:as_frank
select t_ok((gf_my_terms() ->> 'accepted') is null and (gf_my_terms() ->> 'current')::int = 1,
  'はじめは同意していない（いまの版は 1）');
select challenge_id as c from gf_request_challenge() \gset
select t_throws(format('select gf_create_gate(%L, %L, %L, %L, %L, 35.9, 139.72, 8, null, %L, null, %L::jsonb)',
  'frank-gate-0001', :'c', 'はじめての GATE', '', 'place', 'public',
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))), 'gf_terms_required',
  '利用規約に同意する前は、GATE を作れない');
select t_throws('select gf_accept_terms(2)', 'gf_bad_terms', 'まだ無い版には同意できない');
select t_throws('select gf_accept_terms(0)', 'gf_bad_terms', '前の版には同意できない');
select t_throws(format('insert into gf_terms (user_id, version) values (%L, 1)', :'frank'), 'permission denied',
  '同意の記録を直接は書けない（関数からだけ）');
select gf_accept_terms(1);
select t_ok((gf_my_terms() ->> 'accepted')::int = 1, '同意すると、同意した版が残る');
select challenge_id as c from gf_request_challenge() \gset
select t_ok(gf_create_gate('frank-gate-0001', :'c', 'はじめての GATE', '', 'place', 35.9, 139.72, 8, null, 'public', null,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))) is not null,
  '同意したあとは、GATE を作れる');
select t_ok((select count(*) from gf_terms) = 1, 'ほかの人の同意の記録は見えない');

\echo '== 規約の版を上げると、もう一度同意が要る'
:as_admin
update gf_settings set value = 2 where key = 'terms_version';
:as_frank
select challenge_id as c from gf_request_challenge() \gset
select t_throws(format('select gf_create_gate(%L, %L, %L, %L, %L, 35.9, 139.73, 8, null, %L, null, %L::jsonb)',
  'frank-gate-0002', :'c', '二つ目', '', 'place', 'public',
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))), 'gf_terms_required',
  '新しい版に同意するまでは、作れない');
select gf_accept_terms(2);
select challenge_id as c from gf_request_challenge() \gset
select t_ok(gf_create_gate('frank-gate-0002', :'c', '二つ目', '', 'place', 35.9, 139.73, 8, null, 'public', null,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))) is not null,
  '新しい版に同意すると、また作れる');

\echo '== アカウントを消すと、同意の記録も消える'
:as_frank
select gf_delete_me();
:as_admin
select t_ok(not exists (select 1 from gf_terms where user_id = :'frank'), 'アカウントを消すと、同意の記録も消える');
update gf_settings set value = 1 where key = 'terms_version';
