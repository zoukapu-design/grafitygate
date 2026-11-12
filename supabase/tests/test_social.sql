-- お知らせと DM（0005）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set dave  '00000000-0000-0000-0000-00000000000d'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_dave  'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000d'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'

\echo '== お知らせ'
:as_alice
select t_ok(exists (select 1 from gf_my_notifications() where kind = 'board_reply' and actor = :'bob'),
  '自分の話題に返信があると知らせが来る');
select t_ok(exists (select 1 from gf_my_notifications() where kind = 'board_thread' and actor = :'carol'),
  '自分の GATE に話題が立つと知らせが来る');
select t_ok(exists (select 1 from gf_my_notifications() where kind = 'letter_opened' and actor = :'bob'),
  '書いた手紙が開かれると知らせが来る');
select t_ok(exists (select 1 from gf_my_notifications() where kind = 'memory_photo' and actor = :'bob'),
  '思い出に写真が足されると知らせが来る');
select t_ok(exists (select 1 from gf_my_notifications() where kind = 'follow' and actor = :'bob'),
  'フォローされたことも知らせに出る');
select t_ok(not exists (select 1 from gf_my_notifications() where actor = :'alice'), '自分の操作は自分に知らせない');
select t_ok((select notifications from gf_unread_counts()) > 0, 'まだ見ていない知らせの数が分かる');
select gf_mark_notifications_seen();
select t_ok((select notifications from gf_unread_counts()) = 0, '見たことにすると 0 になる');
select t_ok(not exists (select 1 from gf_my_notifications() where unread), '見たあとは新しい印が消える');
select t_ok((select count(*) from gf_notifications) = 0, 'お知らせの表は直接読めない');
:as_bob
select t_ok(exists (select 1 from gf_my_notifications() where kind = 'letter' and actor = :'alice'),
  '手紙が届くと知らせが来る（中身は入らない）');
select t_ok(exists (select 1 from gf_my_notifications() where kind = 'memory_invite'), '思い出の仲間に入れられると知らせが来る');
:as_alice
select gf_block(:'carol');
select t_ok(not exists (select 1 from gf_my_notifications() where actor = :'carol'), 'ブロックした人の知らせは出ない');
select gf_unblock(:'carol');

\echo '== DM'
:as_alice
select gf_dm_send(:'bob', 'こんど桜を見に行こう') as m1 \gset
select t_ok(:'m1' is not null, '友達にメッセージを送れる');
select t_throws(format('select gf_dm_send(%L, %L)', :'carol', 'こんにちは'), 'gf_bad_recipient',
  'お互いにフォローしていない人には送れない');
select t_throws(format('select gf_dm_send(%L, %L)', :'bob', '   '), 'gf_bad_post', '空のメッセージは送れない');
:as_bob
select t_ok((select messages from gf_unread_counts()) = 1, 'まだ読んでいないメッセージの数が分かる');
select t_ok((select unread from gf_dm_threads() where other = :'alice') = 1, '相手ごとに、まだ読んでいない数が分かる');
select t_ok((select count(*) from gf_dm_messages_with(:'alice')) = 1, '相手とのメッセージを読める');
select t_ok((select messages from gf_unread_counts()) = 0, '開くと読んだことになる');
select t_ok((select count(*) from gf_dm_messages) = 0, 'メッセージの表は直接読めない');
select gf_dm_send(:'alice', 'いいね！') as m2 \gset
:as_dave
select t_ok((select count(*) from gf_dm_messages_with(:'alice')) = 0, 'ほかの人どうしのメッセージは読めない');
select t_throws(format('select gf_report_dm(%L, %L, null)', :'m1', 'spam'), 'gf_not_found', '自分に届いていないメッセージは通報できない');
:as_bob
select gf_report_dm(:'m1', 'harassment', null);
:as_admin
select t_ok(exists (select 1 from gf_reports where target_kind = 'dm' and target_user = :'alice'), 'メッセージを通報できる');
:as_bob
select gf_block(:'alice');
select t_ok(not exists (select 1 from gf_dm_threads() where other = :'alice'), 'ブロックした人との話は一覧から消える');
:as_alice
select t_throws(format('select gf_dm_send(%L, %L)', :'bob', 'あれ？'), 'gf_bad_recipient', 'ブロックされたら送れない');
:as_bob
select gf_unblock(:'alice');
:as_alice
select gf_dm_delete(:'m1');
:as_bob
select t_ok(not exists (select 1 from gf_dm_messages_with(:'alice') where id = :'m1'), '送った人が消したメッセージは相手からも消える');
:as_alice
select t_throws(format('select gf_dm_delete(%L)', :'m2'), 'gf_not_found', '相手のメッセージは消せない');
select t_ok(jsonb_array_length(gf_export_me_social() -> 'messages_sent') = 0, '書き出しには自分が送った（消していない）メッセージが入る');
reset role;
\echo '== お知らせと DM：すべて通りました'
