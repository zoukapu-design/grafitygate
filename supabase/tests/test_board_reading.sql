-- グラフィティボードで読めるもの（0024）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
-- ・一度扉を開けた GATE は、遠くからもグラフィティカードと掲示板を読める（書く・保存・返信・いいねは扉の中だけ）
-- ・まだ開けたことのない人には、新しいカード 3 枚と掲示板の題名だけ（チラ見せ）
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'

\echo '== 準備：アリスの景色の GATE に、新しいカード 4 枚と「この GATE の中だけ」のカード、掲示板の話題'
:as_admin
delete from gf_rate;
select id as vg, visibility as vg_vis from gf_gates where client_key = 'view-gate-0001' \gset
update gf_gates set visibility = 'public' where id = :'vg';
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'vg';
-- キャロルは「まだ開けたことのない人」にする（このテストのあいだだけ、入場を取り消しにしておく）
create temp table t_carol_revoked as
  select id from gf_visits where gate_id = :'vg' and user_id = :'carol' and revoked_at is null;
update gf_visits set revoked_at = now() where id in (select id from t_carol_revoked);
insert into gf_graffiti (gate_id, author, body, photo_path, visibility, created_at)
  values (:'vg', :'alice', 'いちばん古い', :'alice' || '/peek-old.jpg', 'public', now() - interval '1 day') returning id as p_old \gset
insert into gf_graffiti (gate_id, author, body, photo_path, visibility, created_at)
  values (:'vg', :'alice', '新しい A', :'alice' || '/peek-a.jpg', 'public', now() - interval '3 minutes') returning id as p_a \gset
insert into gf_graffiti (gate_id, author, body, visibility, created_at)
  values (:'vg', :'alice', '新しい B', 'public', now() - interval '2 minutes') returning id as p_b \gset
insert into gf_graffiti (gate_id, author, body, visibility, created_at)
  values (:'vg', :'alice', '新しい C', 'public', now() - interval '1 minute') returning id as p_c \gset
insert into gf_graffiti (gate_id, author, body, photo_path, visibility, local_only)
  values (:'vg', :'alice', 'ここだけの話', :'alice' || '/peek-local.jpg', 'public', true) returning id as p_local \gset
insert into gf_board_threads (gate_id, author, topic, title, body)
  values (:'vg', :'alice', 'question', 'ベンチはいつからある？', '本文はチラ見せに出さない') returning id as th \gset

\echo '== まだ開けたことのない人：チラ見せだけ'
:as_carol
select t_ok(not (gf_gate_peek(:'vg') ->> 'opened')::boolean, 'まだ扉を開けたことがない');
select t_ok((select array_agg(e ->> 'id' order by e ->> 'body') from jsonb_array_elements(gf_gate_peek(:'vg') -> 'cards') e)
            = array[:'p_a', :'p_b', :'p_c'], 'チラ見せは新しい 3 枚（「この GATE の中だけ」は出ない）');
select t_ok(exists (select 1 from jsonb_array_elements(gf_gate_peek(:'vg') -> 'threads') e
                    where e ->> 'title' = 'ベンチはいつからある？' and not e ? 'body'),
  '掲示板は題名だけ（本文は出さない）');
select t_ok(gf_can_read_media(:'alice' || '/peek-a.jpg'), 'チラ見せのカードの写真は受け取れる');
select t_ok(not gf_can_read_media(:'alice' || '/peek-old.jpg'), 'チラ見せに出ていない古いカードの写真は受け取れない');
select t_ok(not gf_can_read_media(:'alice' || '/peek-local.jpg'), '「この GATE の中だけ」のカードの写真は受け取れない');
select t_ok((select count(*) from gf_graffiti where id = :'p_old') = 0, '古いカードは読めない');
select t_ok((select count(*) from gf_board_list(:'vg') where id = :'th') = 0, '掲示板の本文は読めない');
select t_throws(format('select * from gf_board_replies_of(%L)', :'th'), 'gf_not_found', '掲示板の返信は読めない');
select gf_report('graffiti', :'p_a', 'spam', 'チラ見せのカード');
select gf_report('thread', :'th', 'spam', 'チラ見せの題名');
select t_throws(format('select gf_report(%L, %L, %L, null)', 'graffiti', :'p_old', 'spam'), 'gf_not_found',
  'チラ見せに出ていないカードは通報できない（見えていない）');
:as_admin
select t_ok((select count(*) from gf_reports where reporter = :'carol' and target_id in (:'p_a', :'th')) = 2,
  'チラ見せのカードと話題の題名は通報できる');
delete from gf_reports where reporter = :'carol' and target_id in (:'p_a', :'th');
delete from gf_rate;

\echo '== 一度扉を開けた人：遠くからも読める（書く・保存・返信・いいねは扉の中だけ）'
:as_bob
select t_ok((gf_gate_peek(:'vg') ->> 'opened')::boolean, '前に扉を開けたことがある');
select t_ok(not (gf_gate_peek(:'vg') ->> 'inside')::boolean, 'いまは扉の外');
select t_ok((select count(*) from gf_graffiti where id in (:'p_old', :'p_a', :'p_b', :'p_c')) = 4,
  '古いカードも全部読める');
select t_ok((select count(*) from gf_graffiti where id = :'p_local') = 0, '「この GATE の中だけ」のカードは読めない');
select t_ok(gf_can_read_media(:'alice' || '/peek-old.jpg'), '古いカードの写真も受け取れる');
select t_ok(not gf_can_read_media(:'alice' || '/peek-local.jpg'), '「この GATE の中だけ」のカードの写真は受け取れない');
select t_ok((select body from gf_board_list(:'vg') where id = :'th') = '本文はチラ見せに出さない', '掲示板の本文も読める');
select t_ok((select count(*) >= 0 from gf_board_replies_of(:'th')), '掲示板の返信も読める');
select t_throws(format('insert into gf_reactions (graffiti_id, user_id) values (%L, %L)', :'p_old', :'bob'),
  'row-level security', '扉の外からはいいねできない');
select t_throws(format('select gf_save_card(%L, true)', :'p_old'), 'gf_not_found', '扉の外からは保存できない');
select t_throws(format('select gf_card_comment(%L, %L)', :'p_old', '遠くから'), 'gf_not_found', '扉の外からは返信できない');
select gf_report('graffiti', :'p_old', 'spam', 'テスト');
:as_admin
select t_ok(exists (select 1 from gf_reports where target_id = :'p_old' and reporter = :'bob'), '遠くから読めるカードは通報できる');

\echo '== 閉じた GATE・ブロックの相手'
update gf_gates set status = 'closed' where id = :'vg';
:as_bob
select t_ok((select count(*) from gf_graffiti where id = :'p_old') = 0, 'GATE が閉じたら、遠くからは読めない');
select t_throws(format('select gf_gate_peek(%L)', :'vg'), 'gf_not_found', '閉じた GATE のチラ見せは出ない');
:as_admin
update gf_gates set status = 'open' where id = :'vg';
insert into lp_blocks values (:'bob', :'alice') on conflict do nothing;
:as_bob
select t_ok((select count(*) from gf_graffiti where id = :'p_old') = 0, 'ブロックした相手のカードは読めない');
:as_admin
delete from lp_blocks where blocker = :'bob' and blocked = :'alice';

\echo '== 後かたづけ'
update gf_graffiti set deleted_at = now() where id in (:'p_old', :'p_a', :'p_b', :'p_c', :'p_local');
update gf_board_threads set deleted_at = now() where id = :'th';
update gf_visits set revoked_at = null where id in (select id from t_carol_revoked);
update gf_gates set visibility = :'vg_vis' where id = :'vg';
delete from gf_reports where target_id = :'p_old';
delete from gf_rate;
