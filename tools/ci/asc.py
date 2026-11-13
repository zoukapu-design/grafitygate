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


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "check":
        sys.exit(check(sys.argv[2]))
    if len(sys.argv) == 2 and sys.argv[1] == "cleanup-dev-certs":
        cleanup_dev_certs()
    elif len(sys.argv) == 3 and sys.argv[1] == "next-build-number":
        next_build_number(sys.argv[2])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
