-- 友達の GATE・グラフィティ図鑑・「来たよ」カード（0017）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
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

\echo '== 準備：アリスの景色の GATE に、アリスとボブがカードを残す'
:as_admin
delete from gf_rate;
select id as vg from gf_gates where client_key = 'view-gate-0001' \gset
:as_alice
select challenge_id as c from gf_request_challenge() \gset
select (gf_enter(:'vg', :'c', :vlat50, :vlon, 10, :day, 2) ->> 'visit_id') as va \gset
select gf_post_graffiti(:'va', '夕焼けがきれいだった', :'alice' || '/view-a.jpg', 'friends', false) as ca \gset
:as_bob
select challenge_id as c from gf_request_challenge() \gset
select (gf_enter(:'vg', :'c', :vlat50, :vlon, 10, :day, 2) ->> 'visit_id') as vb \gset
select gf_post_graffiti(:'vb', '俺も来た', :'bob' || '/view-b.jpg', 'friends', false) as cb \gset

\echo '== 友達が作った GATE'
:as_bob
select t_ok(exists (select 1 from gf_user_gates(:'alice') where id = :'vg'), '友達が作った GATE が見える');
select t_ok(not exists (select 1 from gf_user_gates(:'alice') u join gf_gates g on g.id = u.id where g.visibility = 'private'),
  '自分だけの GATE は見えない');
select t_ok((select approx_lat = round(35.83::numeric, 3)::double precision from gf_user_gates(:'alice') where id = :'vg'),
  '位置はおおよそ（約 100m）');

\echo '== グラフィティ図鑑（A：写真・場所・日付まで。文は返さない）'
:as_admin
-- 新着（24 時間）の決まりと混ざらないよう、カードを 2 日前にする。ボブの入場券も切る
update gf_graffiti set created_at = now() - interval '2 days' where id in (:'ca', :'cb');
update gf_visits set expires_at = now() - interval '1 minute' where user_id = :'bob' and gate_id = :'vg';
:as_bob
select t_ok((select count(*) from gf_user_card_atlas(:'alice')) = 0, '書いた人が載せていないカードは、図鑑に出ない');
select t_ok(not gf_can_read_media(:'alice' || '/view-a.jpg'), '載せていないカードの写真は、遠くから受け取れない');
:as_alice
select t_ok((select count(*) from gf_user_card_atlas(:'alice')) >= 1, '自分の図鑑には、自分のカードがいつも出る');
select gf_set_graffiti_atlas(:'ca', true);
:as_bob
select t_ok((select count(*) from gf_user_card_atlas(:'alice') where id = :'ca' and photo_path = :'alice' || '/view-a.jpg') = 1,
  '載せたカードは、友達の図鑑に写真つきで出る');
select t_ok(gf_can_read_media(:'alice' || '/view-a.jpg'), '図鑑に載せたカードの写真は、友達なら遠くから受け取れる');
select t_throws(format('select gf_set_graffiti_atlas(%L, false)', :'ca'), 'gf_not_found', 'ほかの人のカードは載せ外しできない');
:as_carol
select t_ok((select count(*) from gf_user_card_atlas(:'alice')) = 0, 'お互いにフォローしていない人には、図鑑のカードは出ない');
select t_ok(not gf_can_read_media(:'alice' || '/view-a.jpg'), 'お互いにフォローしていない人は、写真を受け取れない');
:as_admin
update gf_graffiti set local_only = true where id = :'ca';
:as_bob
select t_ok((select count(*) from gf_user_card_atlas(:'alice') where id = :'ca') = 0, '「現地だけ」のカードは図鑑に出ない');
:as_admin
update gf_graffiti set local_only = false where id = :'ca';

\echo '== 「来たよ」カード'
:as_bob
select t_throws(format('select gf_send_card_link(%L, %L, %L)', :'cb', :'ca', '俺も今日来たよ！'), 'gf_not_found',
  'GATE の外（入場券なし）からは送れない');
select challenge_id as c from gf_request_challenge() \gset
select (gf_enter(:'vg', :'c', :vlat50, :vlon, 10, :day, 2) ->> 'visit_id') as vb2 \gset
select t_throws(format('select gf_send_card_link(%L, %L, %L)', :'cb', :'cb', 'x'), 'gf_not_found', '自分のカードには送れない');
select t_throws(format('select gf_send_card_link(%L, %L, %L)', :'ca', :'cb', 'x'), 'gf_not_found',
  'ほかの人のカードを添えては送れない');
select gf_send_card_link(:'cb', :'ca', '俺も今日来たよ！') as link \gset
select t_ok(:'link' is not null, '友達のカードに、自分のカードを添えて「来たよ」を送れる');
select t_throws(format('select gf_send_card_link(%L, %L, %L)', :'cb', :'ca', 'もう一度'), 'gf_already_sent',
  '同じ組み合わせは 1 回だけ');
:as_admin
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'vg';
:as_alice
select t_ok(exists (select 1 from gf_my_notifications() where kind = 'card_link'), '届いた人にお知らせが出る');
select t_ok((select count(*) from gf_my_card_links() where incoming and body = '俺も今日来たよ！'
             and from_body = '俺も来た' and to_body = '夕焼けがきれいだった') = 1,
  '届いた人は、遠くからでも 2 枚のカードとひとことを見られる');
select t_ok(gf_can_read_media(:'bob' || '/view-b.jpg'), '添えられたカードの写真も受け取れる');
select gf_mark_card_links_seen();
select t_ok((select seen from gf_my_card_links() where id = :'link'), '見たら「見た」になる');
:as_carol
select t_ok((select count(*) from gf_my_card_links()) = 0, 'ほかの人には見えない');
select t_ok(not gf_can_read_media(:'bob' || '/view-b.jpg'), 'ほかの人は添えられたカードの写真を受け取れない');
:as_bob
select t_ok((select count(*) from gf_card_links_in(:'vg') where id = :'link') = 1, '送った人は、この GATE の「来たよ」を見られる');
:as_admin
update gf_graffiti set deleted_at = now() where id = :'cb';
:as_alice
select t_ok((select count(*) from gf_my_card_links() where id = :'link') = 0, '送った人がカードを消すと、「来たよ」も見えなくなる');
select t_ok(not gf_can_read_media(:'bob' || '/view-b.jpg'), '消したカードの写真は受け取れない');
:as_admin
delete from gf_rate;
