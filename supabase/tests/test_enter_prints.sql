-- 写真で GATE を開けやすくする（0033）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'
\set same 'array_fill(0.25::real, array[16])'
\set far  'array[1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]::real[]'
-- 見本から 0.78 だけ離れた特徴（前のしきい値 0.75 では入れなかった）
\set close 'array[1.03,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25]::real[]'

\echo '== 写真で GATE を開けやすくする'
:as_admin
delete from gf_rate;
select t_ok(gf_setting('match_max_distance') = 0.8, 'しきい値は 0.8（前の 0.75 から）');
:as_alice
select challenge_id as c from gf_request_challenge() \gset
select gf_create_gate('prints-gate-0001', :'c', '水槽の前', '', 'object', 35.97, 139.67, 6, null, 'public', null,
  jsonb_build_array(jsonb_build_object('print', to_jsonb(:same), 'rev', 2))) as pg \gset

:as_bob
select challenge_id as c from gf_request_challenge() \gset
select t_ok((gf_enter2(:'pg', :'c', 35.97, 139.67, 5, jsonb_build_array(to_jsonb(:far), to_jsonb(:far)), 2) ->> 'reason') = 'no_match',
  'どの特徴も合わなければ入れない');
select challenge_id as c from gf_request_challenge() \gset
select t_ok((gf_enter2(:'pg', :'c', 35.97, 139.67, 5, jsonb_build_array(to_jsonb(:far), to_jsonb(:same)), 2) ->> 'ok')::boolean,
  '送った特徴のどれか 1 つが合えば入れる（いちばん近いもので判定）');
select challenge_id as c from gf_request_challenge() \gset
select t_ok((gf_enter2(:'pg', :'c', 35.97, 139.67, 5, jsonb_build_array(to_jsonb(:close)), 2) ->> 'ok')::boolean,
  '少しちがう見え方（距離 0.78）でも入れる');
select challenge_id as c from gf_request_challenge() \gset
select t_ok((gf_enter2(:'pg', :'c', 35.97, 139.67 + 0.01, 5, jsonb_build_array(to_jsonb(:same)), 2) ->> 'reason') = 'too_far',
  '写真が合っても、遠ければ入れない（写真だけでは入れない）');
select challenge_id as c from gf_request_challenge() \gset
select t_throws(format('select gf_enter2(%L, %L, 35.97, 139.67, 5, (select jsonb_agg(to_jsonb(array_fill(0.25::real, array[16]))) from generate_series(1, 13)), 2)',
  :'pg', :'c'), 'gf_bad_prints', '特徴は 12 まで');
:as_admin
select t_ok((select used_at is null from gf_challenges where id = :'c'), '送りすぎで断ったときは、合言葉を使わない');
:as_bob
select t_ok((gf_enter2(:'pg', :'c', 35.97, 139.67, 5, '[]'::jsonb, 2) ->> 'reason') = 'no_reference',
  '特徴が 1 つも無ければ、見本と比べられない');
select challenge_id as c from gf_request_challenge() \gset
select t_ok((gf_enter(:'pg', :'c', 35.97, 139.67, 5, :same, 2) ->> 'ok')::boolean, '前の形（1 枚だけ）でも入れる（古いアプリ）');
select t_ok((select count(*) from gf_match_candidates2(35.97, 139.67, jsonb_build_array(to_jsonb(:far), to_jsonb(:close)), 2)
             where id = :'pg' and similarity = 'strong') = 1, '候補も、送った特徴のいちばん近いもので「似ている」になる');
select t_ok((select count(*) from gf_match_candidates(35.97, 139.67, :far, 2) where id = :'pg' and similarity <> 'strong') = 1,
  '前の形の候補も動く');

:as_admin
select t_ok((select prints from gf_enter_attempts where gate_id = :'pg' and result = 'ok' order by id limit 1) = 2,
  '何枚の特徴を送ったかが記録に残る');
select t_ok((select count(*) from gf_enter_attempts where gate_id = :'pg' and result = 'no_match' and match_distance > 0.8) = 1,
  '合わなかったときも、いちばん近い距離が記録に残る');
:as_bob
select t_throws('select * from gf_parse_prints(''[]''::jsonb)', 'permission denied', '特徴を読む内部の関数は、アプリから直接は呼べない');
