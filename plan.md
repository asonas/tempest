# tempest 実装計画

[[projects/tempest/技術調査]] の最初のマイルストーン「App Password でログインしてタイムラインを取得し、コマンドラインから1投稿」を TDD で実装する。各テストは1つずつ Red → Green → Refactor で進める。

## テストリスト

### Milestone 1: 認証と XRPC クライアント
- [ ] Config が ENV から identifier / app_password / pds_host を読む
- [ ] Config は identifier 未設定なら例外を投げる
- [ ] Session.create が createSession を叩いて access_jwt / refresh_jwt / did / handle を返す
- [ ] Session.create が認証失敗時に AuthenticationError を投げる
- [ ] Session#access_expired? が JWT の exp を判定する
- [ ] Session#refresh! が refreshSession を叩いて新しいトークンに置き換える
- [ ] XRPCClient#get が Authorization ヘッダに access_jwt を付ける
- [ ] XRPCClient が 401 のとき session.refresh! して 1 回だけ再送する

### Milestone 2: タイムライン取得と投稿
- [ ] Timeline.fetch が app.bsky.feed.getTimeline を呼び Post の配列を返す
- [ ] Post には author handle / text / created_at / uri が入る
- [ ] Post.create が com.atproto.repo.createRecord を呼ぶ
- [ ] Post.create のリクエストボディに text と createdAt が含まれる

### Milestone 3: REPL
- [ ] Dispatcher が ":timeline" を timeline コマンドにマッピング
- [ ] Dispatcher が ":quit" を quit コマンドにマッピング
- [ ] Dispatcher が ":" 始まりでない入力を post コマンドにマッピング
- [ ] Formatter が Post を `@handle: text` 形式に整形する
- [ ] exe/tempest が Config を読み Session を確立し REPL を起動する

## 後回し（Milestone 1 完了後に着手）
- Jetstream 接続と画面ストリーム
- Ractor 化（CBOR デコードや高頻度フィルタ評価）
- プラグイン拡張（Ruby::Box は実験フラグ前提なので慎重に）
