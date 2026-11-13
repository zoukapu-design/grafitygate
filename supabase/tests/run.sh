#!/usr/bin/env bash
# gf_ の SQL を、手元の PostgreSQL で確かめる。
# Supabase に似せた環境（ログインの役割・auth.uid()・写真の置き場所・共有の表）を一時的に作り、
# migrations を 2 回ずつ流して（何度実行しても大丈夫か）、test_core.sql と同時に書き込むテストを動かす。
#
# 使い方：bash supabase/tests/run.sh
#   PostgreSQL 14 以上の initdb / pg_ctl / psql が要る（GitHub Actions の Ubuntu には入っている）。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

# root では PostgreSQL を起動できないので、postgres ユーザーで動かし直す
if [ "$(id -u)" = "0" ]; then
  exec su postgres -s /bin/bash -c "bash '$here/run.sh'"
fi

bin="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
if [ -z "$bin" ] || [ ! -x "$bin/initdb" ]; then
  echo "PostgreSQL が見つかりません（PG_BIN で場所を指定できます）" >&2
  exit 2
fi

work="$(mktemp -d)"
cleanup() {
  "$bin/pg_ctl" -D "$work/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

"$bin/initdb" -D "$work/data" -U postgres --auth=trust >/dev/null
"$bin/pg_ctl" -D "$work/data" -o "-k $work -c listen_addresses=''" -l "$work/log" -w start >/dev/null
export PGHOST="$work" PGUSER=postgres PGDATABASE=postgres
export PSQL="$bin/psql"
# 「もうあるので飛ばします」などのお知らせは出さない（テストの ok は NOTICE で出すので、test_core だけ戻す）
export PGOPTIONS='-c client_min_messages=warning'

run_sql() { "$PSQL" -q -X -v ON_ERROR_STOP=1 -f "$1" >/dev/null; }

run_sql "$here/stub_supabase.sql"
run_sql "$here/stub_shared.sql"
for pass in 1 2; do
  for f in "$root"/supabase/migrations/*.sql; do
    run_sql "$f"
  done
done
echo "migrations: 2 回流して、どちらもエラーなし"

# 1 回で貼る用の setup_all.sql が migrations と食い違っていないか（作り直して比べる）
bash "$root/tools/make_setup_sql.sh" "$work/setup_all.sql" >/dev/null
if ! cmp -s "$work/setup_all.sql" "$root/supabase/setup_all.sql"; then
  echo "supabase/setup_all.sql が古いままです。bash tools/make_setup_sql.sh を実行して保存してください" >&2
  exit 1
fi
# setup_all.sql そのものも、もう一度流してエラーにならないこと
run_sql "$root/supabase/setup_all.sql"
echo "setup_all.sql：migrations と同じで、流してもエラーなし"

# NOTICE（ok - …）だけを見やすく出す。失敗すると FAIL の行で止まる。
set +e
PGOPTIONS='-c client_min_messages=notice' "$PSQL" -q -X -t -A -v ON_ERROR_STOP=1 -f "$here/test_core.sql" 2>&1 \
  | sed -n -e 's/^psql:[^:]*:[0-9]*: NOTICE:  /  /p' -e 's/^psql:[^:]*:[0-9]*: ERROR:  /  ERROR: /p' -e '/^== /p'
status=${PIPESTATUS[0]}
set -e
if [ "$status" != "0" ]; then
  echo "test_core.sql が失敗しました" >&2
  exit 1
fi

bash "$here/test_concurrency.sh"

for t in test_maps test_artworks test_inside test_social test_trails test_investigations test_place_health test_memory_media; do
  set +e
  PGOPTIONS='-c client_min_messages=notice' "$PSQL" -q -X -t -A -v ON_ERROR_STOP=1 -f "$here/$t.sql" 2>&1 \
    | sed -n -e 's/^psql:[^:]*:[0-9]*: NOTICE:  /  /p' -e 's/^psql:[^:]*:[0-9]*: ERROR:  /  ERROR: /p' -e '/^== /p'
  status=${PIPESTATUS[0]}
  set -e
  if [ "$status" != "0" ]; then
    echo "$t.sql が失敗しました" >&2
    exit 1
  fi
done
# データが入ったあとに setup_all.sql を貼り直しても、エラーにならないこと（オーナーが新しい版を貼り直すときと同じ）
PGOPTIONS='-c client_min_messages=warning' run_sql "$root/supabase/setup_all.sql"
echo "データが入ったあとに setup_all.sql を貼り直しても、エラーなし"
echo "すべてのテストが通りました"
