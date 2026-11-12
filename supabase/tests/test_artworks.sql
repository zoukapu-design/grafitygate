-- AR の作品（0003）のテスト。前のテストのあとの状態（人・デイブの公開の GATE）を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set dave  '00000000-0000-0000-0000-00000000000d'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_dave  'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000d'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'
\set same 'array_fill(0.25::real, array[16])'
\set rules '''[{"trigger":"touch","action":"burst","cooldown_ms":1500},{"trigger":"approach","action":"glow"}]''::jsonb'

\echo '== AR の作品'
:as_admin
select id as g3 from gf_gates where client_key = 'dave-gate-00001' \gset
insert into storage.objects (bucket_id, name) values ('gf-media', :'dave' || '/art.jpg');

:as_dave
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g3', :'c', 35.81, 139.72, 5, :same, 2) ->> 'visit_id' as vd \gset
select gf_place_artwork(:'vd', 'text', 'また会おう', null, 'warm', 0.5, 1.4, 0.3, 0.2, 1, :rules, 'friends') as a1 \gset
select t_ok(:'a1' is not null, '入場中は光る文字を置ける');
select gf_place_artwork(:'vd', 'photo', '', :'dave' || '/art.jpg', 'white', -0.6, 1.2, 0.4, 0, 1, '[]'::jsonb, 'public') as a2 \gset
select t_ok(:'a2' is not null, '入場中は写真パネルを置ける');
select t_throws(format('select gf_place_artwork(%L, %L, %L, null, null, 0, 1, 0, 0, 1, %L::jsonb, null)', :'vd', 'light', '',
  '[{"trigger":"touch","action":"run_script"}]'), 'gf_bad_rules', '決まっていない動きのルールは断る（プログラムは置けない）');
select t_throws(format('select gf_place_artwork(%L, %L, %L, null, null, 0, 1, 0, 0, 1, %L::jsonb, null)', :'vd', 'light', '',
  '[{"trigger":"touch","action":"glow","url":"https://example.com"}]'), 'gf_bad_rules', 'ルールに余計な項目があれば断る');
select t_throws(format('select gf_place_artwork(%L, %L, %L, null, null, 10, 1, 0, 0, 1, null, null)', :'vd', 'light', ''),
  'gf_bad_artwork', '扉から 4m より遠くには置けない');
select t_throws(format('select gf_place_artwork(%L, %L, %L, null, null, 0, 1, 0, 0, 1, null, null)', :'vd', 'photo', ''),
  'gf_bad_artwork', '写真のない写真パネルは置けない');
select t_throws(format('select gf_place_artwork(%L, %L, %L, null, null, 0, 1, 0, 0, 1, null, null)', :'vd', 'text', '  '),
  'gf_bad_artwork', '文字のない光る文字は置けない');
select t_throws(format('select gf_place_artwork(%L, %L, %L, %L, null, 0, 1, 0, 0, 1, null, null)', :'vd', 'photo', '', :'bob' || '/x.jpg'),
  'gf_bad_media_path', '他人のフォルダの写真は使えない');
select gf_place_artwork(:'vd', 'petals', '', null, 'sakura', 0, 1.0, 0.8, 0, 1,
  '[{"trigger":"touch","action":"chime","cooldown_ms":800}]'::jsonb, 'public') as a3 \gset
select t_ok(:'a3' is not null, '「鳴る」の動きも置ける');
select t_throws(format('select gf_place_artwork(%L, %L, %L, null, null, 0, 1, 0, 0, 1, null, null)', :'vd', 'light', ''),
  'gf_artwork_limit', '1 人が 1 つの GATE に置けるのは 3 つまで');
select t_throws(format('insert into gf_artworks (gate_id, owner, kind, px, py, pz) values (%L, %L, %L, 0, 1, 0)', :'g3', :'dave', 'light'),
  'row-level security', '作品の表に直接は書き込めない');

\echo '== 作品を見る'
:as_bob
select t_ok((select count(*) from gf_artworks) = 0, '入場していない人には作品を見せない');
:as_carol
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g3', :'c', 35.81, 139.72, 5, :same, 2) ->> 'visit_id' as vc \gset
select t_ok((select count(*) from gf_artworks where gate_id = :'g3') = 2, '入場中の人には、公開範囲が合う作品だけ見える（友達向けは見えない）');
select t_ok((select count(*) from storage.objects where name = :'dave' || '/art.jpg') = 1, '見える写真パネルの写真は受け取れる');
select t_throws(format('select gf_move_artwork(%L, %L, 0, 1, 0, 0, 1, 1)', :'a2', :'vc'), 'gf_not_found', '他人の作品は動かせない');

\echo '== 置き直す・隠す・消す'
:as_dave
select t_throws(format('select gf_move_artwork(%L, %L, 0.1, 1.2, 0.4, 0, 1, 5)', :'a2', :'vd'), 'gf_revision_conflict',
  'ほかの端末で先に動かしていたら（版が違えば）断る');
select t_ok(gf_move_artwork(:'a2', :'vd', 0.1, 1.2, 0.4, 0, 1.2, 1) = 2, '版が合えば置き直せて、版が 1 つ進む');
select gf_set_artwork_status(:'a2', 'hidden');
:as_carol
select t_ok((select count(*) from gf_artworks where id = :'a2') = 0, '隠した作品はほかの人に見えない');
select t_ok((select count(*) from storage.objects where name = :'dave' || '/art.jpg') = 0, '隠した作品の写真は受け取れない');
:as_dave
select t_ok((select count(*) from gf_artworks where id = :'a2') = 1, '隠しても本人には見える');
select gf_delete_artwork(:'a1');
select t_ok((select count(*) from gf_artworks where id = :'a1') = 0, '消した作品は本人にも見えない');
:as_admin
update gf_visits set expires_at = now() - interval '1 second' where id = :'vd';
:as_dave
select t_throws(format('select gf_place_artwork(%L, %L, %L, null, null, 0, 1, 0, 0, 1, null, null)', :'vd', 'light', ''),
  'gf_visit_invalid', '入場券が切れたら置けない');
select t_throws(format('select gf_move_artwork(%L, %L, 0, 1, 0, 0, 1, 2)', :'a2', :'vd'), 'gf_visit_invalid',
  '入場券が切れたら置き直せない');
reset role;
\echo '== AR の作品：すべて通りました'
