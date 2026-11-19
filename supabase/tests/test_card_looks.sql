-- カードの名前と仕上げを、保存・近く・メッセージにも返す（0032）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'
\set same 'array_fill(0.25::real, array[16])'

\echo '== 準備：アリスとボブは友達。アリスが名前と仕上げを付けたカードを残す'
:as_admin
delete from gf_rate;
delete from gf_card_nearby_passes;
insert into follows (follower, followee) values (:'alice', :'bob'), (:'bob', :'alice') on conflict do nothing;
:as_alice
select challenge_id as c from gf_request_challenge() \gset
select gf_create_gate('looks-gate-0001', :'c', '坂の上の灯台', '', 'place', 34.71, 135.21, 6, null, 'public', null,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))) as lg \gset
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'lg', :'c', 34.71, 135.21, 5, :same, 2) ->> 'visit_id' as va \gset
select gf_post_graffiti(:'va', '灯台の明かり', :'alice' || '/looks-a.jpg', 'friends', false) as ca \gset
select gf_set_card_title(:'ca', '灯台の約束');
select gf_set_card_finish(:'ca', 'gold');
:as_bob
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'lg', :'c', 34.71, 135.21, 5, :same, 2) ->> 'visit_id' as vb \gset
select gf_save_card(:'ca', true);

\echo '== 保存したカード'
select t_ok((select title = '灯台の約束' and finish = 'gold' and body = '灯台の明かり' from gf_my_saved_cards2() where id = :'ca'),
  '保存したカードに、名前と仕上げが付く');
select t_ok((select array_agg(id) from gf_my_saved_cards2()) = (select array_agg(id) from gf_my_saved_cards()),
  '行と並びは、前の関数と同じ');

\echo '== 近くの友達のカード'
:as_admin
delete from gf_rate;
:as_bob
select t_ok((select title = '灯台の約束' and finish = 'gold' from gf_nearby_cards2(34.71, 135.21, 10) where id = :'ca'),
  '近くの友達のカードに、名前と仕上げが付く');
select t_ok((select array_agg(id) from gf_nearby_cards2(34.71, 135.21, 10))
            = (select array_agg(id) from gf_nearby_cards(34.71, 135.21, 10)),
  '行と並びは、前の関数と同じ');
select t_throws('select * from gf_nearby_cards2(34.71, 135.21, 500)', 'gf_inaccurate', '位置の確かさの決まりは前と同じ');
:as_carol
select t_ok(not exists (select 1 from gf_nearby_cards2(34.71, 135.21, 10) where id = :'ca'),
  '友達でない人には出ない');

\echo '== カード図鑑'
:as_alice
select gf_set_graffiti_atlas(:'ca', true);
:as_bob
select t_ok((select title = '灯台の約束' and finish = 'gold' from gf_user_card_atlas2(:'alice') where id = :'ca'),
  'カード図鑑に、名前と仕上げが付く');
select t_ok((select array_agg(id) from gf_user_card_atlas2(:'alice')) = (select array_agg(id) from gf_user_card_atlas(:'alice')),
  '行と並びは、前の関数と同じ');
:as_carol
select t_ok(not exists (select 1 from gf_user_card_atlas2(:'alice')), '友達でない人には出ない');

\echo '== メッセージで届いたカード'
:as_alice
select gf_dm_send_card(:'bob', :'ca', '灯台に来たよ') as dm \gset
:as_bob
select t_ok((select card_title = '灯台の約束' and card_finish = 'gold' and card_body = '灯台の明かり'
             from gf_dm_messages_with4(:'alice') where id = :'dm'),
  '届いたカードに、名前と仕上げが付く');
select t_ok((select array_agg(id) from gf_dm_messages_with4(:'alice')) = (select array_agg(id) from gf_dm_messages_with3(:'alice')),
  '行と並びは、前の関数と同じ');
:as_alice
select gf_delete_graffiti(:'ca');
:as_bob
select t_ok((select card_id is null and card_title is null and card_finish is null and card_gone
             from gf_dm_messages_with4(:'alice') where id = :'dm'),
  '書いた人がカードを消したら、名前も仕上げも返さない');
select t_ok(not exists (select 1 from gf_my_saved_cards2() where id = :'ca'), '消したカードは保存の一覧からも消える');
