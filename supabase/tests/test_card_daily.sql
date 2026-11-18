-- 1 日 1 枚と、手紙に添えるカード（0030）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'
\set same 'array_fill(0.25::real, array[16])'

\echo '== 1 つの GATE に 1 人 1 日 1 枚'
:as_admin
delete from gf_rate;
:as_alice
select challenge_id as c from gf_request_challenge() \gset
select gf_create_gate('daily-gate-0001', :'c', '朝の広場', '', 'place', 35.91, 139.61, 6, null, 'public', null,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))) as dg \gset
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'dg', :'c', 35.91, 139.61, 5, :same, 2) ->> 'visit_id' as va \gset
:as_bob
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'dg', :'c', 35.91, 139.61, 5, :same, 2) ->> 'visit_id' as vb1 \gset
select t_ok(not (gf_my_card_today(:'dg') ->> 'posted')::boolean, 'まだ残していない日は「残していない」');
select gf_post_graffiti(:'vb1', 'おはよう', :'bob' || '/daily-1.jpg', 'friends', false) as b1 \gset
select t_ok((gf_my_card_today(:'dg') ->> 'card_id') = :'b1', '残したら、今日のカードがわかる');
select t_ok((gf_my_card_today(:'dg') ->> 'next_at')::timestamptz > now(), '次に残せる時刻は、これから先（次の 0 時）');
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'dg', :'c', 35.91, 139.61, 5, :same, 2) ->> 'visit_id' as vb2 \gset
select t_throws(format('select gf_post_graffiti(%L, %L, null, null, false)', :'vb2', '2 枚目'), 'gf_card_today',
  '同じ日に同じ GATE へ 2 枚目は残せない（扉を開け直しても）');
select gf_delete_graffiti(:'b1');
select t_throws(format('select gf_post_graffiti(%L, %L, null, null, false)', :'vb2', '消して作り直し'), 'gf_card_today',
  '消しても、その日はもう残せない');
select t_ok((gf_my_card_today(:'dg') ->> 'posted')::boolean and (gf_my_card_today(:'dg') ->> 'card_id') is null,
  '消したカードは「残した」のまま、カードの ID は返さない');
:as_alice
select gf_post_graffiti(:'va', 'ようこそ', :'alice' || '/daily-a.jpg', 'friends', false) as a1 \gset
select t_ok(:'a1' is not null, 'ほかの人は、同じ日に同じ GATE に残せる');
:as_admin
update gf_graffiti set created_at = now() - interval '1 day' where id = :'b1';
:as_bob
select gf_post_graffiti(:'vb2', '次の日', null, 'friends', false) as b2 \gset
select t_ok(:'b2' is not null, '次の日には、また残せる');
select t_ok((select count(*) from gf_my_cards()) >= 1 and not exists (select 1 from gf_my_cards() where id = :'b1'),
  '自分のカードの一覧に、消したカードは出ない');
select t_ok(exists (select 1 from gf_my_cards() where id = :'b2' and gate_title = '朝の広場'), '自分のカードの一覧に GATE の名前が付く');

\echo '== 手紙にカードを添える'
:as_admin
delete from gf_rate;
-- アリスのカードは「自分だけ」にして、手紙で送ったときだけボブが写真を見られることを確かめる
update gf_graffiti set visibility = 'private' where id = :'a1';
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'dg' and user_id = :'bob';
:as_alice
select t_throws(format('select gf_write_letter2(%L, %L, %L, %L, now(), false)', :'va', :'bob', 'これ見て', :'b2'), 'gf_bad_card',
  'ほかの人のカードは添えられない');
select gf_write_letter2(:'va', :'bob', 'ここで撮ったよ', :'a1', now(), false) as l1 \gset
:as_bob
select t_ok(not gf_can_read_media(:'alice' || '/daily-a.jpg'), '開ける前は、添えたカードの写真を見られない');
select t_ok((select card_id = :'a1' and card_title is null and card_gate_title = '朝の広場' and not card_gone
             from gf_open_letter2(:'l1')), '開けると、添えたカードと GATE の名前が届く');
select t_ok(gf_can_read_media(:'alice' || '/daily-a.jpg'), '開けた宛先の人は、添えたカードの写真を見られる');
:as_carol
select t_ok(not gf_can_read_media(:'alice' || '/daily-a.jpg'), 'ほかの人は写真を見られない');
:as_alice
select gf_delete_graffiti(:'a1');
:as_bob
select t_ok((select card_gone and card_id is null and card_photo is null from gf_open_letter2(:'l1')),
  '書いた人がカードを消すと、手紙のカードも見えなくなる');
select t_ok(not gf_can_read_media(:'alice' || '/daily-a.jpg'), '消したカードの写真は見られない');
:as_admin
delete from gf_rate;
