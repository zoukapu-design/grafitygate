-- 近くにある友達のカード（0020）のテスト。前のテスト（test_manage）のあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'

\echo '== 準備：アリスの GATE のアリスのカード（図鑑・お気に入り・新着には出ていない）'
:as_admin
delete from gf_rate;
select id as vg, lat as glat, lon as glon from gf_gates where client_key = 'view-gate-0001' \gset
select id as ca, photo_path as ca_photo from gf_graffiti where author = :'alice' and gate_id = :'vg' and deleted_at is null
  order by created_at desc limit 1 \gset
update gf_graffiti set in_atlas = false, local_only = false, visibility = 'friends',
                       created_at = least(created_at, now() - interval '2 days') where id = :'ca';
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'vg';
delete from gf_card_saves where graffiti_id = :'ca';
delete from gf_card_nearby_passes;

\echo '== 近くにある友達のカード'
:as_bob
select t_ok(not gf_can_read_media(:'ca_photo'), '見る前は、写真を受け取れない');
select t_throws(format('select * from gf_nearby_cards(%s, %s, 200)', :glat, :glon), 'gf_inaccurate',
  '位置が不確かなときは探せない');
select t_ok((select count(*) from gf_nearby_cards(:glat + 0.01, :glon, 10) where id = :'ca') = 0,
  '1km 先からは出ない（300m 以内だけ）');
select t_ok((select count(*) from gf_nearby_cards(:glat + 0.002, :glon, 10)
             where id = :'ca' and body <> '' and photo_path = :'ca_photo') = 1,
  '200m ほどの所では、友達のカードが写真とひとこと付きで出る');
select t_ok((select distance_m between 150 and 300 from gf_nearby_cards(:glat + 0.002, :glon, 10) where id = :'ca'),
  '距離はおおよそ');
select t_ok(gf_can_read_media(:'ca_photo'), '近くで見たカードの写真は受け取れる');
select t_ok(gf_save_card(:'ca', true), '近くで見たカードは、お気に入りに保存できる');
select gf_save_card(:'ca', false);
select gf_report_nearby_card(:'ca', 'spam', 'テスト');
:as_admin
select t_ok(exists (select 1 from gf_reports where target_kind = 'graffiti' and target_id = :'ca' and reporter = :'bob'),
  '近くで見たカードを通報できる');
update gf_card_nearby_passes set expires_at = now() - interval '1 minute' where user_id = :'bob';
:as_bob
select t_ok(not gf_can_read_media(:'ca_photo'), '30 分たつと、写真は受け取れない');
select t_throws(format('select gf_save_card(%L, true)', :'ca'), 'gf_not_found', '30 分たつと、お気に入りにできない');
:as_admin
update gf_graffiti set local_only = true where id = :'ca';
:as_bob
select t_ok((select count(*) from gf_nearby_cards(:glat, :glon, 10) where id = :'ca') = 0,
  '「この GATE の中だけ」のカードは出ない');
:as_admin
update gf_graffiti set local_only = false, visibility = 'private' where id = :'ca';
:as_bob
select t_ok((select count(*) from gf_nearby_cards(:glat, :glon, 10) where id = :'ca') = 0, '自分だけのカードは出ない');
:as_admin
update gf_graffiti set visibility = 'friends' where id = :'ca';
:as_carol
select t_ok((select count(*) from gf_nearby_cards(:glat, :glon, 10) where id = :'ca') = 0,
  'お互いにフォローしていない人には出ない');
select t_ok(not gf_can_read_media(:'ca_photo'), 'お互いにフォローしていない人は写真を受け取れない');
:as_alice
select t_ok((select count(*) from gf_nearby_cards(:glat, :glon, 10) where id = :'ca') = 0, '自分のカードは出ない');

:as_admin
delete from gf_card_nearby_passes;
delete from gf_rate;
