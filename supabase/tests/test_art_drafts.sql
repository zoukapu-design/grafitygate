-- AR の作品の下書きと「置き直しが必要」（0011）のテスト。前のテストのあとの状態を使う。run.sh から実行する。
\set ON_ERROR_STOP on

\set alice '00000000-0000-0000-0000-00000000000a'
\set bob   '00000000-0000-0000-0000-00000000000b'
\set as_alice 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000a'', false); end $$; set role authenticated;'
\set as_bob   'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', ''00000000-0000-0000-0000-00000000000b'', false); end $$; set role authenticated;'
\set as_admin 'reset role; do $$ begin perform set_config(''request.jwt.claim.sub'', '''', false); end $$;'

\echo '== AR の作品の下書きと置き直し'
:as_admin
delete from gf_rate;
select id as g4 from gf_gates where client_key = 'alice-gate-0101' \gset
select id as va from gf_visits where user_id = :'alice' and gate_id = :'g4' and expires_at > now() order by expires_at desc limit 1 \gset
select id as vb from gf_visits where user_id = :'bob' and gate_id = :'g4' and expires_at > now() order by expires_at desc limit 1 \gset

:as_bob
select gf_place_artwork3(:'vb', 'light', '', null, null, null, 'sky', 0.2, 1.4, 0.7, 0, 1, '[]'::jsonb, 'friends', 'draft') as bd \gset
select t_ok(:'bd' is not null, '下書きで作品を置ける');
:as_alice
select t_ok((select count(*) from gf_artworks where id = :'bd') = 0, '下書きは、ほかの人には見えない（GATE を作った人にも）');
select t_ok(not exists (select 1 from gf_my_notifications() where kind = 'gate_artwork' and actor = :'bob' and ref_id = :'bd'),
  '下書きを置いても、お知らせは届かない');
:as_bob
select t_ok((select status from gf_artworks where id = :'bd') = 'draft', '置いた本人には下書きが見える');
select gf_set_artwork_status(:'bd', 'published');
:as_alice
select t_ok((select count(*) from gf_artworks where id = :'bd') = 1, '公開すると、友達で入場中の人に見える');
select t_ok((select count(*) from gf_my_notifications() where kind = 'gate_artwork' and actor = :'bob' and ref_id = :'bd') = 1,
  '下書きを公開したときに、GATE を作った人へお知らせが届く');
:as_bob
select gf_set_artwork_status(:'bd', 'hidden');
select gf_set_artwork_status(:'bd', 'published');
:as_alice
select t_ok((select count(*) from gf_my_notifications() where kind = 'gate_artwork' and actor = :'bob' and ref_id = :'bd') = 1,
  '隠して出し直しても、お知らせは重ならない');
:as_bob
select t_throws(format('select gf_set_artwork_status(%L, %L)', :'bd', 'weird'), 'gf_bad_artwork', '決まっていない状態にはできない');
select t_throws(format('select gf_place_artwork3(%L, %L, %L, null, null, null, null, 0, 1, 0, 0, 1, null, null, %L)',
  :'vb', 'light', '', 'hidden'), 'gf_bad_artwork', '置くときは、公開か下書きだけ');

-- 下書きも上限に入る（1 人 1 つの GATE に 3 つまで）
:as_alice
select gf_place_artwork3(:'va', 'light', '', null, null, null, 'warm', 0, 1.2, 0.5, 0, 1, '[]'::jsonb, 'friends', 'draft') as ad \gset
select t_ok(:'ad' is not null, '自分の下書きを置ける');
select gf_place_artwork3(:'va', 'light', '', null, null, null, 'white', 0.1, 1.0, 0.4, 0, 1, '[]'::jsonb, 'friends', 'draft')
from generate_series(1, greatest(0, 3 - (select count(*) from gf_artworks where gate_id = :'g4' and owner = :'alice'
                                         and status in ('published', 'draft'))::int));
select t_throws(format('select gf_place_artwork3(%L, %L, %L, null, null, null, null, 0, 1, 0, 0, 1, null, null, %L)',
  :'va', 'light', '', 'draft'), 'gf_artwork_limit', '下書きも 1 人 3 つの上限に入る');

-- 場所の記憶を撮り直すと「置き直しが必要」（隠している作品には付けない）
:as_bob
select gf_set_artwork_status(:'bd', 'hidden');
:as_alice
select gf_register_place_map(:'g4', :'alice' || '/g4-a.worldmap', 1000, 'gg.gate');
select gf_register_place_map(:'g4', :'alice' || '/g4-b.worldmap', 1200, 'gg.gate');
select t_ok((select bool_and(needs_replace) from gf_artworks where gate_id = :'g4' and status <> 'hidden'),
  '場所の記憶を撮り直すと、その GATE の作品に「置き直しが必要」が付く');
:as_bob
select t_ok(not (select needs_replace from gf_artworks where id = :'bd'), '隠している作品には付けない');
:as_alice
select gf_keep_artwork_place(:'ad');
select t_ok(not (select needs_replace from gf_artworks where id = :'ad'), '「このままでよい」で外せる');
:as_bob
select t_throws(format('select gf_keep_artwork_place(%L)', :'ad'), 'gf_not_found', 'ほかの人の作品の印は外せない');
:as_alice
select id as am, revision as ar from gf_artworks where gate_id = :'g4' and owner = :'alice' and needs_replace limit 1 \gset
select gf_move_artwork(:'am', :'va', 0.3, 1.3, 0.6, 0, 1, :ar);
select t_ok(not (select needs_replace from gf_artworks where id = :'am'), '置き直すと「置き直しが必要」が外れる');
reset role;
\echo '== AR の作品の下書きと置き直し：すべて通りました'
