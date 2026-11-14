-- GATE の中の機能（0004）のテスト：掲示板・手紙・思い出・保存と図鑑・通報・ブロック・書き出し・アカウントの削除。
-- 前のテストのあとの状態（人）を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set dave  '00000000-0000-0000-0000-00000000000d'
\set eve   '00000000-0000-0000-0000-00000000000e'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_dave  'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000d'', false); end $$; set role authenticated;'
\set as_eve   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000e'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'
\set same 'array_fill(0.25::real, array[16])'

:as_admin
delete from gf_rate;
insert into storage.objects (bucket_id, name) values
  ('gf-media', :'alice' || '/letter.jpg'), ('gf-media', :'bob' || '/mem1.jpg'), ('gf-media', :'bob' || '/mem2.jpg');

-- アリスの公開の GATE と、3 人の入場
:as_alice
select challenge_id as c from gf_request_challenge() \gset
select gf_create_gate('alice-gate-0101', :'c', '川沿いの桜', '', 'place', 35.82, 139.72, 6, null, 'public', null,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))) as g4 \gset
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g4', :'c', 35.82, 139.72, 5, :same, 2) ->> 'visit_id' as va \gset
:as_bob
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g4', :'c', 35.82, 139.72, 5, :same, 2) ->> 'visit_id' as vb \gset
:as_carol
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g4', :'c', 35.82, 139.72, 5, :same, 2) ->> 'visit_id' as vc \gset

\echo '== 掲示板'
:as_alice
select gf_board_post(:'va', 'memory', '去年の花見', 'ここで集まったね') as t1 \gset
select t_ok(:'t1' is not null, '入場中は話題を立てられる');
select t_throws(format('select gf_board_post(%L, %L, %L, %L)', :'va', 'ad', '広告', ''), 'gf_bad_post',
  '決まっていない種類の話題は立てられない');
select t_throws(format('select gf_board_post(%L, %L, %L, %L)', :'va', 'memory', '  ', ''), 'gf_bad_post',
  '題のない話題は立てられない');
:as_dave
select t_ok((select count(*) from gf_board_list(:'g4')) = 0, '入場していない人には掲示板が見えない');
select t_ok((select count(*) from gf_board_threads) = 0, '入場していない人は表からも読めない');
select t_throws(format('select gf_board_reply(%L, %L, %L)', gen_random_uuid(), :'t1', 'こんにちは'), 'gf_visit_invalid',
  '入場券がなければ返信できない');
:as_bob
select t_ok((select unread from gf_board_list(:'g4') where id = :'t1'), '入場中の人には見えて、まだ読んでいない印が付く');
select gf_board_reply(:'vb', :'t1', '行きたかった！') as r1 \gset
select t_ok((select reply_count from gf_board_list(:'g4') where id = :'t1') = 1, '返信すると数が増える');
select t_ok(not (select unread from gf_board_list(:'g4') where id = :'t1'), '自分で返信した話題は読んだことになる');
:as_alice
select t_ok((select unread from gf_board_list(:'g4') where id = :'t1'), 'ほかの人の返信があると、また未読になる');
select t_ok((select count(*) from gf_board_replies_of(:'t1')) = 1, '返信を読める');
select t_ok(not (select unread from gf_board_list(:'g4') where id = :'t1'), '返信を開くと読んだことになる');
:as_carol
select gf_board_post(:'vc', 'notice', '夜は暗いです', '足もとに気をつけて') as t2 \gset
select gf_board_reply(:'vc', :'t2', '街灯がひとつ切れています') as r2 \gset
:as_bob
select t_throws(format('select gf_board_pin(%L, true)', :'t2'), 'gf_not_found', 'GATE を作った人でなければピン留めできない');
select t_throws(format('select gf_board_delete(%L, %L)', 'thread', :'t2'), 'gf_not_found', '他人の話題は消せない');
:as_alice
select gf_board_pin(:'t2', true);
select t_ok((select id from gf_board_list(:'g4') limit 1) = :'t2', 'ピン留めした話題がいちばん上に出る');
select gf_board_delete('reply', :'r2');
select t_ok((select reply_count from gf_board_list(:'g4') where id = :'t2') = 0, 'GATE を作った人は返信を消せて、数も減る');
:as_admin
update gf_visits set expires_at = now() - interval '1 second' where id = :'vb';
:as_bob
select t_ok((select count(*) from gf_board_list(:'g4')) = 0, '入場券が切れると掲示板は見えない');
select t_throws(format('select gf_board_reply(%L, %L, %L)', :'vb', :'t1', 'まだいる？'), 'gf_visit_invalid',
  '入場券が切れると返信できない');

\echo '== 手紙・タイムカプセル'
:as_alice
select gf_write_letter(:'va', :'bob', 'また来年もここで', :'alice' || '/letter.jpg', null, true) as l1 \gset
select t_ok(:'l1' is not null, '友達に、現地で開く手紙を書ける');
select t_throws(format('select gf_write_letter(%L, %L, %L, null, null, true)', :'va', :'dave', 'こんにちは'), 'gf_bad_recipient',
  'お互いにフォローしていない人には書けない');
select t_throws(format('select gf_write_letter(%L, %L, %L, null, null, false)', :'va', :'bob', '条件なし'), 'gf_bad_letter',
  '日時も現地もない手紙は書けない（いつでも読めるならメッセージと同じ）');
select t_throws(format('select gf_write_letter(%L, null, %L, null, %L, false)', :'va', '昔へ', now() - interval '1 day'),
  'gf_bad_open_at', '過去の日時には開けない');
select gf_write_letter(:'va', null, '1 年後の自分へ', null, now() + interval '1 day', false) as l2 \gset
select t_throws(format('select * from gf_open_letter(%L)', :'l2'), 'gf_letter_not_yet',
  '自分あてのタイムカプセルは、書いた本人でも開く日まで開けない');
:as_bob
select t_ok((select count(*) from gf_letters) = 0, '手紙の表は直接読めない');
select t_ok(exists (select 1 from gf_my_letters() where id = :'l1' and not sent), '自分あての手紙があることは分かる');
select t_ok((select count(*) from storage.objects where name = :'alice' || '/letter.jpg') = 0, '開く前は手紙の写真を受け取れない');
select t_throws(format('select * from gf_open_letter(%L)', :'l1'), 'gf_letter_onsite', '現地で開く手紙は、入場していないと開けない');
select challenge_id as c from gf_request_challenge() \gset
select gf_enter(:'g4', :'c', 35.82, 139.72, 5, :same, 2) ->> 'visit_id' as vb2 \gset
select t_ok((select here from gf_my_letters(:'g4') where id = :'l1'), '入場すると「ここで開ける」と分かる');
select t_ok((select body from gf_open_letter(:'l1')) = 'また来年もここで', '入場中は開けて、中身が読める');
select t_ok((select count(*) from storage.objects where name = :'alice' || '/letter.jpg') = 1, '開いたあとは手紙の写真を受け取れる');
:as_alice
select t_ok((select opened_at from gf_my_letters() where id = :'l1') is not null, '書いた人には、開かれたことが分かる');
select t_throws(format('select gf_delete_letter(%L)', :'l1'), 'gf_not_found', '開かれたあとは、書いた人は消せない');
select gf_write_letter(:'va', :'bob', '桜が咲いたら', null, now() + interval '30 days', false) as l3 \gset
:as_bob
select t_throws(format('select * from gf_open_letter(%L)', :'l3'), 'gf_letter_not_yet', '開く日より前は開けない');
:as_dave
select t_throws(format('select * from gf_open_letter(%L)', :'l1'), 'gf_not_found', '宛先でない人は開けない');
:as_bob
select gf_block(:'alice');
select t_ok(not exists (select 1 from gf_my_letters() where id = :'l3'), 'ブロックした人からの手紙は出ない');
select gf_unblock(:'alice');
select gf_delete_letter(:'l1');
select t_ok(not exists (select 1 from gf_my_letters() where id = :'l1'), '宛先の人は、開いた手紙を消せる');

\echo '== 思い出'
:as_alice
select gf_create_memory(:'va', '2026 年の花見', 'みんなで', 'friends') as m1 \gset
select gf_invite_to_memory(:'m1', :'bob');
select t_throws(format('select gf_invite_to_memory(%L, %L)', :'m1', :'dave'), 'gf_bad_recipient',
  'お互いにフォローしていない人は仲間に入れられない');
:as_admin
update gf_visits set expires_at = now() - interval '1 second' where id = :'vb2';
:as_bob
select gf_add_memory_item(:'m1', :'bob' || '/mem1.jpg', '満開') as i1 \gset
select t_ok(:'i1' is not null, '仲間は、作ってから 72 時間のうちなら現地にいなくても写真を足せる');
select t_ok((select count(*) from gf_memory_list(:'g4')) = 1, '仲間は現地にいなくても思い出を見られる');
select t_ok((select count(*) from storage.objects where name = :'bob' || '/mem1.jpg') = 1, '自分の写真は読める');
select t_throws(format('select gf_add_memory_item(%L, %L, null)', :'m1', :'alice' || '/letter.jpg'), 'gf_bad_media_path',
  '他人のフォルダの写真は足せない');
:as_admin
update gf_settings set value = 1 where key = 'memory_items_per_person';
:as_bob
select t_throws(format('select gf_add_memory_item(%L, %L, null)', :'m1', :'bob' || '/mem2.jpg'), 'gf_memory_full',
  '1 人が足せる写真の数を超えると足せない');
:as_admin
update gf_settings set value = 12 where key = 'memory_items_per_person';
update gf_memories set created_at = now() - interval '4 days' where id = :'m1';
:as_bob
select t_throws(format('select gf_add_memory_item(%L, %L, null)', :'m1', :'bob' || '/mem2.jpg'), 'gf_visit_invalid',
  '72 時間を過ぎたら、現地に来ないと足せない');
:as_carol
select t_ok((select count(*) from gf_memory_list(:'g4')) = 0, '友達向けの思い出は、入場中でも友達でなければ見えない');
select t_ok((select count(*) from storage.objects where name = :'bob' || '/mem1.jpg') = 0, '見えない思い出の写真は受け取れない');
:as_dave
select t_ok((select count(*) from gf_memories) = 0, '入場していない人には思い出が見えない');
:as_bob
select t_ok((select count(*) from gf_my_memories()) = 1, '仲間に入った思い出は「わたし」に出る');
:as_alice
select t_ok(gf_delete_memory_item(:'i1') = :'bob' || '/mem1.jpg', '思い出を作った人は写真を消せて、ファイルの名前が返る');
select t_throws(format('select gf_delete_memory(%L)', gen_random_uuid()), 'gf_not_found', 'ない思い出は消せない');

\echo '== 保存と図鑑'
:as_alice
select t_ok((select visits from gf_my_collection('visited') where gate_id = :'g4') >= 1, '入場すると図鑑に付く');
:as_bob
select gf_set_bookmark(:'g4', true);
select t_ok(exists (select 1 from gf_my_collection('saved') where gate_id = :'g4'), '見てよい GATE は保存できる');
select t_ok((select count(*) from gf_friend_atlas(:'alice')) = 0, '友達の図鑑は、本人が見せると選ぶまで見えない');
:as_admin
select id as g1 from gf_gates where client_key = 'alice-gate-0001' \gset
:as_dave
select t_throws(format('select gf_set_bookmark(%L, true)', :'g1'),
  'gf_not_found', '見てはいけない GATE は保存できない（あることも知らせない）');
:as_alice
select gf_set_atlas_shared(:'g4', true);
:as_bob
select t_ok((select count(*) from gf_friend_atlas(:'alice')) = 1, '本人が見せると選んだ図鑑は、友達に見える');
:as_carol
select t_ok((select count(*) from gf_friend_atlas(:'alice')) = 0, 'お互いにフォローしていない人には見えない');

\echo '== 通報とブロック'
:as_carol
select gf_report('thread', :'t1', 'spam', 'ちがう話');
:as_admin
select t_ok((select target_user from gf_reports where target_id = :'t1') = :'alice', '通報すると、だれのものかはサーバーが埋める');
:as_carol
select t_ok((select count(*) from gf_reports) = 0, '通報は運営だけが読める');
select t_throws(format('select gf_report(%L, %L, %L, null)', 'thread', :'t1', 'bad'), 'gf_bad_report', '決まっていない理由では通報できない');
:as_dave
select t_throws(format('select gf_report(%L, %L, %L, null)', 'thread', :'t1', 'spam'), 'gf_not_found',
  '見えないものは通報できない（あることも知らせない）');
:as_carol
select gf_block(:'alice');
select t_ok((select count(*) from gf_my_blocks()) = 1, 'ブロックした人の一覧に出る');
select t_ok(not exists (select 1 from gf_board_list(:'g4') where author = :'alice'), 'ブロックした人の話題は見えない');
select gf_unblock(:'alice');
select t_ok((select count(*) from gf_my_blocks()) = 0, 'ブロックをやめられる');

\echo '== 書き出しとアカウントの削除'
:as_alice
select t_ok(jsonb_array_length(gf_export_me() -> 'gates') >= 2, '自分の GATE を書き出せる');
select t_ok(jsonb_array_length(gf_export_me() -> 'letters_written') >= 2, '自分が書いた手紙も書き出せる');
:as_admin
insert into auth.users values (:'eve');
insert into gf_terms (user_id, version) values (:'eve', 1) on conflict (user_id) do nothing;
insert into profiles (id, display_name, handle) values (:'eve', 'イブ', 'eve');
:as_eve
select gf_set_bookmark(:'g4', true);
select gf_delete_me();
:as_admin
select t_ok(not exists (select 1 from profiles where id = :'eve'), 'アカウントを消すと、プロフィールも消える');
select t_ok(not exists (select 1 from gf_bookmarks where user_id = :'eve'), 'アカウントを消すと、保存なども一緒に消える');
reset role;
\echo '== GATE の中の機能：すべて通りました'
