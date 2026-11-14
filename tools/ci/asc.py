#!/usr/bin/env python3
"""App Store Connect の小さな道具（GitHub Actions から使う）。

  asc.py cleanup-dev-certs
      組み立てのたびに Apple 側に増える「CI が作った開発用の証明書」（名前に Created via API が入るもの）を取り消す。
      クラウドの Mac は毎回まっさらで鍵が残らないため、残った証明書があると署名で止まる。配布用の証明書は触らない。
  asc.py next-build-number BUNDLE_ID
      TestFlight にあるビルド番号の最大 + 1 を出す。取れなければ何も出さない（呼ぶ側が別の番号を使う）。
  asc.py check BUNDLE_ID
      鍵で App Store Connect につながるか・アプリが登録されているかを確かめ、GitHub の注記（タイトル「App Store Connect」）に出す。
      鍵の中身は出さない。
  asc.py crashes BUNDLE_ID [件数]
      TestFlight で落ちたときに「共有」された記録を読み、落ちた理由と、落ちた所の流れ（どの関数か）だけを注記に出す。
      公開リポジトリの注記はだれでも見られるので、メールアドレス・ひとこと・端末の識別子は出さない。

環境変数：ASC_KEY_PATH（.p8 の場所）、ASC_KEY_ID、ASC_ISSUER_ID
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import jwt
except ImportError:  # check で分かりやすく知らせる
    jwt = None

API = "https://api.appstoreconnect.apple.com"
_token = None


def request(method, path):
    global _token
    if _token is None:
        with open(os.environ["ASC_KEY_PATH"]) as f:
            key = f.read()
        now = int(time.time())
        _token = jwt.encode(
            {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
            key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
    req = urllib.request.Request(API + path, method=method, headers={"Authorization": "Bearer " + _token})
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read()
    return json.loads(body) if body else {}


def cleanup_dev_certs():
    query = urllib.parse.urlencode({"filter[certificateType]": "DEVELOPMENT,IOS_DEVELOPMENT", "limit": 200})
    removed = 0
    for cert in request("GET", "/v1/certificates?" + query).get("data", []):
        attrs = cert.get("attributes", {})
        label = "%s / %s" % (attrs.get("name") or "", attrs.get("displayName") or "")
        if "Created via API" in label:
            try:
                request("DELETE", "/v1/certificates/" + cert["id"])
                removed += 1
            except Exception as error:  # noqa: BLE001
                print("取り消せませんでした: %s" % error, file=sys.stderr)
    print("CI が作った開発用の証明書を %d 件取り消しました" % removed, file=sys.stderr)


def next_build_number(bundle_id):
    query = urllib.parse.urlencode({"filter[bundleId]": bundle_id, "limit": 20})
    apps = [a for a in request("GET", "/v1/apps?" + query).get("data", [])
            if a.get("attributes", {}).get("bundleId") == bundle_id]
    if not apps:
        print("App Store Connect にアプリがありません: %s" % bundle_id, file=sys.stderr)
        return
    query = urllib.parse.urlencode({"filter[app]": apps[0]["id"], "sort": "-uploadedDate", "limit": 50,
                                    "fields[builds]": "version"})
    numbers = []
    for build in request("GET", "/v1/builds?" + query).get("data", []):
        head = (build.get("attributes", {}).get("version") or "").split(".")[0]
        if head.isdigit():
            numbers.append(int(head))
    print(max(numbers) + 1 if numbers else 1)


def describe(error):
    """失敗の理由を、鍵の中身を出さずに短い言葉にする"""
    if isinstance(error, urllib.error.HTTPError):
        detail = ""
        try:
            errors = json.loads(error.read() or b"{}").get("errors") or []
            if errors:
                detail = "（%s）" % (errors[0].get("detail") or errors[0].get("title") or "")
        except Exception:  # noqa: BLE001
            pass
        if error.code == 401:
            return ("鍵が通りません（401）%s。ASC_KEY_ID・ASC_ISSUER_ID・ASC_KEY_P8 が同じ鍵の組か、"
                    "ASC_KEY_P8 に BEGIN〜END まで全部入っているかを確かめてください。" % detail)
        if error.code == 403 and "agreement" in detail.lower():
            return ("鍵は通りましたが、Apple の規約への同意が必要です（403）%s。アカウントの持ち主が "
                    "https://developer.apple.com/account と https://appstoreconnect.apple.com/business で、"
                    "新しい規約・契約に同意してください。" % detail)
        if error.code == 403:
            return "鍵の権限が足りません（403）%s。App Store Connect の鍵のアクセスを Admin にしてください。" % detail
        return "App Store Connect に断られました（%d）%s" % (error.code, detail)
    if isinstance(error, urllib.error.URLError):
        return "App Store Connect につながりませんでした（%s）" % error.reason
    name = type(error).__name__
    if "Key" in name or "Deserializ" in str(error) or "PEM" in str(error):
        return "ASC_KEY_P8 を鍵として読めませんでした（%s）。.p8 の中身を BEGIN〜END まで全部貼ってください。" % name
    return "%s: %s" % (name, str(error)[:200])


def check(bundle_id):
    def say(level, text):
        print("::%s title=App Store Connect::%s" % (level, text))

    if jwt is None:
        say("error", "pyjwt を入れられませんでした（組み立ての Mac の Python）。")
        return 1
    try:
        query = urllib.parse.urlencode({"filter[bundleId]": bundle_id, "limit": 20})
        apps = [a for a in request("GET", "/v1/apps?" + query).get("data", [])
                if a.get("attributes", {}).get("bundleId") == bundle_id]
    except Exception as error:  # noqa: BLE001
        say("error", describe(error))
        return 1
    if not apps:
        say("error", "鍵は通りましたが、App Store Connect に %s のアプリがまだありません。"
                     "「マイ App」→「＋」→「新規 App」でこのバンドル ID のアプリを作ってください。" % bundle_id)
        return 1
    say("notice", "つながりました（アプリ「%s」あり）" % apps[0].get("attributes", {}).get("name", ""))
    return 0


def _app_id(bundle_id):
    query = urllib.parse.urlencode({"filter[bundleId]": bundle_id, "limit": 20})
    apps = [a for a in request("GET", "/v1/apps?" + query).get("data", [])
            if a.get("attributes", {}).get("bundleId") == bundle_id]
    return apps[0]["id"] if apps else None


def _frames_text(frames, images, limit=40):
    lines = []
    for i, f in enumerate(frames[:limit]):
        image = ""
        idx = f.get("imageIndex")
        if isinstance(idx, int) and 0 <= idx < len(images):
            image = images[idx].get("name") or ""
        sym = f.get("symbol") or ("+0x%x" % f.get("imageOffset", 0))
        where = ""
        if f.get("sourceFile"):
            where = " (%s:%s)" % (f.get("sourceFile"), f.get("sourceLine", "?"))
        lines.append("%2d %-22s %s%s" % (i, image[:22], sym[:160], where))
    return lines


def condense(log):
    """落ちた記録（.ips の JSON か、昔の文字の形）から、理由と落ちた所の流れだけを取り出す"""
    log = log or ""
    out = []
    text = log.lstrip()
    if text.startswith("{"):
        first, _, rest = text.partition("\n")
        try:
            head = json.loads(first)
            body = json.loads(rest)
        except Exception:  # noqa: BLE001
            return log[:3000]
        out.append("版: %s (%s)  端末: %s  iOS: %s" % (
            head.get("app_version", "?"), head.get("build_version", "?"),
            body.get("modelCode", "?"), (body.get("osVersion") or {}).get("train", head.get("os_version", "?"))))
        exc = body.get("exception") or {}
        if exc:
            out.append("落ち方: %s %s %s" % (exc.get("type", ""), exc.get("signal", ""), exc.get("subtype", "")))
        term = body.get("termination") or {}
        if term:
            out.append("終わった理由: %s %s %s" % (term.get("namespace", ""), term.get("code", ""),
                                             " / ".join(term.get("reasons") or [])[:600]))
        asi = body.get("asi") or {}
        for k, v in asi.items():
            out.append("知らせ(%s): %s" % (k, " / ".join(v if isinstance(v, list) else [str(v)])[:800]))
        images = body.get("usedImages") or []
        leb = body.get("lastExceptionBacktrace") or []
        if leb:
            out.append("--- 最後の例外の流れ ---")
            out += _frames_text(leb, images)
        for t in body.get("threads") or []:
            if t.get("triggered"):
                out.append("--- 落ちた所（%s %s）---" % (t.get("queue", ""), t.get("name", "")))
                out += _frames_text(t.get("frames") or [], images)
                break
        return "\n".join(out)
    # 文字の形：大事な行と、落ちたスレッドの流れ
    keep = ("Version:", "Hardware Model:", "OS Version:", "Exception Type:", "Exception Codes:", "Exception Note:",
            "Termination Reason:", "Triggered by Thread:", "Crashed Thread:")
    lines = log.splitlines()
    out += [l for l in lines if l.startswith(keep)]
    grab = False
    count = 0
    for l in lines:
        if ("Crashed:" in l and l.startswith("Thread")) or l.startswith("Last Exception Backtrace") \
                or l.startswith("Application Specific Information"):
            grab = True
            count = 0
            out.append("--- " + l + " ---")
            continue
        if grab:
            if not l.strip() or count > 40:
                grab = False
                continue
            out.append(l)
            count += 1
    return "\n".join(out)


def crashes(bundle_id, limit=3):
    def note(title, text):
        print("::notice title=%s::%s" % (title, text.replace("%", "%25").replace("\r", "").replace("\n", "%0A")))

    try:
        app = _app_id(bundle_id)
        if not app:
            note("落ちた記録", "App Store Connect にアプリがありません")
            return 1
        query = urllib.parse.urlencode({"sort": "-createdDate", "limit": limit})
        subs = request("GET", "/v1/apps/%s/betaFeedbackCrashSubmissions?%s" % (app, query)).get("data", [])
    except Exception as error:  # noqa: BLE001
        note("落ちた記録", describe(error))
        return 1
    if not subs:
        note("落ちた記録", "共有された落ちた記録はまだありません（TestFlight の「共有」を押すと届きます）")
        return 0
    for n, sub in enumerate(subs, 1):
        attrs = sub.get("attributes", {})
        header = "届いた日時: %s  端末: %s  iOS: %s" % (attrs.get("createdDate", "?"), attrs.get("deviceModel", "?"),
                                                attrs.get("osVersion", "?"))
        try:
            log = request("GET", "/v1/betaFeedbackCrashSubmissions/%s/crashLog" % sub["id"])
            text = ((log.get("data") or {}).get("attributes") or {}).get("logText") or ""
            note("落ちた記録 %d" % n, header + "\n" + condense(text)[:6000])
        except Exception as error:  # noqa: BLE001
            note("落ちた記録 %d" % n, header + "\n記録を読めませんでした: " + describe(error))
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "crashes":
        sys.exit(crashes(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 3))
    if len(sys.argv) == 3 and sys.argv[1] == "check":
        sys.exit(check(sys.argv[2]))
    if len(sys.argv) == 2 and sys.argv[1] == "cleanup-dev-certs":
        cleanup_dev_certs()
    elif len(sys.argv) == 3 and sys.argv[1] == "next-build-number":
        next_build_number(sys.argv[2])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
