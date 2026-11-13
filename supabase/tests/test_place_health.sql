-- 場所の記憶の見つかりやすさと GATE の数字（0008）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set dave  '00000000-0000-0000-0000-00000000000d'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_dave  'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000d'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'
\set same 'array_fill(0.25::real, array[16])'

\echo '== 場所の記憶の見つかりやすさ'
:as_admin
delete from gf_rate;
select id as g4 from gf_gates where client_key = 'alice-gate-0101' \gset

:as_alice
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g4', :'c', 35.82, 139.72, 5, :same, 2) ->> 'visit_id' as va \gset
select gf_report_relocalize(:'va', false, 20);
:as_bob
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g4', :'c', 35.82, 139.72, 5, :same, 2) ->> 'visit_id' as vb \gset
select gf_report_relocalize(:'vb', false, 20);
:as_carol
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g4', :'c', 35.82, 139.72, 5, :same, 2) ->> 'visit_id' as vc \gset
select gf_report_relocalize(:'vc', false, 20);
:as_alice
select t_ok(not exists (select 1 from gf_my_notifications() where kind = 'place_map_stale'),
  '作った本人と 2 人が見つけられなかっただけでは、まだ知らせない（本人の分は数えない）');
:as_dave
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g4', :'c', 35.82, 139.72, 5, :same, 2) ->> 'visit_id' as vd \gset
select gf_report_relocalize(:'vd', false, 20);
select t_ok((select count(*) from gf_relocalize_log) = 0, '探した記録の表は直接読めない');
select t_throws(format('select * from gf_place_map_health(%L)', :'g4'), 'gf_not_found', '見つかりやすさは作った本人だけが見られる');
select t_throws(format('select gf_report_relocalize(%L, true, 1)', :'vb'), 'gf_visit_invalid', '他人の入場券では送れない');
:as_alice
select t_ok((select count(*) from gf_my_notifications() where kind = 'place_map_stale' and gate_id = :'g4') = 1,
  '見つからない日が続くと、作った人に「場所の記憶を撮り直す」知らせが届く');
select t_ok((select actor from gf_my_notifications() where kind = 'place_map_stale' limit 1) = :'alice',
  'だれが見つけられなかったかは知らせない');
select t_ok((select attempts from gf_place_map_health(:'g4')) = 4 and (select found from gf_place_map_health(:'g4')) = 0,
  '作った本人は、探した回数と見つかった回数が分かる');
:as_bob
select gf_report_relocalize(:'vb', true, 4);
:as_alice
select t_ok((select found from gf_place_map_health(:'g4')) = 1, '同じ入場で送り直すと上書きされる');
select gf_register_place_map(:'g4', :'alice' || '/g4.worldmap', 1000, 'gg.gate');
select t_ok((select attempts from gf_place_map_health(:'g4')) = 0 and (select has_map from gf_place_map_health(:'g4')),
  '場所の記憶を撮り直すと、それまでの記録は数えない');

\echo '== GATE の数字'
:as_dave
select t_ok((select visitor_count from gf_gate_stats(:'g4')) >= 4, '訪れた人の数が分かる');
select t_ok((select last_activity_at from gf_gate_stats(:'g4')) is not null, '最後に記録が増えた日が分かる');
select t_ok((select my_visits from gf_gate_stats(:'g4')) = 1, '自分が訪れた回数が分かる');
select t_throws(format('select * from gf_gate_stats(%L)', (select gen_random_uuid())), 'gf_not_found', 'ない GATE の数字は出さない');
reset role;
\echo '== 場所の記憶の見つかりやすさと GATE の数字：すべて通りました'
