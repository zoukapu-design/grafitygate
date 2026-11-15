-- GATE を直す・閉じる、一緒に管理する人、カードを直す、メッセージに写真（0019）のテスト。
-- 前のテスト（test_cards_trails）のあとの状態を使う。run.sh から実行する。
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

\echo '== 準備'
:as_admin
delete from gf_rate;
select id as vg, title as vg_title, coalesce(cover_path, '') as vg_cover from gf_gates where client_key = 'view-gate-0001' \gset
select id as qt from gf_board_threads where gate_id = :'vg' and author = :'bob' and deleted_at is null
  order by created_at desc limit 1 \gset
select id as ca, body as ca_body from gf_graffiti where author = :'alice' and gate_id = :'vg' and deleted_at is null
  order by created_at desc limit 1 \gset
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'vg';

\echo '== 一緒に管理する人'
:as_bob
select t_throws(format('select gf_board_pin(%L, true)', :'qt'), 'gf_not_found', '管理していない人はピン留めできない');
select t_throws(format('select gf_edit_gate(%L, %L, null, null, null)', :'vg', 'のっとり'), 'gf_not_found',
  '管理していない GATE は直せない');
select t_throws(format('select gf_add_gate_manager(%L, %L)', :'vg', :'carol'), 'gf_not_found',
  'ほかの人の GATE に管理する人を入れられない');
:as_alice
select t_throws(format('select gf_add_gate_manager(%L, %L)', :'vg', :'carol'), 'gf_not_friends',
  'お互いにフォローしていない人は入れられない');
select gf_add_gate_manager(:'vg', :'bob');
select gf_add_gate_manager(:'vg', :'bob');
select t_ok((select count(*) from gf_gate_managers_of(:'vg') where user_id = :'bob') = 1, '2 回入れても 1 人');
:as_bob
select t_ok(exists (select 1 from gf_my_notifications() where kind = 'gate_manager' and actor = :'alice'),
  '入れられた人にお知らせが出る');
select t_ok(exists (select 1 from gf_my_managed_gates() where id = :'vg'), '一緒に管理している GATE が分かる');
select gf_edit_gate(:'vg', '夕焼けの見える丘（西口）', '夕方がおすすめです', null, null);
select t_ok((select title = '夕焼けの見える丘（西口）' and note = '夕方がおすすめです' from gf_gate_summary(:'vg')),
  '一緒に管理する人は、名前・紹介を直せる');
select t_throws(format('select gf_edit_gate(%L, null, null, null, %L)', :'vg', 'private'), 'gf_not_owner',
  '見せる範囲は、作った人だけが変えられる');
select t_throws(format('select gf_edit_gate(%L, %L, null, null, null)', :'vg', '   '), 'gf_bad_title', '名前は空にできない');
select t_throws(format('select gf_edit_gate(%L, null, %L, null, null)', :'vg', repeat('あ', 401)), 'gf_too_long',
  '紹介は 400 文字まで');
select t_throws(format('select gf_edit_gate(%L, null, null, %L, null)', :'vg', :'alice' || '/cover.jpg'), 'gf_bad_media_path',
  '表紙は自分のフォルダの写真だけ');
select gf_edit_gate(:'vg', null, null, :'bob' || '/cover.jpg', null);
select t_ok((select cover_path = :'bob' || '/cover.jpg' from gf_gate_summary(:'vg')), '表紙を差し替えられる');
select gf_board_pin(:'qt', true);
select gf_board_pin(:'qt', false);
select t_ok(true, '一緒に管理する人は、掲示板をピン留めできる');
:as_carol
select t_ok((select count(*) from gf_gate_managers_of(:'vg')) = 0 or not exists (
  select 1 from gf_gates g where g.id = :'vg' and gf_can_see_gate(g, :'carol')), '見えない GATE の管理する人は分からない');
:as_alice
select gf_remove_gate_manager(:'vg', :'bob');
:as_bob
select t_throws(format('select gf_edit_gate(%L, %L, null, null, null)', :'vg', 'まだ直す'), 'gf_not_found',
  '外されたら直せない');
:as_alice
select gf_add_gate_manager(:'vg', :'bob');
:as_bob
select gf_remove_gate_manager(:'vg', :'bob');
select t_ok(not exists (select 1 from gf_my_managed_gates() where id = :'vg'), '一緒に管理する人は、自分で抜けられる');
:as_admin
update gf_gates set title = :'vg_title', note = '', cover_path = nullif(:'vg_cover', '') where id = :'vg';

\echo '== 閉じる・開け直す'
:as_bob
select t_throws(format('select gf_set_gate_open(%L, false)', :'vg'), 'gf_not_found', 'ほかの人は閉じられない');
:as_alice
select gf_set_gate_open(:'vg', false);
:as_bob
select t_ok(not exists (select 1 from gf_gate_summary(:'vg')), '閉じた GATE は、ほかの人に見えない');
:as_alice
select t_ok(exists (select 1 from gf_gate_summary(:'vg') where status = 'closed'), '作った人には「閉じている」と見える');
select gf_set_gate_open(:'vg', true);
:as_bob
select t_ok(exists (select 1 from gf_gate_summary(:'vg')), '開け直すと、また見える');

\echo '== カードを直す'
:as_bob
select t_throws(format('select gf_edit_graffiti(%L, %L, null, null)', :'ca', 'のっとり'), 'gf_not_found',
  'ほかの人のカードは直せない');
select challenge_id as c from gf_request_challenge() \gset
select (gf_enter(:'vg', :'c', :vlat50, :vlon, 10, :day, 2) ->> 'visit_id') as vb \gset
select t_ok(exists (select 1 from gf_graffiti where id = :'ca'), '直す前は、GATE の中で見える');
:as_alice
select gf_edit_graffiti(:'ca', '夕焼けがとてもきれいだった', null, null);
:as_admin
select t_ok((select edited_at is not null and original_body = :'ca_body' and body = '夕焼けがとてもきれいだった'
             from gf_graffiti where id = :'ca'), '文を直すと「直しました」になり、最初の文が残る');
:as_alice
select gf_edit_graffiti(:'ca', 'もう一度直した', null, null);
:as_admin
select t_ok((select original_body = :'ca_body' from gf_graffiti where id = :'ca'), '最初の文は 1 回だけ残す');
:as_alice
select t_throws(format('select gf_edit_graffiti(%L, %L, null, null)', :'ca', repeat('あ', 281)), 'gf_too_long',
  '長すぎる文にはできない');
select gf_edit_graffiti(:'ca', null, 'private', null);
:as_bob
select t_ok(not exists (select 1 from gf_graffiti where id = :'ca'), '「自分だけ」にしたカードは、ほかの人に見えなくなる');
:as_alice
select gf_edit_graffiti(:'ca', :'ca_body', 'friends', null);
:as_admin
update gf_graffiti set edited_at = null, original_body = null where id = :'ca';
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'vg';

\echo '== メッセージに写真'
:as_alice
select gf_dm_send2(:'bob', '', :'alice' || '/dm-1.jpg') as dm1 \gset
select t_throws(format('select gf_dm_send2(%L, %L, %L)', :'bob', '', :'bob' || '/x.jpg'), 'gf_bad_media_path',
  'ほかの人のフォルダの写真は送れない');
select t_throws(format('select gf_dm_send2(%L, %L, null)', :'bob', '   '), 'gf_bad_post', '空のメッセージは送れない');
select t_throws(format('select gf_dm_send2(%L, %L, %L)', :'carol', 'やあ', :'alice' || '/dm-2.jpg'), 'gf_bad_recipient',
  'お互いにフォローしていない人には送れない');
:as_bob
select t_ok((select photo_path = :'alice' || '/dm-1.jpg' from gf_dm_messages_with2(:'alice') where id = :'dm1'),
  '写真だけのメッセージが届く');
select t_ok(gf_can_read_media(:'alice' || '/dm-1.jpg'), '受け取った人は写真を見られる');
:as_carol
select t_ok(not gf_can_read_media(:'alice' || '/dm-1.jpg'), 'ほかの人はメッセージの写真を見られない');

:as_admin
delete from gf_rate;
