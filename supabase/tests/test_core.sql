-- gf_ のルールの確認テスト（v0.7 の主なテストを SQL に移したもの）。run.sh から実行する。
-- 失敗すると "FAIL: ..." で止まる。通ったものは "ok - ..." と出る。
\set ON_ERROR_STOP on

-- ---------- テストの道具 ----------
create or replace function t_ok(cond boolean, name text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', name; end if;
  raise notice 'ok - %', name;
end $$;
create or replace function t_throws(stmt text, expected text, name text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    if sqlerrm like '%' || expected || '%' then raise notice 'ok - %', name; return; end if;
    raise exception 'FAIL: % (別のエラー: %)', name, sqlerrm;
  end;
  raise exception 'FAIL: % (エラーにならなかった)', name;
end $$;
grant execute on function t_ok(boolean, text) to authenticated, anon;
grant execute on function t_throws(text, text, text) to authenticated, anon;

-- ---------- 人 ----------
\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set dave  '00000000-0000-0000-0000-00000000000d'
insert into auth.users values (:'alice'), (:'bob'), (:'carol'), (:'dave');
insert into profiles (id, display_name, handle) values
  (:'alice', 'アリス', 'alice'), (:'bob', 'ボブ', 'bob'), (:'carol', 'キャロル', 'carol'), (:'dave', 'デイブ', 'dave');
-- アリスとボブは友達（お互いにフォロー）。キャロルはアリスとボブを片方だけフォロー。デイブは知らない人。
insert into follows values (:'alice', :'bob'), (:'bob', :'alice'), (:'carol', :'alice'), (:'carol', :'bob');

\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_dave  'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000d'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'

-- GATE の場所と、北へ 50m・110m・130m の位置（緯度 1m ≒ 0.0000090 度）
\set glat 35.80000
\set glon 139.72000
\set lat50  35.80045
\set lat110 35.80099
\set lat130 35.80117
-- 写真の特徴：参照（same）・同じ物を別の時に撮った（near）・別の物（far）
\set same 'array_fill(0.25::real, array[16])'
\set near 'array_fill(0.27::real, array[16])'
\set far  'array[1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]::real[]'

-- =========================================================
\echo '== GATE を作る'
:as_alice
select challenge_id as c from gf_request_challenge() \gset
select gf_create_gate('alice-gate-0001', :'c', '駅前の街灯', '待ち合わせた場所', 'object',
  :glat, :glon, 8, 90, 'friends', :'alice' || '/cover1.jpg',
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2, 'photo_path', :'alice' || '/ref1.jpg'))) as g1 \gset
select t_ok(:'g1' is not null, '友達向けの GATE を作れる');
select t_ok(gf_create_gate('alice-gate-0001', :'c', '駅前の街灯', '', 'object', :glat, :glon, 8, 90, 'friends', null,
  '[]'::jsonb) = :'g1', '同じ client_key で送り直すと、同じ GATE が返る（2 つできない）');
select t_ok((select count(*) from gf_gates where owner = :'alice') = 1, '作った GATE は 1 つだけ');
select t_throws(format('select gf_create_gate(%L, %L, %L, %L, %L, 35.8, 139.72, 8, null, %L, null, %L::jsonb)',
  'alice-gate-0002', :'c', '二つ目', '', 'place', 'public',
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))), 'gf_challenge_used',
  '使った合言葉では作れない');
select challenge_id as c from gf_request_challenge() \gset
select t_throws(format('select gf_create_gate(%L, %L, %L, %L, %L, 35.8, 139.72, 50, null, %L, null, %L::jsonb)',
  'alice-gate-0003', :'c', '精度が悪い', '', 'place', 'public',
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))), 'gf_inaccurate',
  '位置の精度が 35m より悪いと作れない');
select challenge_id as c from gf_request_challenge() \gset
select t_throws(format('select gf_create_gate(%L, %L, %L, %L, %L, 35.8, 139.72, 8, null, %L, %L, %L::jsonb)',
  'alice-gate-0004', :'c', '他人の写真', '', 'place', 'public', :'bob' || '/x.jpg',
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))), 'gf_bad_media_path',
  '他人のフォルダの写真は表紙にできない');
select challenge_id as c from gf_request_challenge() \gset
select t_throws(format('select gf_create_gate(%L, %L, %L, %L, %L, 35.8, 139.72, 8, null, %L, null, %L::jsonb)',
  'alice-gate-0005', :'c', '参照なし', '', 'place', 'public', '[]'), 'gf_bad_references',
  '参照写真の特徴がないと作れない');
-- 公開の GATE（デイブも見つけられる）を少し離れた所に
select challenge_id as c from gf_request_challenge() \gset
select gf_create_gate('alice-gate-0006', :'c', '公園のベンチ', '', 'object', 35.80300, 139.72000, 6, null, 'public', null,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))) as g2 \gset
select t_ok(:'g2' is not null, '公開の GATE を作れる');

-- =========================================================
\echo '== 正確な位置と参照写真の特徴は、表から直接は読めない'
select t_ok((select count(*) from gf_gates) = 2, '自分の GATE は表から読める');
select t_ok((select count(*) from gf_gate_refs) = 0, '参照写真の特徴は、作った本人にも表から返さない');
:as_bob
select t_ok((select count(*) from gf_gates) = 0, '他人の GATE は表から直接読めない（正確な位置を守る）');
select t_ok((select count(*) from gf_challenges) = 0 and (select count(*) from gf_visits) = 0,
  '合言葉・入場券の表は直接読めない');

-- =========================================================
\echo '== 見つける（100m）'
select t_ok(exists (select 1 from gf_discover_nearby(:lat50, :glon) where id = :'g1'), '友達は 50m で見つけられる');
select t_ok(not exists (select 1 from gf_discover_nearby(:lat110, :glon) where id = :'g1'), '110m では見つからない（発見は 100m まで）');
select t_ok((select approx_lat from gf_discover_nearby(:lat50, :glon) where id = :'g1') = round(:glat::numeric, 4)::double precision,
  '見つけたときの位置は丸めてある');
select t_ok((select title from gf_gate_summary(:'g1')) = '駅前の街灯', '友達は概要を見られる');
select t_ok((select graffiti_count from gf_gate_summary(:'g1')) = 0, '概要には記録の数だけ出る');
:as_carol
select t_ok(not exists (select 1 from gf_discover_nearby(:lat50, :glon) where id = :'g1'),
  '片方だけフォローの人は、友達向けの GATE を見つけられない');
select t_ok(not exists (select 1 from gf_gate_summary(:'g1')), '片方だけフォローの人は概要も見られない');
:as_dave
select t_ok(not exists (select 1 from gf_discover_nearby(:lat50, :glon) where id = :'g1'), '知らない人は友達向けの GATE を見つけられない');
select t_ok(exists (select 1 from gf_discover_nearby(35.80300, 139.72000) where id = :'g2'), '公開の GATE はだれでも見つけられる');
select t_throws('select * from gf_discover_nearby(91, 139.72)', 'gf_bad_position', 'ありえない位置は断る');
select t_throws('select * from gf_discover(35.8, 139.72)', 'permission denied', '中だけで使う関数は直接呼べない');

-- =========================================================
\echo '== 入る（120m・精度・写真の一致・合言葉）'
:as_bob
select challenge_id as c from gf_request_challenge() \gset
select t_ok((gf_enter(:'g1', :'c', :lat130, :glon, 10, :near, 2) ->> 'reason') = 'too_far', '130m では入れない（GPS の距離）');
select challenge_id as c from gf_request_challenge() \gset
select t_ok((gf_enter(:'g1', :'c', :lat50, :glon, 40, :near, 2) ->> 'reason') = 'inaccurate', '精度 40m では入れない');
select challenge_id as c from gf_request_challenge() \gset
select t_ok((gf_enter(:'g1', :'c', :lat50, :glon, 10, :far, 2) ->> 'reason') = 'no_match', '近くても写真が別の物なら入れない（GPS だけでは入れない）');
select challenge_id as c from gf_request_challenge() \gset
select t_ok((gf_enter(:'g1', :'c', :lat50, :glon, 10, :near, 1) ->> 'reason') = 'no_reference', '特徴の版が違うと比べられない');
select challenge_id as c from gf_request_challenge() \gset
select t_ok((gf_enter(:'g1', :'c', 35.90000, :glon, 10, :same, 2) ->> 'reason') = 'too_far', '写真がぴったりでも遠ければ入れない（写真だけでは入れない）');
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g1', :'c', :lat110, :glon, 10, :near, 2) ->> 'visit_id' as v1 \gset
select t_ok(:'v1' is not null, '110m・精度 10m・写真が合えば入れる');
select t_ok((gf_enter(:'g1', :'c', :lat110, :glon, 10, :near, 2) ->> 'reason') = 'challenge_used', '同じ合言葉は 2 回使えない');
select t_ok((select my_visit from gf_gate_summary(:'g1')) = :'v1', '概要に自分の入場券が出る');
:as_alice
select challenge_id as alice_c from gf_request_challenge() \gset
:as_bob
select t_ok((gf_enter(:'g1', :'alice_c', :lat50, :glon, 10, :near, 2) ->> 'reason') = 'challenge_invalid', '他人の合言葉は使えない');
select challenge_id as c from gf_request_challenge() \gset
:as_admin
update gf_challenges set expires_at = now() - interval '1 second' where id = :'c';
:as_bob
select t_ok((gf_enter(:'g1', :'c', :lat50, :glon, 10, :near, 2) ->> 'reason') = 'challenge_expired', '期限の切れた合言葉は使えない');
:as_carol
select challenge_id as c from gf_request_challenge() \gset
select t_ok((gf_enter(:'g1', :'c', :lat50, :glon, 10, :same, 2) ->> 'reason') = 'not_found', '見てはいけない GATE は「ない」と返す');
:as_admin
select t_ok((select count(*) from gf_enter_attempts) >= 10, '入場の試みは、合わなかったものも記録に残る');
select t_ok((select count(*) from gf_enter_attempts where result = 'no_match' and match_distance > 0.75) = 1,
  '記録には写真の特徴の距離が残る（しきい値を決め直すため）');

-- =========================================================
\echo '== グラフィティ（1 回の入場で 1 枚・12 時間）'
:as_bob
select gf_post_graffiti(:'v1', 'また来たよ', :'bob' || '/g1.jpg', 'friends', false) as p1 \gset
select t_ok(:'p1' is not null, '入場中は書ける');
select t_throws(format('select gf_post_graffiti(%L, %L, null, null, false)', :'v1', '二枚目'), 'gf_already_posted',
  '同じ入場で 2 枚目は書けない');
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g1', :'c', :lat50, :glon, 10, :near, 2) ->> 'visit_id' as v2 \gset
select t_throws(format('select gf_post_graffiti(%L, %L, null, null, false)', :'v2', '入り直し'), 'gf_repost_cooldown',
  '入り直しても 12 時間たつまで同じ GATE には書けない');
:as_admin
update gf_graffiti set created_at = now() - interval '11 hours' where id = :'p1';
:as_bob
select t_throws(format('select gf_post_graffiti(%L, %L, null, null, false)', :'v2', '11 時間後'), 'gf_repost_cooldown',
  '11 時間ではまだ書けない');
:as_admin
update gf_graffiti set created_at = now() - interval '13 hours' where id = :'p1';
:as_bob
select gf_post_graffiti(:'v2', '13 時間後', null, 'friends', true) as p2 \gset
select t_ok(:'p2' is not null, '12 時間たてば書ける（この 1 枚は「現地だけ」）');
select t_throws(format('select gf_post_graffiti(%L, %L, %L, null, false)', :'v2', 'x', :'alice' || '/a.jpg'), 'gf_already_posted',
  '入場券 1 枚につき 1 枚（もう書いた入場券では書けない）');
:as_dave
select t_throws(format('select gf_post_graffiti(%L, %L, null, null, false)', :'v2', 'なりすまし'), 'gf_visit_invalid',
  '他人の入場券では書けない');
:as_admin
update gf_visits set expires_at = now() - interval '1 second' where id = :'v2';
:as_bob
select t_throws(format('select gf_post_graffiti(%L, %L, null, null, false)', :'v2', '期限切れ'), 'gf_visit_invalid',
  '期限の切れた入場券では書けない');

-- =========================================================
\echo '== 現地でしか見られない'
:as_alice
select t_ok((select count(*) from gf_graffiti where gate_id = :'g1') = 0, 'GATE の持ち主でも、入場券がなければ中のグラフィティは読めない');
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g1', :'c', :glat, :glon, 5, :same, 2) ->> 'visit_id' as va \gset
select t_ok((select count(*) from gf_graffiti where gate_id = :'g1') = 2, '入場すると、友達のグラフィティが読める（現地だけのものも）');
:as_bob
select t_ok((select count(*) from gf_graffiti where author = :'bob') = 2, '書いた本人は、いつでも自分のグラフィティを読める');
:as_dave
select t_ok((select count(*) from gf_graffiti) = 0, '知らない人は ID を知っていても読めない');
select t_throws(format('insert into gf_graffiti (gate_id, author, body) values (%L, %L, %L)', :'g1', :'dave', '直接'),
  'row-level security', '表に直接は書き込めない（関数を通すだけ）');
update gf_gates set lat = 0 where id = :'g2';
:as_admin
select t_ok((select lat from gf_gates where id = :'g2') = 35.80300, '他人の GATE の位置は書き換えられない');
:as_dave

-- =========================================================
\echo '== 友達の新着（24 時間）'
:as_alice
select t_ok((select count(*) from gf_friend_feed()) = 1, '友達の新着に出るのは、現地だけでないカードだけ');
select t_ok((select gate_title from gf_friend_feed() limit 1) = '駅前の街灯', '新着には GATE の名前が付く');
select t_ok((select approx_lat from gf_friend_feed() limit 1) = round(:glat::numeric, 3)::double precision, '新着の位置は 100m ほどに丸める');
:as_carol
select t_ok((select count(*) from gf_friend_feed()) = 0, '片方だけフォローの人の新着には、友達向けのカードは出ない');
:as_admin
update gf_graffiti set created_at = now() - interval '25 hours' where id = :'p1';
:as_alice
select t_ok((select count(*) from gf_friend_feed()) = 0, '24 時間たつと新着から消える');
select t_ok((select count(*) from gf_graffiti where id = :'p1') = 1, '新着から消えても、GATE の記録としては残る');

-- =========================================================
\echo '== 写真の置き場所'
:as_admin
insert into storage.objects (bucket_id, name) values
  ('gf-media', :'alice' || '/ref1.jpg'), ('gf-media', :'alice' || '/cover1.jpg'), ('gf-media', :'bob' || '/g1.jpg');
:as_bob
select t_ok((select count(*) from storage.objects where name = :'alice' || '/ref1.jpg') = 0, '参照写真は持ち主しか見られない');
select t_ok((select count(*) from storage.objects where name = :'alice' || '/cover1.jpg') = 1, '見てよい GATE の表紙は見られる');
:as_dave
select t_ok((select count(*) from storage.objects where bucket_id = 'gf-media') = 0, '知らない人はどの写真も見られない');
select t_throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'gf-media', :'alice' || '/evil.jpg'),
  'row-level security', '他人のフォルダには置けない');
:as_alice
select t_ok((select count(*) from storage.objects where name = :'bob' || '/g1.jpg') = 1, '入場中は、グラフィティの写真を見られる');
:as_admin
update gf_visits set expires_at = now() - interval '1 second' where id = :'va';
:as_alice
select t_ok((select count(*) from storage.objects where name = :'bob' || '/g1.jpg') = 0,
  '入場券が切れ、新着からも消えたら、写真も見られない');

-- =========================================================
\echo '== 反応'
:as_alice
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g1', :'c', :glat, :glon, 5, :same, 2) ->> 'visit_id' as va \gset
insert into gf_reactions (graffiti_id, user_id) values (:'p1', :'alice');
select t_ok((select count(*) from gf_reactions where graffiti_id = :'p1') = 1, '見えるグラフィティには反応できる');
:as_dave
select t_throws(format('insert into gf_reactions (graffiti_id, user_id) values (%L, %L)', :'p1', :'dave'),
  'row-level security', '見えないグラフィティには反応できない');
select t_ok((select count(*) from gf_reactions) = 0, '見えないグラフィティの反応は読めない');

-- =========================================================
\echo '== ブロック・公開範囲の変更はすぐ効く'
:as_admin
insert into lp_blocks values (:'alice', :'bob');
:as_bob
select t_ok(not exists (select 1 from gf_discover_nearby(:lat50, :glon) where id = :'g1'), 'ブロックされると見つけられない');
select challenge_id as c from gf_request_challenge() \gset
select t_ok((gf_enter(:'g1', :'c', :lat50, :glon, 10, :near, 2) ->> 'reason') = 'not_found', 'ブロックされると入れない');
:as_alice
select t_ok((select count(*) from gf_graffiti where author = :'bob') = 0, 'ブロックした人のグラフィティは、入場中でも見えない');
:as_admin
delete from lp_blocks;
:as_bob
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g1', :'c', :lat50, :glon, 10, :near, 2) ->> 'visit_id' as v3 \gset
:as_alice
select gf_update_gate(:'g1', null, null, 'private', null);
:as_bob
select t_ok(not exists (select 1 from gf_discover_nearby(:lat50, :glon) where id = :'g1'), '自分だけに変えた GATE は見つからない');
select t_ok((select count(*) from gf_graffiti where gate_id = :'g1' and author <> :'bob') = 0, '自分だけに変えた GATE の中は、入場券があっても読めない');
:as_admin
update gf_graffiti set created_at = now() - interval '13 hours' where author = :'bob';
:as_bob
select t_throws(format('select gf_post_graffiti(%L, %L, null, null, false)', :'v3', '非公開後'), 'gf_visit_invalid',
  '自分だけに変えた GATE には、前の入場券でも書けない');
select t_throws(format('select gf_update_gate(%L, %L, null, null, null)', :'g1', '乗っ取り'), 'gf_not_found',
  '他人の GATE は変えられない');
select t_throws(format('select gf_delete_graffiti(%L)', gen_random_uuid()), 'gf_not_found', 'ないグラフィティは消せない');
select gf_delete_graffiti(:'p2');
select t_ok((select count(*) from gf_graffiti where id = :'p2') = 0, '消したグラフィティは本人にも見えなくなる');

-- =========================================================
\echo '== 回数の上限・ログインしていない人'
:as_admin
update gf_settings set value = 1 where key = 'gates_per_day';
:as_dave
select challenge_id as c from gf_request_challenge() \gset
select gf_create_gate('dave-gate-00001', :'c', 'ポスト', '', 'object', 35.81, 139.72, 5, null, 'public', null,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))) as g3 \gset
select challenge_id as c from gf_request_challenge() \gset
select t_throws(format('select gf_create_gate(%L, %L, %L, %L, %L, 35.81, 139.72, 5, null, %L, null, %L::jsonb)',
  'dave-gate-00002', :'c', '二つ目', '', 'place', 'public',
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))), 'gf_rate_limited',
  '1 日に作れる数を超えると作れない');
:as_admin
update gf_settings set value = 20 where key = 'gates_per_day';
reset role;
do $$ begin perform set_config('request.jwt.claim.sub', '', false); end $$;
set role authenticated;
select t_throws('select * from gf_request_challenge()', 'gf_not_signed_in', 'ログインしていないと合言葉はもらえない');
reset role;
set role anon;
select t_throws('select * from gf_request_challenge()', 'permission denied', 'ログイン前の役割では呼べない');
reset role;

\echo '== すべて通りました'
