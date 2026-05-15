# tempest 実装計画

[[projects/tempest/技術調査]] の最初のマイルストーン「App Password でログインしてタイムラインを取得し、コマンドラインから1投稿」を TDD で実装する。各テストは1つずつ Red → Green → Refactor で進める。

## テストリスト

### Milestone 1: 認証と XRPC クライアント
- [x] Config が ENV から identifier / app_password / pds_host を読む
- [x] Config は identifier 未設定なら例外を投げる
- [x] Session.create が createSession を叩いて access_jwt / refresh_jwt / did / handle を返す
- [x] Session.create が認証失敗時に AuthenticationError を投げる
- [x] Session#access_expired? が JWT の exp を判定する
- [x] Session#refresh! が refreshSession を叩いて新しいトークンに置き換える
- [x] XRPCClient#get が Authorization ヘッダに access_jwt を付ける
- [x] XRPCClient が 401 のとき session.refresh! して 1 回だけ再送する

### Milestone 2: タイムライン取得と投稿
- [x] Timeline.fetch が app.bsky.feed.getTimeline を呼び Post の配列を返す
- [x] Post には author handle / text / created_at / uri が入る
- [x] Post.create が com.atproto.repo.createRecord を呼ぶ
- [x] Post.create のリクエストボディに text と createdAt が含まれる

### Milestone 3: REPL
- [x] Dispatcher が ":timeline" を timeline コマンドにマッピング
- [x] Dispatcher が ":quit" を quit コマンドにマッピング
- [x] Dispatcher が ":" 始まりでない入力を post コマンドにマッピング
- [x] Formatter が Post を `@handle: text` 形式に整形する
- [x] exe/tempest が Config を読み Session を確立し REPL を起動する

### Milestone 4: Jetstream 再接続とオフライン差分復旧
- [x] `Jetstream::Client#subscribe_url(cursor: n)` が `cursor=n` を URL に含める
- [x] `Jetstream::Client#subscribe_url(cursor: nil)` は `cursor` を含めない
- [x] `Jetstream::Client#each_event(cursor:)` が cursor を transport に渡す
- [x] `StreamManager` は yielded event の `time_us` を最新値として保持する
- [x] `StreamManager` は `each_event` が正常終了したら保持した cursor で再接続する
- [x] `StreamManager` は `each_event` が例外で終わっても再接続する
- [x] 切断時に `StreamStatus(state: :disconnected, reason:)` を on_event に流す
- [x] 再接続前に `StreamStatus(state: :reconnecting)` を on_event に流す
- [x] 再接続成功（最初のイベント受信）で `StreamStatus(state: :live)` を on_event に流す
- [x] 再接続は指数的 backoff（1, 2, 5, 10, 30 秒上限）を持つ
- [x] `StreamManager#stop` は backoff 中でもループを抜ける
- [x] 切断時間が cursor 保持窓を超えたら `StreamStatus(state: :gapped, since:)` を出してから cursor なしで再接続する
- [x] `Runner#handle_stream_event` が `StreamStatus` を `-- <text>` 行で画面に出す
- [x] `Runner` が `:gapped` を受け取ったら `Timeline.fetch` を呼び結果を時系列の古い順に画面に流す

### Milestone 5: cursor のディスク永続化
- [x] `CursorStore.save / load` のラウンドトリップが成立する
- [x] `CursorStore.load` はファイル欠落 / 壊れた JSON で nil を返す
- [x] `CursorStore.default_path` が `TEMPEST_CURSOR_PATH` / `XDG_CONFIG_HOME` / `HOME` の優先順位を尊重する
- [x] `StreamManager` は `cursor_store` から初期 cursor を採用する
- [x] `StreamManager` は `saved_at` が窓を超えていれば store の cursor を無視する
- [x] `StreamManager` は live-tail 中、N 秒間隔で cursor を store に保存する（スロットル）
- [x] `StreamManager` は切断時に保存中の cursor との差分があれば必ず保存する
- [x] `StreamManager#stop` 後に最新 cursor が確実に保存されている
- [x] CLI が `CursorStore` を生成して `StreamManager` に渡す

### Milestone 6: フォロー先 DID を含むホームフィード相当の live stream
- [x] `Tempest::Follows.fetch` が `app.bsky.graph.getFollows` を呼び `[{did:, handle:}, ...]` を返す
- [x] `Tempest::Follows.fetch` は cursor を辿って全件取得する
- [x] `Tempest::Follows.fetch` は応答が空のときに空配列を返す
- [x] `Tempest::Jetstream::Subscription.build(self_did:, follows:, cap:)` が cap 以下なら `wanted_dids` を返し、超えたら空 (firehose) + filter set を返す
- [x] `Subscription.build` は self_did を follows と重複なく結合する
- [x] `StreamManager` が `filter:` predicate を受け取り、false の event は on_event に流さない（cursor 追跡は継続）
- [x] CLI の `--feed=home`（デフォルト）/ `--feed=self` フラグが認識される
- [x] CLI が home モードで follows を取得して Jetstream を購読する
- [x] CLI が HandleResolver に follows の (did, handle) を seed する

### Milestone 7: タイムラインのスナップショット永続化と起動時表示
- [x] `TimelineStore.save / load` のラウンドトリップが成立する（posts と saved_at）
- [x] `TimelineStore.load` はファイル欠落 / 壊れた JSON で nil を返す
- [x] `TimelineStore.default_path` が `TEMPEST_TIMELINE_PATH` / `XDG_CONFIG_HOME` / `HOME` の優先順位を尊重する
- [ ] `TimelineStore.save` は posts を直近 50 件にトリムする
- [x] `Runner#bootstrap_timeline` はキャッシュがあれば古い順に画面に流す
- [x] `Runner#bootstrap_timeline` はキャッシュ後に `Timeline.fetch` を呼び新着分のみ表示する（uri 重複は除外）
- [x] `Runner#bootstrap_timeline` は fetch 成功時に `TimelineStore.save` を呼ぶ
- [x] `Runner#bootstrap_timeline` は fetch 失敗時にエラー行を出して継続する
- [x] `Runner#handle_timeline` が成功時に `TimelineStore.save` を呼ぶ
- [x] CLI が `TimelineStore` を生成して `Runner` に渡し、`auto_start_stream` 前に bootstrap する

## 後回し（最初のマイルストーン完了後に着手）
- Ractor 化（CBOR デコードや高頻度フィルタ評価などの CPU 仕事）
- HTTP 層の persistent 化（minisky 採用見直し、async-http への置き換え検討）
- プラグイン拡張（Ruby::Box は実験フラグ前提なので慎重に）
- 投稿のリプライ / メンション / 画像添付など lexicon 拡張
- タイムラインの cursor ベースのページング
- フォロー先の動的更新（Jetstream options_update / 定期的な再取得）
