-- AR の作品の「映像パネル」と「声の玉」（0010）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'
\set play '''[{"trigger":"touch","action":"play","cooldown_ms":1200},{"trigger":"approach","action":"play","cooldown_ms":10000}]'''

\echo '== AR の作品の映像と声'
:as_admin
delete from gf_rate;
select id as g4 from gf_gates where client_key = 'alice-gate-0101' \gset
select id as va from gf_visits where user_id = :'alice' and gate_id = :'g4' and expires_at > now() order by expires_at desc limit 1 \gset
insert into storage.objects (bucket_id, name) values
  ('gf-media', :'alice' || '/art.mp4'), ('gf-media', :'alice' || '/art.jpg'), ('gf-media', :'alice' || '/art.m4a');

:as_alice
select gf_place_artwork2(:'va', 'video', '', :'alice' || '/art.mp4', :'alice' || '/art.jpg', 9.5, 'warm',
  0.4, 1.3, 0.6, 0, 1, :play::jsonb, 'friends') as av \gset
select t_ok(:'av' is not null, '15 秒までの映像パネルを、表紙の絵つきで置ける');
select t_throws(format('select gf_place_artwork2(%L, %L, %L, %L, null, 9, null, 0, 1, 0, 0, 1, null, null)',
  :'va', 'video', '', :'alice' || '/art.mp4'), 'gf_bad_artwork', '表紙の絵のない映像パネルは置けない');
select t_throws(format('select gf_place_artwork2(%L, %L, %L, %L, %L, 20, null, 0, 1, 0, 0, 1, null, null)',
  :'va', 'video', '', :'alice' || '/art.mp4', :'alice' || '/art.jpg'), 'gf_bad_artwork', '15 秒より長い映像は置けない');
select t_throws(format('select gf_place_artwork2(%L, %L, %L, %L, %L, 9, null, 0, 1, 0, 0, 1, null, null)',
  :'va', 'video', '', :'alice' || '/art.mp4', :'bob' || '/x.jpg'), 'gf_bad_media_path', '他人のフォルダの表紙の絵は使えない');
select t_throws(format('select gf_place_artwork2(%L, %L, %L, %L, %L, 30, null, 0, 1, 0, 0, 1, null, null)',
  :'va', 'voice', '', :'alice' || '/art.m4a', :'alice' || '/art.jpg'), 'gf_bad_artwork', '声の玉に表紙の絵は付けない');
select t_throws(format('select gf_place_artwork2(%L, %L, %L, null, null, 5, null, 0, 1, 0, 0, 1, null, null)',
  :'va', 'light', ''), 'gf_bad_artwork', '光の玉に長さは付けない');
select t_throws(format('select gf_place_artwork2(%L, %L, %L, null, null, null, null, 0, 1, 0, 0, 1, %L::jsonb, null)',
  :'va', 'light', '', '[{"trigger":"touch","action":"play"}]'), 'gf_bad_rules', '「流す」は映像・声のほかには付けられない');
select t_throws(format('select gf_place_artwork2(%L, %L, %L, %L, null, 70, null, 0, 1, 0, 0, 1, null, null)',
  :'va', 'voice', '', :'alice' || '/art.m4a'), 'gf_bad_artwork', '60 秒より長い声は置けない');
select gf_place_artwork2(:'va', 'voice', '', :'alice' || '/art.m4a', null, 42, 'sky',
  -0.5, 1.1, 0.5, 0, 1, :play::jsonb, 'friends') as aw \gset
select t_ok(:'aw' is not null, '60 秒までの声の玉を置ける');
select t_ok((select thumb_path = :'alice' || '/art.jpg' and abs(duration - 9.5) < 0.01 from gf_artworks where id = :'av'),
  '映像パネルの表紙の絵と長さが残る');
select gf_place_artwork(:'va', 'light', '', null, 'mint', 0, 1.6, 0.9, 0, 1, '[]'::jsonb, 'friends') as al \gset
select t_ok(:'al' is not null, '前の形の「作品を置く」も、これまでどおり使える');

:as_bob
select t_ok((select count(*) from storage.objects where name in (:'alice' || '/art.mp4', :'alice' || '/art.jpg', :'alice' || '/art.m4a')) = 3,
  '友達で入場中なら、映像・表紙の絵・声を受け取れる');
:as_carol
select t_ok((select count(*) from storage.objects where name in (:'alice' || '/art.jpg', :'alice' || '/art.m4a')) = 0,
  '友達向けの作品の表紙の絵・声は、友達でなければ受け取れない');
select t_throws(format('select gf_delete_artwork2(%L)', :'av'), 'gf_not_found', 'ほかの人の作品は消せない');
:as_alice
select t_ok((select gf_delete_artwork2(:'av')) = array[:'alice' || '/art.mp4', :'alice' || '/art.jpg'],
  '映像パネルを消すと、映像と表紙の絵の両方の名前が返る（ファイルも消すため）');
-- 声の玉は残す（データが入ったあとに setup_all.sql を貼り直しても大丈夫かを、新しい種類でも確かめる）
select gf_delete_artwork(:'al');
reset role;
\echo '== AR の作品の映像と声：すべて通りました'
