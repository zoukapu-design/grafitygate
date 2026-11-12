-- TRAIL と今と昔（0006）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
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

:as_admin
delete from gf_rate;
select id as g3 from gf_gates where client_key = 'dave-gate-00001' \gset
select id as g4 from gf_gates where client_key = 'alice-gate-0101' \gset
insert into storage.objects (bucket_id, name) values ('gf-media', :'bob' || '/snap.jpg'), ('gf-media', :'alice' || '/snap.jpg');

\echo '== TRAIL'
:as_alice
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g3', :'c', 35.81, 139.72, 5, :same, 2) ->> 'visit_id' as va3 \gset
select t_throws(format('select gf_create_trail(%L, %L, %L, %L::uuid[])', '一か所', '', 'public', array[:'g4']::text),
  'gf_bad_trail', '1 か所だけの TRAIL は作れない');
select t_throws(format('select gf_create_trail(%L, %L, %L, %L::uuid[])', '同じ所', '', 'public', array[:'g4', :'g4']::text),
  'gf_bad_trail', '同じ GATE を 2 回入れられない');
select t_throws(format('select gf_create_trail(%L, %L, %L, %L::uuid[])', '行っていない', '', 'public',
  array[:'g4', gen_random_uuid()::text]::text), 'gf_trail_not_visited', '扉を開けたことのない GATE は入れられない');
select gf_create_trail('桜とポスト', '春の散歩道', 'public', array[:'g4', :'g3']::uuid[]) as tr1 \gset
select gf_create_trail('ひみつの道', '', 'private', array[:'g3', :'g4']::uuid[]) as tr2 \gset
select t_ok((select stop_count from gf_trail_list() where id = :'tr1') = 2, '扉を開けた GATE をつないで TRAIL を作れる');
:as_bob
select t_ok(exists (select 1 from gf_trail_list() where id = :'tr1'), '友達の TRAIL が一覧に出る');
select t_ok(not exists (select 1 from gf_trail_list() where id = :'tr2'), '自分だけの TRAIL はほかの人に出ない');
select t_throws(format('select * from gf_trail_stops_of(%L)', :'tr2'), 'gf_not_found', '自分だけの TRAIL の地点は見られない');
:as_carol
select t_ok(not exists (select 1 from gf_trail_list() where id = :'tr1'), '友達でない人の TRAIL は、ふだんの一覧には出ない');
select t_ok(exists (select 1 from gf_trail_list(:'g4') where id = :'tr1'), 'GATE の画面では、その GATE をふくむ公開の TRAIL が出る');
:as_bob
select gf_trail_start(:'tr1');
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g3', :'c', 35.81, 139.72, 5, :same, 2) ->> 'visit_id' as vx \gset
select t_ok((select reached from gf_trail_list() where id = :'tr1') = 0, '順番どおりでない地点では進まない');
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g4', :'c', 35.82, 139.72, 5, :same, 2) ->> 'visit_id' as vb3 \gset
select t_ok((select reached from gf_trails_reached_by(:'vb3') where trail_id = :'tr1') = 1,
  '次の地点で扉を開けると 1 つ進み、その入場で進んだことが分かる');
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g3', :'c', 35.81, 139.72, 5, :same, 2) ->> 'visit_id' as vx2 \gset
select t_ok((select completed from gf_trail_list() where id = :'tr1'), '最後の地点まで行くと歩き終わる');
select t_ok((select count(*) from gf_trail_stops_of(:'tr1') where reached) = 2, '地点ごとに着いた印が付く');
select t_throws(format('select gf_delete_trail(%L)', :'tr1'), 'gf_not_found', '他人の TRAIL は消せない');
:as_alice
select gf_delete_trail(:'tr2');
select t_ok(not exists (select 1 from gf_trail_list() where id = :'tr2'), '自分の TRAIL は消せる');

\echo '== 今と昔'
:as_bob
select gf_add_snapshot(:'vb3', :'bob' || '/snap.jpg', 'friends') as s1 \gset
select t_ok(:'s1' is not null, '入場中は、いまの景色を残せる');
select t_throws(format('select gf_add_snapshot(%L, %L, null)', :'vb3', :'bob' || '/snap.jpg'), 'gf_already_posted',
  '1 回の入場で 1 枚だけ');
select t_throws(format('select gf_add_snapshot(%L, %L, null)', :'vb3', :'alice' || '/snap.jpg'), 'gf_bad_media_path',
  '他人のフォルダの写真は使えない');
:as_alice
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g4', :'c', 35.82, 139.72, 5, :same, 2) ->> 'visit_id' as va4 \gset
select gf_add_snapshot(:'va4', :'alice' || '/snap.jpg', 'public') as s2 \gset
select t_ok((select count(*) from gf_snapshots where gate_id = :'g4') = 2, '友達の写真と公開の写真が、入場中に見える');
:as_carol
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g4', :'c', 35.82, 139.72, 5, :same, 2) ->> 'visit_id' as vc2 \gset
select t_ok((select count(*) from gf_snapshots where gate_id = :'g4') = 1, '友達でない人には、公開の写真だけ見える');
select t_ok((select count(*) from storage.objects where name = :'alice' || '/snap.jpg') = 1, '見える写真は受け取れる');
select t_ok((select count(*) from storage.objects where name = :'bob' || '/snap.jpg') = 0, '見えない写真は受け取れない');
select gf_report('snapshot', :'s2', 'privacy', null);
:as_dave
select t_ok((select count(*) from gf_snapshots) = 0, '入場していない人には見えない');
:as_bob
select t_ok(gf_delete_snapshot(:'s1') = :'bob' || '/snap.jpg', '自分の写真は消せて、ファイルの名前が返る');
:as_admin
select t_ok(exists (select 1 from gf_reports where target_kind = 'snapshot' and target_user = :'alice'), '今と昔の写真も通報できる');
reset role;
\echo '== TRAIL と今と昔：すべて通りました'
