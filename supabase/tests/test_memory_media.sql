-- 思い出の動画と声（0009）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'

\echo '== 思い出の動画と声'
:as_admin
delete from gf_rate;
select id as g4 from gf_gates where client_key = 'alice-gate-0101' \gset
select id as va from gf_visits where user_id = :'alice' and gate_id = :'g4' and expires_at > now() order by expires_at desc limit 1 \gset
insert into storage.objects (bucket_id, name) values
  ('gf-media', :'alice' || '/v.mp4'), ('gf-media', :'alice' || '/v.jpg'), ('gf-media', :'alice' || '/voice.m4a');
select t_ok((select 'video/mp4' = any(allowed_mime_types) and 'audio/mp4' = any(allowed_mime_types)
             from storage.buckets where id = 'gf-media'), '写真の置き場所に、動画と声のファイルも置ける');

:as_alice
select gf_create_memory(:'va', '夏の川', '', 'friends') as m2 \gset
select gf_add_memory_media(:'m2', 'video', :'alice' || '/v.mp4', :'alice' || '/v.jpg', 12, '水の音') as i1 \gset
select t_ok(:'i1' is not null, '15 秒までの動画を、表紙の絵つきで足せる');
select t_throws(format('select gf_add_memory_media(%L, %L, %L, null, 12, null)', :'m2', 'video', :'alice' || '/v.mp4'),
  'gf_bad_media', '表紙の絵のない動画は足せない');
select t_throws(format('select gf_add_memory_media(%L, %L, %L, %L, 30, null)', :'m2', 'video', :'alice' || '/v.mp4', :'alice' || '/v.jpg'),
  'gf_bad_media', '15 秒より長い動画は足せない');
select gf_add_memory_media(:'m2', 'voice', :'alice' || '/voice.m4a', null, 45, '') as i2 \gset
select t_ok(:'i2' is not null, '60 秒までの声を足せる');
select t_throws(format('select gf_add_memory_media(%L, %L, %L, null, 90, null)', :'m2', 'voice', :'alice' || '/voice.m4a'),
  'gf_bad_media', '60 秒より長い声は足せない');
select t_throws(format('select gf_add_memory_media(%L, %L, %L, %L, 5, null)', :'m2', 'video', :'alice' || '/v.mp4', :'bob' || '/x.jpg'),
  'gf_bad_media_path', '他人のフォルダの表紙の絵は使えない');
select t_throws(format('select gf_add_memory_media(%L, %L, %L, null, null, null)', :'m2', 'song', :'alice' || '/v.mp4'),
  'gf_bad_media', '決まっていない種類は足せない');
select t_ok((select cover_path from gf_memory_list(:'g4') where id = :'m2') = :'alice' || '/v.jpg',
  '動画がいちばん古いときは、その表紙の絵が思い出の表紙になる');

:as_bob
select t_ok((select count(*) from storage.objects where name in (:'alice' || '/v.jpg', :'alice' || '/v.mp4', :'alice' || '/voice.m4a')) = 3,
  '友達で入場中なら、動画・表紙の絵・声を受け取れる');
:as_carol
select t_ok((select count(*) from storage.objects where name = :'alice' || '/v.jpg') = 0,
  '友達向けの思い出の表紙の絵は、友達でなければ受け取れない');
:as_alice
select t_ok((select gf_delete_memory_media(:'i1')) = array[:'alice' || '/v.mp4', :'alice' || '/v.jpg'],
  '動画を消すと、動画と表紙の絵の両方の名前が返る（ファイルも消すため）');
reset role;
\echo '== 思い出の動画と声：すべて通りました'
