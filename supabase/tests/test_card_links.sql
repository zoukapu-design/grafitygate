-- グラフィティカードをアルバム・掲示板につなげる（0031）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'
\set same 'array_fill(0.25::real, array[16])'

:as_admin
delete from gf_rate;
:as_alice
select challenge_id as c from gf_request_challenge() \gset
select gf_create_gate('links-gate-0001', :'c', '川べりのベンチ', '', 'place', 35.93, 139.63, 6, null, 'public', null,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))) as lg \gset
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'lg', :'c', 35.93, 139.63, 5, :same, 2) ->> 'visit_id' as va \gset
select gf_post_graffiti(:'va', 'ベンチで休憩', :'alice' || '/links-a.jpg', 'friends', false) as ca \gset
:as_bob
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'lg', :'c', 35.93, 139.63, 5, :same, 2) ->> 'visit_id' as vb \gset
select gf_post_graffiti(:'vb', '川の音', :'bob' || '/links-b.jpg', 'friends', false) as cb \gset
:as_admin
-- アリスのカードは「自分だけ」に。アルバム・掲示板に入れたときだけ、ほかの人に見えることを確かめる
update gf_graffiti set visibility = 'private' where id = :'ca';

\echo '== アルバムにカードを入れる'
:as_alice
select gf_create_memory(:'va', 'ベンチの思い出', '', 'friends') as m \gset
select t_throws(format('select gf_add_memory_card(%L, %L)', :'m', :'cb'), 'gf_bad_card', 'ほかの人のカードは入れられない');
select gf_add_memory_card(:'m', :'ca') as ia \gset
select t_throws(format('select gf_add_memory_card(%L, %L)', :'m', :'ca'), 'gf_already_added', '同じカードは 2 回入れられない');
select t_ok((select media_kind = 'card' and photo_path = 'card:' || :'ca' from gf_memory_items where id = :'ia'),
  'アルバムの欄には、カードの印（card:）を入れる（ファイルの名前は入れない）');
select t_ok((select cover_path = :'alice' || '/links-a.jpg' from gf_memory_list(:'lg') where id = :'m'),
  'アルバムの表紙には、カードの写真が使われる');
:as_bob
select t_ok((select card_id = :'ca' and body = 'ベンチで休憩' and gate_title = '川べりのベンチ' from gf_memory_cards(:'m')),
  'アルバムが見える人には、入れたカードの中身が届く');
select t_ok(gf_can_read_media(:'alice' || '/links-a.jpg'), 'アルバムが見える人は、入れたカードの写真を見られる');
:as_carol
select t_ok(not exists (select 1 from gf_memory_cards(:'m')), 'アルバムが見えない人には届かない');
select t_ok(not gf_can_read_media(:'alice' || '/links-a.jpg'), 'アルバムが見えない人は、写真を見られない');
:as_alice
select t_ok(cardinality(gf_delete_memory_media(:'ia')) = 0, 'アルバムからカードを外しても、消すファイルの名前は返らない（カードの写真は残す）');
select gf_add_memory_card(:'m', :'ca') as ia2 \gset

\echo '== 掲示板の話題・返信にカードを添える'
:as_alice
select gf_board_post(:'va', 'memory', 'ベンチの話', '座ると川が見える') as t \gset
select gf_board_attach_card('thread', :'t', :'ca');
:as_bob
select t_throws(format('select gf_board_attach_card(%L, %L, %L)', 'thread', :'t', :'cb'), 'gf_not_found',
  'ほかの人の話題には添えられない');
select gf_board_reply(:'vb', :'t', 'ぼくも座った') as r \gset
select t_throws(format('select gf_board_attach_card(%L, %L, %L)', 'reply', :'r', :'ca'), 'gf_bad_card',
  'ほかの人のカードは添えられない');
select gf_board_attach_card('reply', :'r', :'cb');
select t_ok((select count(*) = 1 from gf_board_cards(:'lg') where target_id = :'t' and card_id = :'ca'),
  'GATE の話題の一覧で、添えたカードがわかる');
select t_ok((select count(*) = 2 from gf_board_cards(:'lg', :'t')), '話題を開くと、話題と返信のカードが届く');
select t_ok(gf_can_read_media(:'alice' || '/links-a.jpg'), '話題を読める人は、添えたカードの写真を見られる');
:as_carol
select t_ok(not exists (select 1 from gf_board_cards(:'lg', :'t')), 'まだ扉を開けていない人には届かない');
:as_alice
select gf_board_attach_card('thread', :'t', null);
:as_bob
select t_ok(not exists (select 1 from gf_board_cards(:'lg') where target_id = :'t'), '外したカードは出ない');

\echo '== カードを消すと、アルバム・掲示板からも見えなくなる'
:as_alice
select gf_board_attach_card('thread', :'t', :'ca');
select gf_delete_graffiti(:'ca');
:as_admin
select t_ok(not exists (select 1 from gf_memory_items where card_id = :'ca'), 'カードを消すと、アルバムから外れる');
:as_bob
select t_ok(not exists (select 1 from gf_board_cards(:'lg', :'t') where card_id = :'ca'), '消したカードは、掲示板にも出ない');
select t_ok(not gf_can_read_media(:'alice' || '/links-a.jpg'), '消したカードの写真は見られない');
:as_admin
delete from gf_rate;
