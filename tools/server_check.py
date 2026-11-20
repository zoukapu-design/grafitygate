#!/usr/bin/env python3
"""サーバーに、アプリが使う新しい関数がそろっているかを確かめる（.github/workflows/server-check.yml から呼ぶ）。

公開の鍵（anon）で、関数を空の値で呼ぶ。ログインしていないので、関数は中で断る（＝ある）。
関数が無いときだけ PostgREST が PGRST202（見つからない）を返す。鍵・アドレスは出さない。
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

# 確かめる関数（段ごとに 1 つ、その段で新しく足したもの）
CHECKS = [
    ("0025", "gf_leave_visit"),
    ("0026", "gf_set_card_finish"),
    ("0027", "gf_friend_feed2"),
    ("0028", "gf_set_door_style"),
    ("0029", "gf_set_card_title"),
    ("0030", "gf_write_letter2"),
    ("0031", "gf_add_memory_card"),
    ("0032", "gf_my_saved_cards2"),
    ("0033", "gf_enter2"),
]

ROOT = os.path.join(os.path.dirname(__file__), "..", "supabase", "migrations")


def params_of(name: str) -> list:
    """migrations の中で最後に作った形の、引数の名前"""
    found = None
    for fn in sorted(os.listdir(ROOT)):
        text = open(os.path.join(ROOT, fn), encoding="utf-8").read()
        for m in re.finditer(r"create or replace function public\." + re.escape(name) + r"\s*\((.*?)\)\s*returns",
                             text, re.S | re.I):
            found = m.group(1)
    if found is None:
        return []
    names = []
    for part in re.split(r",(?![^()]*\))", found):
        part = part.strip()
        if not part:
            continue
        names.append(part.split()[0])
    return names


def main() -> int:
    raw = os.environ.get("SUPABASE_URL", "").strip()
    key = os.environ.get("SUPABASE_ANON_KEY", "").strip()
    if not raw or not key:
        print("::warning title=サーバー::鍵がないので確かめられません（SUPABASE_URL・SUPABASE_ANON_KEY）")
        return 0
    u = urllib.parse.urlparse(raw if "://" in raw else "https://" + raw)
    base = f"https://{u.hostname}"
    missing = []
    for stage, name in CHECKS:
        body = json.dumps({p: None for p in params_of(name)}).encode()
        req = urllib.request.Request(f"{base}/rest/v1/rpc/{name}", data=body, method="POST",
                                     headers={"apikey": key, "Authorization": f"Bearer {key}",
                                              "Content-Type": "application/json"})
        code, text = 0, ""
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                code = r.status
        except urllib.error.HTTPError as e:
            code = e.code
            text = e.read().decode("utf-8", "replace")[:400]
        except Exception as e:  # noqa: BLE001
            print(f"::warning title=サーバー::{stage} {name}：つながりませんでした（{type(e).__name__}）")
            continue
        absent = code == 404 and "PGRST202" in text
        mark = "ない" if absent else "ある"
        print(f"{stage} {name}: {code} → {mark}")
        if absent:
            missing.append(stage)
    if missing:
        print(f"::warning title=サーバー::まだ入っていない段：{'・'.join(missing)}（supabase/setup_all.sql を貼り直す）")
    else:
        print("::notice title=サーバー::新しい関数はそろっています")
    return 0


if __name__ == "__main__":
    sys.exit(main())
