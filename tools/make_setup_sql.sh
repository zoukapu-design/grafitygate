#!/usr/bin/env bash
# supabase/migrations/*.sql を番号の順につないで、1 回貼るだけで済む supabase/setup_all.sql を作る。
# migrations を変えたら、これを実行して setup_all.sql も一緒に保存する（テストで食い違いを確かめる）。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/supabase/setup_all.sql}"
{
  echo "-- Grafity Gate のサーバーの準備（migrations をすべて番号の順につないだもの）。"
  echo "-- Supabase の SQL Editor に全部貼って Run。何度実行しても大丈夫。"
  echo "-- このファイルは tools/make_setup_sql.sh で作る（直接書き換えない）。"
  for f in "$root"/supabase/migrations/*.sql; do
    echo
    echo "-- ======================================================================"
    echo "-- $(basename "$f")"
    echo "-- ======================================================================"
    cat "$f"
  done
} > "$out"
echo "作りました：$out"
