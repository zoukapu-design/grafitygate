# GRAFITYGATE — 開発メモ（Claude 向け）

- アプリ名は GRAFITYGATE（旧名 GRAFFOOT・仮の名前 GRAFTGATE）。コンセプトは「場所に、記憶の扉を。」。設計書は claude.ai の「GRAFITYGATE 詳細設計書」（Claude Docs）。
- **このリポジトリは公開している。** 秘密の値（Supabase の鍵、App Store Connect の鍵）は絶対にコミットしない・ログに出さない。GitHub Secrets から CI が `App/Config/Secrets.xcconfig` を作る。
- **別のアプリ Lyric Path（非公開のリポジトリ）のコードを入れない・写さない。** 文字の道、会話や歌の記録など Lyric Path 固有の仕組みも作らない。AR は Apple（ARKit・RealityKit・Vision）と Google（ARCore）の公開の部品で作る。Lyric Path で分かった問題（夜に AR の座標が飛ぶ、4GB の機種で固まる等）は参考にしてよい。
- サーバーは Supabase（Lyric Path と同じプロジェクト）。表は `gf_` で始める。`profiles`・`follows`・`reports` は Lyric Path と共有、ブロックは `lp_blocks` を読む（形を変えるときは両方のアプリで確かめる）。
- 判定はすべてサーバー（`supabase/migrations/*.sql` の関数と行ごとの権限）で行う。アプリだけで決まりを守らない。決まりを変えたら `supabase/tests/test_core.sql` にテストを足し、`bash supabase/tests/run.sh` が通ることを確かめる（CI でも毎回動く）。SQL は何度実行しても大丈夫な書き方にする（run.sh が 2 回流して確かめる）。
- 守るルール（旧 GRAFFOOT の決定。現場のデータで確かめるまで緩めない）：発見 100m、入場 120m・精度 35m・20 分、合言葉 90 秒・1 回、1 回の入場で 1 枚、同じ GATE は 12 時間、友達の新着は 24 時間。GPS だけ・写真だけでは入れない。「友達」はお互いにフォロー。値は `gf_settings`。
- 写真の特徴は Vision の `VNGenerateImageFeaturePrintRequest`（版は `FeaturePrint.revision`）。参照写真の特徴はアプリに返さず、比べるのはサーバー。距離のしきい値 `match_max_distance` は仮の値で、`gf_enter_attempts` の記録を見て決め直す。
- 写真で入る・作るときはカメラだけ（写真アプリから選ばせない＝前の写真で入れないように）。
- iPhone アプリは `App/`。XcodeGen（`App/project.yml`）、Swift 5 言語モード、iOS 17 以上。いちばん下の基準の端末は iPhone 12（LiDAR なし・4GB）。`.xcodeproj` はコミットしない。
- ユーザーは Mac を持っていない。組み立ては GitHub Actions（`.github/workflows/ios.yml`。公開リポジトリなので Mac も無料）。push で署名なしの組み立てを確かめ、TestFlight へは手動実行で「TestFlight に送る」を選んだときだけ。失敗したら `gh run view <id> --log-failed` と、注記（annotations）の `build errors` を読んで直す。
- 画面は白基調（`Theme`）。下のタブは「ホーム／地図／撮る／わたし」の 4 つ。ホームは友達の新着だけ。分かりやすさを最優先にし、ボタンや文字を詰め込まない。
- エフェクトは最初は数種類。仕組みが固まってから増やす。
- ユーザーへの説明は日本語で、専門用語を避けて分かりやすく。直したときは、何をどう直したかをまとめて伝える。
