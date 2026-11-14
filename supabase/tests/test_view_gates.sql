-- 景色の GATE と、見え方を足す仕組み（0015）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'
-- 展望台（ほかのテストの GATE と離れた所）
\set vlat 35.83000
\set vlon 139.75000
\set vlat50  35.83045
\set vlat130 35.83117
\set day   'array_fill(0.25::real, array[16])'
\set night 'array_fill(0.90::real, array[16])'

\echo '== 景色の GATE'
:as_admin
delete from gf_rate;
:as_alice
select challenge_id as c from gf_request_challenge() \gset
select gf_create_gate('view-gate-0001', :'c', '夕焼けの見える丘', '', 'view', :vlat, :vlon, 8, 270, 'public', null,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:day), 'rev', 2))) as vg \gset
select t_ok((select kind from gf_gates where id = :'vg') = 'view', '種類「景色」で GATE を作れる');
select challenge_id as c from gf_request_challenge() \gset
select t_throws(format('select gf_create_gate(%L, %L, %L, %L, %L, %s, %s, 8, null, %L, null, %L::jsonb)',
  'view-gate-0002', :'c', '山', '', 'mountain', :vlat, :vlon, 'public',
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:day), 'rev', 2))), 'gf_gates_kind_check',
  '決まっていない種類では作れない');
select t_ok((gf_gate_ref_count(:'vg') ->> 'count')::int = 1 and (gf_gate_ref_count(:'vg') ->> 'max')::int = 12,
  '作った本人は見本の数と上限を見られる');

\echo '== 夜は昼の見本と合わない → 作った本人が夜の見え方を足すと入れる'
:as_bob
select t_throws(format('select gf_gate_ref_count(%L)', :'vg'), 'gf_not_found', 'ほかの人は見本の数を見られない');
select challenge_id as c from gf_request_challenge() \gset
select t_ok((gf_enter(:'vg', :'c', :vlat50, :vlon, 10, :night, 2) ->> 'reason') = 'no_match',
  '昼に作った景色に、夜の写真では入れない');
select challenge_id as c from gf_request_challenge() \gset
select t_throws(format('select gf_add_gate_refs(%L, %L, %s, %s, 10, %L::jsonb)', :'vg', :'c', :vlat50, :vlon,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:night), 'rev', 2))), 'gf_not_found',
  'ほかの人は見本を足せない');

:as_alice
select challenge_id as c from gf_request_challenge() \gset
select t_throws(format('select gf_add_gate_refs(%L, %L, %s, %s, 10, %L::jsonb)', :'vg', :'c', :vlat130, :vlon,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:night), 'rev', 2))), 'gf_too_far',
  '遠くからは足せない（その場から 120m 以内）');
select challenge_id as c from gf_request_challenge() \gset
select t_throws(format('select gf_add_gate_refs(%L, %L, %s, %s, 40, %L::jsonb)', :'vg', :'c', :vlat50, :vlon,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:night), 'rev', 2))), 'gf_inaccurate',
  '位置の精度が粗いと足せない');
select challenge_id as c from gf_request_challenge() \gset
select t_throws(format('select gf_add_gate_refs(%L, %L, %s, %s, 10, %L::jsonb)', :'vg', :'c', :vlat50, :vlon, '[]'),
  'gf_bad_references', '空では足せない');
select challenge_id as c from gf_request_challenge() \gset
select t_ok(gf_add_gate_refs(:'vg', :'c', :vlat50, :vlon, 10,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:night), 'rev', 2))) = 2, '作った本人は現地で夜の見え方を足せる');
select t_throws(format('select gf_add_gate_refs(%L, %L, %s, %s, 10, %L::jsonb)', :'vg', :'c', :vlat50, :vlon,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:night), 'rev', 2))), 'gf_challenge_used',
  '同じ合言葉では 2 回足せない');
:as_admin
select t_ok((select photo_path from gf_gate_refs where gate_id = :'vg' order by created_at desc limit 1) is null,
  '足した見本は特徴だけ（写真は持たない）');

:as_bob
select challenge_id as c from gf_request_challenge() \gset
select t_ok((gf_enter(:'vg', :'c', :vlat50, :vlon, 10, :night, 2) ->> 'ok')::boolean,
  '夜の見え方を足したあとは、夜の写真でも入れる');

\echo '== 見本は 12 まで'
:as_admin
delete from gf_rate;
:as_alice
do $$
declare i int; c uuid;
begin
  for i in 1..3 loop
    select challenge_id into c from gf_request_challenge();
    perform gf_add_gate_refs((select id from gf_gates where client_key = 'view-gate-0001'), c, 35.83045, 139.75000, 10,
      jsonb_build_array(jsonb_build_object('print', to_jsonb(array_fill((0.3 + i * 0.05)::real, array[16])), 'rev', 2),
                        jsonb_build_object('print', to_jsonb(array_fill((0.31 + i * 0.05)::real, array[16])), 'rev', 2),
                        jsonb_build_object('print', to_jsonb(array_fill((0.32 + i * 0.05)::real, array[16])), 'rev', 2)));
  end loop;
end $$;
select t_ok((gf_gate_ref_count(:'vg') ->> 'count')::int = 11, '足して 11 枚');
select challenge_id as c from gf_request_challenge() \gset
select t_throws(format('select gf_add_gate_refs(%L, %L, %s, %s, 10, %L::jsonb)', :'vg', :'c', :vlat50, :vlon,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:night), 'rev', 2),
                    jsonb_build_object('print', to_jsonb(:day), 'rev', 2))), 'gf_too_many_refs',
  '12 を超えては足せない');
:as_admin
delete from gf_rate;
