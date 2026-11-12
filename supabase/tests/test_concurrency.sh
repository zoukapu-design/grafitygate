#!/usr/bin/env bash
# 同時に 2 回書き込んでも、ルールが守られるか（run.sh から呼ぶ。test_core.sql のあとの状態を使う）
#  1) 同じ入場券で同時に 2 枚 → 1 枚だけ
#  2) 同じ人が別々の入場券で、同じ GATE に同時に 2 枚 → 12 時間のルールで 1 枚だけ
set -euo pipefail

carol='00000000-0000-0000-0000-00000000000c'
as_carol="do \$\$ begin perform set_config('request.jwt.claim.sub', '$carol', false); end \$\$; set role authenticated;"
q() { "$PSQL" -q -X -t -A -v ON_ERROR_STOP=1 -c "$1"; }

gate=$(q "select id from gf_gates where client_key = 'dave-gate-00001'")
enter() {
  q "$as_carol
     select gf_enter('$gate', (select challenge_id from gf_request_challenge()), 35.81, 139.72, 5,
                     array_fill(0.25::real, array[16]), 2) ->> 'visit_id'" | tail -1
}
post_slow() { # 書いてから 1.5 秒つかんだまま終える
  "$PSQL" -q -X -t -A -v ON_ERROR_STOP=1 <<SQL 2>&1
begin;
$as_carol
select gf_post_graffiti('$1', '$2', null, 'public', false);
select pg_sleep(1.5);
commit;
SQL
}
post() {
  "$PSQL" -q -X -t -A -v ON_ERROR_STOP=1 -c "$as_carol select gf_post_graffiti('$1', '$2', null, 'public', false)" 2>&1 || true
}

# 1) 同じ入場券で同時に 2 枚
v=$(enter)
post_slow "$v" 'A' > /tmp/gf_a.$$ &
sleep 0.4
out_b=$(post "$v" 'B')
wait
n=$(q "select count(*) from gf_graffiti where visit_id = '$v'")
if [ "$n" = "1" ] && echo "$out_b" | grep -q 'gf_already_posted'; then
  echo "  ok - 同じ入場券で同時に 2 枚送っても 1 枚だけ（もう 1 つは「もう書いた」と返る）"
else
  echo "  FAIL: 同じ入場券の同時書き込み（枚数 $n / 2 つ目の結果: $out_b）" >&2
  exit 1
fi

# 2) 別々の入場券で同時に 2 枚（12 時間のルール）
q "delete from gf_graffiti where author = '$carol'"
v1=$(enter)
v2=$(enter)
post_slow "$v1" 'C' > /tmp/gf_c.$$ &
sleep 0.4
out_d=$(post "$v2" 'D')
wait
n=$(q "select count(*) from gf_graffiti where author = '$carol' and gate_id = '$gate'")
if [ "$n" = "1" ] && echo "$out_d" | grep -q 'gf_repost_cooldown'; then
  echo "  ok - 別々の入場券で同時に送っても、12 時間のルールで 1 枚だけ"
else
  echo "  FAIL: 別々の入場券の同時書き込み（枚数 $n / 2 つ目の結果: $out_d）" >&2
  exit 1
fi
rm -f /tmp/gf_a.$$ /tmp/gf_c.$$
