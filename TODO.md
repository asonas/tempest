# TODO

tempest で実現したいことのメモ。優先度や実装方針は未確定。

## 投稿機能の拡張

### 画像投稿
- 添付ファイル付きの投稿ができるようにする。
- `app.bsky.feed.post` の `embed` に `app.bsky.embed.images` を載せ、画像本体は `com.atproto.repo.uploadBlob` でアップロードしたBlobを参照する形にする。

### クリップボード画像のペースト投稿
- macOSのCleanShotやWindowsのSnipping Toolでクリップボードに入った画像を、そのまま貼り付けて投稿できるようにしたい。
- 入力UI（REPL）でクリップボード画像を検出し、一時ファイル化してから`uploadBlob`に流す経路を作る。
- macOSは `pngpaste` 等の外部コマンド、もしくは `osascript` 経由で取得することを検討する。

## プロンプトの改善

- 現状の `tempest>` ではなく、サインインしているアカウントの handle を反映したプロンプトにする。
  - 例: `asonas.bsky.social>` や `ason.as>`。
- マルチアカウント対応とあわせて、現在アクティブなアカウントが一目で分かるようにする。
- 表示する識別子のフォーマット（フルhandle / 短縮形 / 別名）の選択肢を検討する。
