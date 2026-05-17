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

### 画像のみ・動画のみの投稿の表示
- 本文が空で画像だけ／動画だけの投稿のとき、タイムライン上でコンテンツの存在が分かるように絵文字でヒントを出す。
  - 例: 画像のみ → `画像` を示す絵文字、動画のみ → `動画` を示す絵文字。
- `Tempest::REPL::Formatter` の整形ロジックに、embed種別ベースのプレースホルダ表示を追加する。

## ふぁぼ機能

### `:fav $AA` の実装
- `$AA` のような短縮ID（タイムラインに表示中の投稿を指す参照子）を解決し、対象の投稿に対してLike（`app.bsky.feed.like` レコードの作成）を行う。
- 参照子の振り方とタイムライン表示の整合性を考える必要がある（表示済み投稿に対する識別子の付与・保持）。
- Likeの取り消し（unlike）もセットで考えておく。

## マルチアカウント対応

- 複数アカウントのタイムライン取得・投稿を切り替えながら扱えるようにしたい。
- `SessionStore` / `CursorStore` / `TimelineStore` をアカウントごとに名前空間分けする必要がある。
- 起動オプションまたは REPL コマンドでアクティブアカウントを切り替える。
- Jetstream 購読も切り替えに合わせて貼り直す。

## プロンプトの改善

- 現状の `tempest>` ではなく、サインインしているアカウントの handle を反映したプロンプトにする。
  - 例: `asonas.bsky.social>` や `ason.as>`。
- マルチアカウント対応とあわせて、現在アクティブなアカウントが一目で分かるようにする。
- 表示する識別子のフォーマット（フルhandle / 短縮形 / 別名）の選択肢を検討する。

## ImageMagick依存の排除

- `Tempest::AvatarStore.default_converter` の `magick` シェルアウトをやめる。
- 動機は二つ。
  - サブプロセス起動コスト（毎回100〜300ms程度）が無視できない。
  - Q16-HDRIビルドで16-bit PNGを吐いた場合に、kitty graphics protocol 側で描画されない事例（taea 環境で再現）があり、出力ビット深度を明示的に制御したい。
- 第一候補は `ruby-vips`。`Vips::Image.thumbnail_buffer(bytes, 128, height: 128, crop: :centre)` + `pngsave_buffer(bitdepth: 8)` で同等処理がインプロセスで完結する。Homebrew では `brew install vips`。
- 代替: macOS 標準の `sips` で逃げる（Linux移植性を捨てる前提）。
- Bluesky CDN の `/img/avatar/...` バリアントは既に正方形クロップ済みなので、クライアント側の `extent` 処理は省略可能。リサイズだけで足りる。
- 切り替え時は `Kitty.inline` に渡す前のPNGが 8-bit sRGB であることをテストで担保する。
