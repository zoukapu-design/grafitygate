-- カードの仕上げ（0026）のテスト。run.sh から実行する。
\set ON_ERROR_STOP on
\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'

\echo '== カードの仕上げ'
:as_admin
select id as card, author as card_author from gf_graffiti where author = :'alice' order by created_at limit 1 \gset
select t_ok((select finish = 'normal' from gf_graffiti where id = :'card'), 'はじめは「ふつう」');
:as_bob
select t_throws(format('select gf_set_card_finish(%L, %L)', :'card', 'gold'), 'gf_not_found', 'ほかの人のカードは変えられない');
:as_alice
select t_throws(format('select gf_set_card_finish(%L, %L)', :'card', 'rainbow'), 'gf_bad_finish', '決まった仕上げだけ');
select gf_set_card_finish(:'card', 'holo');
:as_admin
select t_ok((select finish = 'holo' from gf_graffiti where id = :'card'), '書いた本人は「キラ」にできる');
:as_alice
select gf_set_card_finish(:'card', 'normal');

\echo '== 友達の新着（仕上げつき）'
:as_bob
select t_ok((select count(*) from gf_friend_feed2()) = (select count(*) from gf_friend_feed()),
            '新着の 2 番目の形は、前の形と同じカードを返す');
select t_ok((select bool_and(finish in ('normal', 'holo', 'gold', 'neon')) from gf_friend_feed2()) is not false,
            '新着に仕上げが付く');

\echo '== カードの名前'
:as_alice
select gf_set_card_title(:'card', '  夕焼けの約束  ');
:as_admin
select t_ok((select title = '夕焼けの約束' from gf_graffiti where id = :'card'), '書いた本人は名前を付けられる（前後の空白は消す）');
:as_bob
select t_throws(format('select gf_set_card_title(%L, %L)', :'card', 'のっとり'), 'gf_not_found', 'ほかの人のカードには付けられない');
:as_alice
select t_throws(format('select gf_set_card_title(%L, %L)', :'card', repeat('あ', 31)), 'gf_too_long', '30 文字まで');
select gf_set_card_title(:'card', '');
:as_admin
select t_ok((select title is null from gf_graffiti where id = :'card'), '空にすると名前なし（アプリは書いた人の名前を出す）');
