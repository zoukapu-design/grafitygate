-- 場所の記憶（0002）のテスト。test_core.sql のあとの状態（人・GATE）を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set dave  '00000000-0000-0000-0000-00000000000d'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_dave  'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000d'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'
\set same 'array_fill(0.25::real, array[16])'

\echo '== 場所の記憶'
:as_admin
select id as g2 from gf_gates where client_key = 'alice-gate-0006' \gset
insert into storage.objects (bucket_id, name) values ('gf-maps', :'alice' || '/g2.map');

:as_alice
select gf_register_place_map(:'g2', :'alice' || '/g2.map', 2048000, 'gg.gate');
select t_ok((select path from gf_place_map(:'g2')) = :'alice' || '/g2.map', '作った人は自分の GATE に場所の記憶を登録できる');
select gf_register_place_map(:'g2', :'alice' || '/g2.map', 2100000, 'gg.gate');
select t_ok((select byte_size from gf_place_map(:'g2')) = 2100000, '撮り直すと置き換わる（1 つの GATE に 1 つ）');
select t_throws(format('select gf_register_place_map(%L, %L, 10, null)', :'g2', :'bob' || '/x.map'), 'gf_bad_media_path',
  '他人のフォルダのファイルは登録できない');
select t_ok((select count(*) from storage.objects where bucket_id = 'gf-maps') = 1, '作った人は自分の場所の記憶のファイルを読める');

:as_bob
select t_throws(format('select gf_register_place_map(%L, %L, 10, null)', :'g2', :'bob' || '/g2.map'), 'gf_not_found',
  '他人の GATE には登録できない');
select t_ok((select count(*) from gf_place_maps) = 0, '場所の記憶の表は直接読めない');

:as_dave
select t_ok(not exists (select 1 from gf_place_map(:'g2')), '入場していない人には場所の記憶を渡さない');
select t_ok((select count(*) from storage.objects where bucket_id = 'gf-maps') = 0, '入場していない人はファイルも読めない');
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g2', :'c', 35.80300, 139.72000, 5, :same, 2) ->> 'visit_id' as vd \gset
select t_ok((select path from gf_place_map(:'g2')) = :'alice' || '/g2.map', '入場中の人は場所の記憶を受け取れる');
select t_ok((select count(*) from storage.objects where bucket_id = 'gf-maps') = 1, '入場中の人はファイルを読める');
select t_throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'gf-maps', :'alice' || '/evil.map'),
  'row-level security', '他人のフォルダには場所の記憶を置けない');
:as_admin
update gf_visits set expires_at = now() - interval '1 second' where id = :'vd';
:as_dave
select t_ok(not exists (select 1 from gf_place_map(:'g2')), '入場券が切れたら場所の記憶は渡さない');
select t_ok((select count(*) from storage.objects where bucket_id = 'gf-maps') = 0, '入場券が切れたらファイルも読めない');

:as_alice
delete from gf_gates where id = :'g2';
:as_admin
select t_ok((select count(*) from gf_place_maps where gate_id = :'g2') = 0, 'GATE を消すと場所の記憶の登録も消える');
reset role;
\echo '== 場所の記憶：すべて通りました'
