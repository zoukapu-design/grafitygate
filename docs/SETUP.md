# はじめて動かすときの準備

順番にやると、iPhone（TestFlight）で GRAFITYGATE を試せるようになります。

## 1. Supabase にサーバーのルールを入れる

1. [Supabase のプロジェクト一覧](https://supabase.com/dashboard/projects) を開き、Lyric Path と同じプロジェクトを選ぶ
2. 左の **SQL Editor** を開き、**New query** を押す
3. [0001_gf_core.sql](https://github.com/zoukapu-design/grafitygate/blob/main/supabase/migrations/0001_gf_core.sql) を開き、右上の「Copy raw file」で中身を全部コピーして貼る
4. **Run** を押す（何度実行しても大丈夫です）

前提：Lyric Path の SQL（`profiles`・`follows`・`lp_blocks` を作るもの）がもう入っていること。
**Authentication → Sign In / Providers** で「Allow anonymous sign-ins」が入っていること（Lyric Path と同じ設定）。

## 2. アプリの ID と、App Store Connect のアプリを作る

1. [Identifiers](https://developer.apple.com/account/resources/identifiers/list) で「＋」→ App IDs → App →
   Description に `GRAFITYGATE`、Bundle ID（Explicit）に `com.zoukapu.grafitygate` を入れて登録
2. [App Store Connect のアプリ一覧](https://appstoreconnect.apple.com/apps) で「＋」→「新規 App」→
   プラットフォーム iOS、名前 `GRAFITYGATE`、言語 日本語、バンドル ID は上で作ったもの、SKU は `grafitygate` などで作成

## 3. GitHub の Secrets に鍵を入れる

[このリポジトリの Secrets の画面](https://github.com/zoukapu-design/grafitygate/settings/secrets/actions) で
「New repository secret」を押し、次の 6 つを入れます（Lyric Path で使っているものと同じ値で大丈夫です）。

| 名前 | 入れるもの |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer のチーム ID（10 桁） |
| `ASC_KEY_ID` | App Store Connect API キーの Key ID |
| `ASC_ISSUER_ID` | App Store Connect API の Issuer ID |
| `ASC_KEY_P8` | API キーの .p8 ファイルの中身（`-----BEGIN PRIVATE KEY-----` から `-----END PRIVATE KEY-----` まで全部） |
| `SUPABASE_URL` | Supabase のプロジェクト URL（`https://…supabase.co`） |
| `SUPABASE_ANON_KEY` | Supabase の anon キー |

値は [Supabase の API の設定](https://supabase.com/dashboard/project/_/settings/api) と
[App Store Connect の API キー](https://appstoreconnect.apple.com/access/integrations/api) で確かめられます。

## 4. TestFlight に送る

1. [Actions の「iOS」](https://github.com/zoukapu-design/grafitygate/actions/workflows/ios.yml) を開く
2. 右の **Run workflow** → 「TestFlight に送る」にチェックが入っているのを確かめて **Run workflow**
3. 20 分ほどで組み立てが終わり、さらに 10〜30 分で TestFlight アプリに届きます
