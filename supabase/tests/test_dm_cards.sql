-- グラフィティカードを友達に送る（0022）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'

\echo '== グラフィティカードを友達に送る'
:as_admin
delete from gf_rate;
select id as vg from gf_gates where client_key = 'view-gate-0001' \gset
select id as ca, photo_path as ca_photo from gf_graffiti where author = :'alice' and gate_id = :'vg' and deleted_at is null
  order by created_at desc limit 1 \gset
select id as cb from gf_graffiti where author <> :'alice' and deleted_at is null limit 1 \gset
update gf_graffiti set in_atlas = false, local_only = true where id = :'ca';
delete from gf_card_saves where graffiti_id = :'ca';
delete from gf_card_nearby_passes;
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'vg';
:as_bob
select t_ok(not gf_can_read_media(:'ca_photo'), '送られる前は、カードの写真を受け取れない');
:as_alice
select gf_dm_send_card(:'bob', :'ca', 'ここに来たよ') as dm \gset
select t_throws(format('select gf_dm_send_card(%L, %L, %L)', :'bob', :'cb', ''), 'gf_not_found',
  'ほかの人のカードは送れない');
select t_throws(format('select gf_dm_send_card(%L, %L, %L)', :'carol', :'ca', ''), 'gf_bad_recipient',
  'お互いにフォローしていない人には送れない');
:as_bob
select t_ok((select card_id = :'ca' and card_photo = :'ca_photo' and card_gate_id = :'vg' and not card_gone
             from gf_dm_messages_with3(:'alice') where id = :'dm'), '受け取った人に、カードの写真・GATE が届く');
select t_ok(gf_can_read_media(:'ca_photo'), '受け取った人は、カードの写真を見られる（「この GATE の中だけ」でも、書いた本人が送ったので）');
select t_ok((select last_kind = 'card' from gf_dm_threads2() where other = :'alice'), '相手の一覧に「カード」と出る');
:as_carol
select t_ok(not gf_can_read_media(:'ca_photo'), 'ほかの人は写真を見られない');
:as_admin
update gf_graffiti set deleted_at = now() where id = :'ca';
:as_bob
select t_ok((select card_gone and card_id is null and card_photo is null from gf_dm_messages_with3(:'alice') where id = :'dm'),
  '書いた人がカードを消すと、送ったカードも見えなくなる');
select t_ok(not gf_can_read_media(:'ca_photo'), '消したカードの写真は見られない');
:as_admin
update gf_graffiti set deleted_at = null, local_only = false where id = :'ca';
delete from gf_rate;
