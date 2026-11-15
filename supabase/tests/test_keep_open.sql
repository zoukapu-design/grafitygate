-- 扉は、その場にいるあいだ開いたまま（0021）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set bob   '00000000-0000-0000-0000-00000000000b'
\set carol '00000000-0000-0000-0000-00000000000c'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_carol 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000c'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'
\set vlat50 35.83045
\set vlon 139.75000
\set day 'array_fill(0.25::real, array[16])'

\echo '== 扉は、その場にいるあいだ開いたまま'
:as_admin
delete from gf_rate;
select id as vg, lat as glat, lon as glon from gf_gates where client_key = 'view-gate-0001' \gset
:as_bob
select challenge_id as c from gf_request_challenge() \gset
select (gf_enter(:'vg', :'c', :vlat50, :vlon, 10, :day, 2) ->> 'visit_id') as vb \gset
:as_admin
-- 20 分のうち 18 分たったことにする（残り 2 分）
update gf_visits set expires_at = now() + interval '2 minutes' where id = :'vb';
:as_bob
select t_ok((gf_keep_open(:'vb', :glat, :glon, 10) ->> 'near')::boolean, 'GATE のそばにいれば「近い」');
:as_admin
select t_ok((select expires_at > now() + interval '4 minutes' from gf_visits where id = :'vb'),
  'そばにいるあいだは、閉じる時刻が 5 分先まで延びる');
:as_bob
select t_ok(gf_keep_open(:'vb', :glat, :glon, 300) -> 'near' = 'null'::jsonb, '位置が不確かなときは、延ばしも閉じもしない');
select t_ok(not (gf_keep_open(:'vb', :glat + 0.01, :glon, 10) ->> 'near')::boolean, '1km 離れると「離れた」');
:as_admin
select t_ok((select expires_at <= now() + interval '2 minutes' from gf_visits where id = :'vb'),
  'はっきり離れたら、2 分で閉じる');
:as_carol
select t_ok(not (gf_keep_open(:'vb', :glat, :glon, 10) ->> 'open')::boolean, 'ほかの人の扉は延ばせない');
:as_admin
update gf_visits set expires_at = now() - interval '1 minute' where id = :'vb';
:as_bob
select t_ok(not (gf_keep_open(:'vb', :glat, :glon, 10) ->> 'open')::boolean, '閉じた扉は、位置を送っても開かない（開け直す）');

:as_admin
update gf_visits set expires_at = now() - interval '1 minute' where gate_id = :'vg';
delete from gf_rate;
