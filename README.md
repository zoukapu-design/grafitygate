# GRAFITYGATE

**場所に、記憶の扉を。**

現実の場所や物に、写真・言葉・声・映像・AR の作品を残せる iPhone アプリです。
友達がその場所を訪れたとき、または数年後の自分が戻ってきたとき、残された GATE（記憶の扉）に出会えます。

## いまできること（段階 1 の途中）

- 目の前の場所・物を写して、新しい GATE を作る（位置と、写真の特徴の両方で場所を確かめる）
- 100m 以内の GATE を地図で見つける
- 現地で写して GATE に入る（120m 以内・写真が合うと 20 分）
- 入場中にグラフィティ（ひとこと）を 1 枚残す。同じ GATE には 12 時間あけて
- 友達（お互いにフォロー）の新着を 24 時間見る。中身は現地で入ったときだけ

写真そのものはサーバーに送らず、写真から作った「特徴」（数の並び）と位置だけを送ります。

## フォルダ

| 場所 | 中身 |
| --- | --- |
| `App/` | iPhone アプリ（SwiftUI・iOS 17 以上）。`project.yml` から XcodeGen で Xcode のプロジェクトを作る |
| `supabase/migrations/` | サーバー（Supabase）の表とルール。SQL Editor に貼って実行する |
| `supabase/tests/` | サーバーのルールのテスト（`bash supabase/tests/run.sh`。PostgreSQL が要る） |
| `.github/workflows/ios.yml` | GitHub のクラウド Mac での組み立てと、TestFlight への送信 |
| `docs/SETUP.md` | はじめて動かすときの準備 |

## 組み立て

Mac は要りません。`main` に push すると GitHub Actions が、サーバーのルールのテストと、署名なしの組み立てを行います。
TestFlight に送るときは、Actions の「iOS」→「Run workflow」で「TestFlight に送る」を選びます（準備は `docs/SETUP.md`）。

## ライセンス

まだ決めていません。公開していますが、利用・改変・再配布の許可はしていません。
