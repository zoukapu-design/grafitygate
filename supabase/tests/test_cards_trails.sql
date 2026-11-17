-- カードのお気に入り・返信、掲示板の「解決しました」、名前で探す、友達の TRAIL、訪問の記録、お知らせの設定（0018）のテスト。
-- 前のテスト（test_friend_cards）のあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'
\set vlat50 35.83045
\set vlon 139.75000
\set day 'array_fill(0.25::real, array[16])'
\set leave_gate 'update gf_visits set expires_at = now() - interval ''1 minute'' where gate_id = '

\echo '== 準備：アリスの景色の GATE と、アリスのカード（図鑑からは外しておく）'
:as_admin
delete from gf_rate;
select id as vg, title as vg_title from gf_gates where client_key = 'view-gate-0001' \gset
select id as ca from gf_graffiti where author = :'alice' and gate_id = :'vg' and deleted_at is null
  order by created_at desc limit 1 \gset
update gf_graffiti set in_atlas = false, local_only = false where id = :'ca';
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'vg';

\echo '== カードのお気に入り'
:as_bob
select t_throws(format('select gf_save_card(%L, true)', :'ca'), 'gf_not_found', 'GATE の外からはお気に入りにできない');
select challenge_id as c from gf_request_challenge() \gset
select (gf_enter(:'vg', :'c', :vlat50, :vlon, 10, :day, 2) ->> 'visit_id') as vb \gset
select t_ok(gf_save_card(:'ca', true), 'GATE の中ならお気に入りにできる');
select t_ok(gf_save_card(:'ca', true), '2 回押しても 1 つ');
select t_ok((select saved from gf_card_extras(:'vg') where graffiti_id = :'ca'), '中の一覧で、お気に入りかが分かる');
:as_admin
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'vg';
:as_bob
select t_ok((select count(*) from gf_my_saved_cards()
             where id = :'ca' and photo_path = :'alice' || '/view-a.jpg' and body is not null and gate_title = :'vg_title') = 1,
  '遠くからも、お気に入りの写真・GATE・日付が見え、一度扉を開けた GATE なのでひとことも読める');
select t_ok(gf_can_read_media(:'alice' || '/view-a.jpg'), 'お気に入りにしたカードの写真は、遠くから受け取れる');
:as_admin
update gf_graffiti set local_only = true where id = :'ca';
:as_bob
select t_ok((select photo_path is null from gf_my_saved_cards() where id = :'ca'),
  '「現地だけ」にしたカードの写真は、お気に入りでも遠くからは出ない');
select t_ok(not gf_can_read_media(:'alice' || '/view-a.jpg'), '「現地だけ」のカードの写真は受け取れない');
:as_admin
update gf_graffiti set local_only = false where id = :'ca';
:as_carol
select t_ok(not gf_can_read_media(:'alice' || '/view-a.jpg'), 'お気に入りにしていない人は受け取れない');
select t_ok((select count(*) from gf_my_saved_cards()) = 0, 'ほかの人のお気に入りは見えない');
:as_alice
select t_ok((select count(*) from gf_my_saved_cards() where id = :'ca') = 0, 'お気に入りは、した本人だけのもの');
:as_bob
select t_ok(not gf_save_card(:'ca', false), '外すのは遠くからでもできる');
select t_ok((select count(*) from gf_my_saved_cards() where id = :'ca') = 0, '外したら一覧から消える');
-- 0024：ボブは一度扉を開けているので、保存を外しても遠くから読める（この GATE の中だけのカードは除く）
select t_ok(gf_can_read_media(:'alice' || '/view-a.jpg'), '外しても、一度扉を開けた GATE のカードの写真は受け取れる');

\echo '== カードへの返信'
:as_bob
select t_throws(format('select gf_card_comment(%L, %L)', :'ca', 'すてき'), 'gf_not_found', 'GATE の外からは返信できない');
select challenge_id as c from gf_request_challenge() \gset
select (gf_enter(:'vg', :'c', :vlat50, :vlon, 10, :day, 2) ->> 'visit_id') as vb2 \gset
select gf_card_comment(:'ca', 'すてきな夕焼け') as cm \gset
select t_ok(:'cm' is not null, 'GATE の中なら返信できる');
select t_throws(format('select gf_card_comment(%L, %L)', :'ca', '   '), 'gf_bad_body', '空の返信は断る');
select t_throws(format('select gf_card_comment(%L, %L)', :'ca', repeat('あ', 201)), 'gf_too_long', '長すぎる返信は断る');
select t_ok((select comments from gf_card_extras(:'vg') where graffiti_id = :'ca') = 1, '返信の数が分かる');
select t_ok((select mine and can_delete from gf_card_comments_of(:'ca') where id = :'cm'), '自分の返信は消せる');
:as_alice
select t_ok(exists (select 1 from gf_my_notifications() where kind = 'card_comment' and actor = :'bob'),
  'カードを書いた人にお知らせが出る');
select t_ok((select count(*) from gf_card_comments_of(:'ca')) = 1, 'カードを書いた本人は、遠くからでも返信を読める');
select gf_card_comment(:'ca', 'ありがとう！') as cm2 \gset
:as_bob
select t_ok(exists (select 1 from gf_my_notifications() where kind = 'card_comment' and actor = :'alice'),
  '書いた本人が返すと、返信した人にお知らせが出る');
:as_admin
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'vg';
:as_bob
select t_ok((select count(*) from gf_card_comments_of(:'ca')) = 2, '一度扉を開けた GATE のカードの返信は、遠くからも読める');
select t_throws(format('select gf_card_comment(%L, %L)', :'ca', '遠くから'), 'gf_not_found', 'GATE を出たら返信は書けない');
:as_carol
select t_throws(format('select * from gf_card_comments_of(%L)', :'ca'), 'gf_not_found', 'ほかの人は読めない');
select t_throws(format('select gf_delete_card_comment(%L)', :'cm'), 'gf_not_found', 'ほかの人の返信は消せない');
select t_throws(format('select gf_report(%L, %L, %L, null)', 'card_comment', :'cm', 'spam'), 'gf_not_found',
  '見えない返信は通報できない');
:as_alice
select gf_report('card_comment', :'cm', 'spam', 'テスト');
:as_admin
select t_ok(exists (select 1 from gf_reports where target_kind = 'card_comment' and target_id = :'cm' and target_user = :'bob'),
  '返信を通報できる（書いた人と文が残る）');
:as_alice
select gf_delete_card_comment(:'cm');
select t_ok((select count(*) from gf_card_comments_of(:'ca') where id = :'cm') = 0,
  'カードを書いた本人は、ほかの人の返信を消せる');

\echo '== お知らせの設定'
:as_alice
select t_ok(gf_set_notify_mute(array['card_comment'], true) = array['card_comment'], '種類ごとにお知らせを止められる');
select t_throws(format('select gf_set_notify_mute(%L::text[], true)', '{nope}'), 'gf_bad_kind', '知らない種類は断る');
:as_admin
delete from gf_notifications where user_id = :'alice' and kind = 'card_comment';
:as_bob
select challenge_id as c from gf_request_challenge() \gset
select (gf_enter(:'vg', :'c', :vlat50, :vlon, 10, :day, 2) ->> 'visit_id') as vb3 \gset
select gf_card_comment(:'ca', 'また来ました') as cm3 \gset
:as_alice
select t_ok(not exists (select 1 from gf_my_notifications() where kind = 'card_comment'), '止めた種類のお知らせは作られない');
select t_ok(cardinality(gf_set_notify_mute(array['card_comment'], false)) = 0, '止めたのを戻せる');
select t_ok(cardinality(gf_my_notify_mutes()) = 0, '戻したら止めた種類はない');

\echo '== 掲示板の「解決しました」'
:as_bob
select gf_board_post(:'vb3', 'question', '夜景がきれいな時間は？', '何時ごろがいいですか') as qt \gset
select t_ok(not (select resolved from gf_board_list3(:'vg') where id = :'qt'), 'はじめは解決していない');
:as_carol
select t_throws(format('select gf_board_resolve(%L, true)', :'qt'), 'gf_not_found', 'ほかの人は「解決しました」にできない');
:as_alice
select gf_board_resolve(:'qt', true);
:as_bob
select t_ok((select resolved from gf_board_list3(:'vg') where id = :'qt'), 'GATE を作った人は「解決しました」にできる');
select gf_board_resolve(:'qt', false);
select t_ok(not (select resolved from gf_board_list3(:'vg') where id = :'qt'), '立てた本人は戻せる');

\echo '== GATE を名前で探す'
:as_bob
select t_ok(exists (select 1 from gf_search_gates(left(:'vg_title', 2), 35.83, 139.75) where id = :'vg' and friend),
  '友達の GATE を名前で探せる');
select t_ok((select approx_lat = round(35.83045::numeric, 3)::double precision
             from gf_search_gates(left(:'vg_title', 2)) where id = :'vg'), '場所はおおよそだけ（約 100m）');
select t_ok((select count(*) from gf_search_gates('%')) = 0, '% や _ は文字として探す');
select t_throws(format('select * from gf_search_gates(%L)', '  '), 'gf_bad_query', '空では探せない');
:as_admin
select visibility as vg_vis from gf_gates where id = :'vg' \gset
update gf_gates set visibility = 'friends' where id = :'vg';
:as_carol
select t_ok(not exists (select 1 from gf_search_gates(left(:'vg_title', 2)) where id = :'vg'),
  '友達だけの GATE は、ほかの人の検索に出ない');
:as_admin
update gf_gates set visibility = 'public' where id = :'vg';
:as_carol
select t_ok(exists (select 1 from gf_search_gates(left(:'vg_title', 2)) where id = :'vg' and not friend),
  '全員に公開した GATE は、だれでも名前で探せる');
:as_admin
update gf_gates set visibility = :'vg_vis' where id = :'vg';

\echo '== 友達の TRAIL・探す・リンクで開く・直す'
:as_admin
select id as g2 from gf_gates where id <> :'vg' and owner = :'alice' and status = 'open' order by created_at limit 1 \gset
insert into gf_trails (owner, title, note, visibility) values (:'alice', '夕焼けの散歩道', '駅から川まで', 'friends')
  returning id as tr \gset
insert into gf_trail_stops (trail_id, seq, gate_id) values (:'tr', 1, :'vg'), (:'tr', 2, :'g2');
:as_bob
select t_ok(exists (select 1 from gf_user_trails(:'alice') where id = :'tr' and stop_count = 2),
  '友達のプロフィールで、その人の TRAIL が見える');
select t_ok(exists (select 1 from gf_trail_get(:'tr')), 'リンクで開ける');
select t_ok(exists (select 1 from gf_trail_search('散歩')), 'TRAIL を名前で探せる');
select t_ok(exists (select 1 from gf_trail_search('', 35.83, 139.75) where id = :'tr'), '近くの TRAIL が見つかる');
select t_ok(not exists (select 1 from gf_trail_search('', 0, 0) where id = :'tr'), '遠くの TRAIL は「近く」に出ない');
:as_carol
select t_ok(not exists (select 1 from gf_user_trails(:'alice') where id = :'tr'), '友達だけの TRAIL は、ほかの人には見えない');
select t_ok(not exists (select 1 from gf_user_trails(:'alice') u join gf_trails t on t.id = u.id where t.visibility <> 'public'),
  'ほかの人に見えるのは、全員に公開した TRAIL だけ');
select t_ok(not exists (select 1 from gf_trail_get(:'tr')), 'リンクを知っていても開けない');
:as_bob
select t_throws(format('select gf_update_trail(%L, %L, %L, %L)', :'tr', 'のっとり', '', 'public'), 'gf_not_found',
  'ほかの人の TRAIL は直せない');
:as_alice
select t_throws(format('select gf_update_trail(%L, %L, %L, %L)', :'tr', '  ', '', 'public'), 'gf_bad_trail', '名前は空にできない');
select gf_update_trail(:'tr', '夕焼けの散歩道', '駅から川まで歩く', 'public');
:as_carol
select t_ok(exists (select 1 from gf_trail_get(:'tr') where note = '駅から川まで歩く'),
  '全員に公開した TRAIL は、友達でなくても開ける');

\echo '== 自分の訪問の記録'
:as_bob
select t_ok((select count(*) from gf_my_visit_history(:'vg')) >= 3, '自分がその GATE に入った日がわかる');
:as_carol
select t_ok((select count(*) from gf_my_visit_history(:'vg')) = 0, 'ほかの人の訪問は見えない');

:as_admin
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'vg';
delete from gf_rate;
