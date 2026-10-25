# 設計メモ

このドキュメントは、statusline スクリプトの実装上の仕組み、壊れやすい箇所、採らなかった案をまとめたものです。表示される内容 (何が、どの順で、どの色で出るか) の定義は [SPEC.md](SPEC.md) にあり、ここでは｢なぜその実装になっているか｣と｢変えると何が起きるか｣を扱います。テストの書き方は [tests/README.md](../tests/README.md)、開発の進め方は [DEVELOPMENT.md](DEVELOPMENT.md) を参照してください。

## 目次

- [全体の構成](#全体の構成)
- [macOS 版と Linux 版の差分](#macos-版と-linux-版の差分)
- [実装上の仕組み](#実装上の仕組み)
- [壊れやすい箇所と守っているテスト](#壊れやすい箇所と守っているテスト)
- [採らなかった案と経緯](#採らなかった案と経緯)
- [テストで守れていない箇所](#テストで守れていない箇所)

## 全体の構成

macOS 版 (`statusline-macos.sh`) と Linux 版 (`statusline-linux.sh`) は同じ順序で処理を進めます。

1. `export LC_ALL=C.UTF-8` でロケールを固定する
2. 設定ファイル (`~/.claude/statusline.conf`) を読み込む
3. カスタマイズ設定を env > conf > 既定値 の順で決める
4. 内部定数 (`SPARKS` / `UNTRACKED_DIFF_LIMIT` など) を定義し、数値の設定 (`RATE_CHART_LEN` と間引き間隔) を clamp する
5. カラースキーム (`COLOR_*`) を定義する
6. 依存コマンドを確認し、履歴ディレクトリを安全に用意する
7. 入力 JSON を `jq` 1 回で読み取り、`HIGHLIGHT` のトークンを照合用の `hl_set` にまとめる
8. rate 履歴を更新してチャートを作り、weekly の 1 文字のスパークを求める
9. git のブランチ、変更行数、ahead/behind を取得する (`GIT_FETCH=1` のときはここでバックグラウンド fetch を投げる)
10. 各フィールドを着色し、レイアウトに従って 1 行目と 2 行目を組み立てて出力する (`PR_STATUS=1` で branch 列を組み立てるときだけ、PR のキャッシュを読み、必要ならバックグラウンドで取得を投げる)

Linux 版はステップ 1 の前に bash 4.1+ ゲートを置き、ステップ 6 では履歴ディレクトリの準備を先に行ってから `jq` / `flock` を確認します (macOS 版は `jq` の確認が先です)。また `LOCK_TIMEOUT_SEC` は、Linux 版では内部定数のブロックに、macOS 版ではロック取得関数 (`acquire_lock`) の直前にあります。

描画は statusline が更新されるたびに走るため、全体を通して｢fork (外部コマンド起動) を増やさない｣｢ネットワーク I/O を描画経路に入れない｣｢異常があっても表示は続ける｣の 3 点を優先しています。

## macOS 版と Linux 版の差分

両版の違いはプラットフォーム依存の部分に限られます。

| 項目 | macOS 版 | Linux 版 |
| --- | --- | --- |
| 想定 bash | `/bin/bash` 3.2 以上 | bash 4.1 以上 (冒頭でバージョン確認) |
| 排他制御 | `mkdir` の原子性 + stale ロック解除 | `flock(1)` + named fd (`exec {fd}>...`) |
| ロックの実体 | `<対象>.lockd` ディレクトリ | `<対象>.lock` ファイル |
| `date` / `stat` | `uname -s` で BSD 版と GNU 版を切り替える | GNU 版 (`date -d "@.."`、`stat -c`) |
| 依存コマンドの確認 | `jq` | `jq` と `flock` |

macOS 版で `flock` を使わないのは、macOS に標準で入っておらず、無い環境では黙って失敗するためです。代わりに POSIX で原子性が保証されている `mkdir` でロックを取り、`LOCK_TIMEOUT_SEC` × 5 秒 (既定 10 秒) より古いロックディレクトリは stale とみなして削除します。Linux 版の `flock` はプロセス終了時に自動で解放されるため、stale 処理は持ちません。

これ以外のブロック (設定の読み込み、カスタマイズ設定、clamp、カラースキーム、PR の状態表示の定数と共通部分、スパークと残量の計算、履歴の読み出し、色付けと整形、レイアウトの組み立て、main の描画部分) は両版で一字一句同じに保ちます。履歴まわりで両版が違うのは、ロックを取る `history_push` だけです。PR の状態表示で両版が違うのは、ロックを取る `maybe_pr_refresh` だけです。`tests/script-parity.sh` がこれらのブロックを抜き出して比較します。

## 実装上の仕組み

### 色付けの 3 段構成

すべての着色 (model / effort / ctx / rate / weekly / diff / ahead-behind) は `paint <text> <effect> [arg]` を経由します。

- `paint` は effect 名を見て `static` か `rainbow` に振り分けるだけのディスパッチャです
- `static <text> <color>` は単色で囲んで末尾に `\033[0m` を付けます。color が空のときは文字列を末尾改行付きで素通しします
- 色を決める関数 (`model_color` / `effort_color` / `ctx_color` / `limit_color`) は `"static <ansi>"` / `"static"` / `"rainbow"` という effect 指定の文字列を `printf -v` で第 1 引数の変数に入れ、呼び出し側はそれをクォートせずに展開して `paint` に渡します
  - `$(...)` で受けないので fork しません
  - 無色は `"static"` だけなので、色が付くかは `"static"` との比較で判定します

新しいエフェクトを足すときは `paint` に分岐を 1 つ追加すれば済みます。個別の経路から `static` を直接呼ぶ形に戻すと、エフェクトの追加箇所が分散します。

例外は `HIGHLIGHT` の塗り (`highlight`) です。色が `COLOR_text` に決まっていて effect を選ぶ必要がなく、指定が無いときも全要素が通るため、`paint` を経由せず fork しない形にしています ([ハイライト (`HIGHLIGHT`)](#ハイライト-highlight))。

無色の `static` は末尾改行を付けるため、`$(...)` で受けて改行を落としてから連結します (無色の `*` がこの経路を通ります)。色付きの `static` は末尾改行を付けないので、そのまま連結しても出力は崩れません。

### rainbow

effort が `max` のとき、`effort_color` が `rainbow` を返し、語句を 1 文字ずつ別の色で塗ります。

- 色は `RAINBOW_PALETTE` (7 色の truecolor `R;G;B`) を i 番目の文字に `palette[i % 7]` で割り当てます。補間はしません
- 末尾の `\033[0m` は最後に 1 回だけ付けます
- 1 文字の切り出しは `${text:i:1}` で行い、外部コマンドに文字を渡しません。マルチバイト文字を壊さないためで、`LC_ALL=C.UTF-8` で文字数換算になることが前提です

### effort の連結と区切り

effort は model とは別の `paint` 呼び出しで塗り、`✻ <model>` の色シーケンスと混ぜません。

- `SHOW_MODEL_NAME=1` のとき: `model_field` と effort の間に無色の `∙` を前後スペースなしで挟みます。`∙` は `paint` を通さないので、`max` の rainbow 循環にも入りません
- `SHOW_MODEL_NAME=0` のとき: `∙` を使わず、スペース 1 個で連結します
- effort が空 (非対応モデル) のときは `[ -n "$effort" ]` で分岐ごと飛ばし、区切りも effort も出しません。effort 導入前と同じ出力になります

### `✻` の常時表示

`SHOW_MODEL_NAME=0` でもモデル名だけを消し、`✻` は `model_color` の色で残します。記号の色でモデルを見分けられるようにするためです。色の判定はトリム前のモデル名全体で行うので、13 文字で切られたあとも色は変わりません。

### カラースキーム定数ブロック

`COLOR_*` は Claude Code の light/dark テーマに合わせた配色で、`COLOR_SCHEME` の `case` で 2 セットを切り替えます。

- `_fg` は `R;G;B` を `\033[38;2;R;G;Bm` に展開するヘルパで、定義時にだけ使います。各 `COLOR_*` は実際の ESC を含む文字列になっているので、使う側は `printf` で包まずに `static` へ渡します
- セマンティック名 (`success` / `error` など) は用途を表す名前で、今は使っていないキーも残しています
- `COLOR_subagent_*` は Claude Code のサブエージェント表示に使われる色に対応します

色の値を各関数に直接書く形に戻すと、light/dark の切り替えと両版の一致確認が難しくなります。

### rate / weekly / ctx の 3 階調と点滅

テーマの配色には警告系の色が `warning` (黄) と `error` (赤) の 2 段しかありません。rate / weekly と ctx では中間に `claude` (橙) を挟み、警戒 → 危険 → 致命 の 3 段にしています。致命段は `error` に点滅属性 `\033[5m` を重ねます。点滅は色ではなく属性なので、色の数を増やさずに危険段と区別できます。点滅を外して `error` 単色にすると、致命段と危険段の見た目の差が色だけになり、隣接する段と紛れやすくなります。

### 1 行目の組み立て

1 行目は 2 行目の `parts` とは別の配列 `line1_parts` で組み立てます。

- 要素が 1 つ以上あるときだけ `join_by` の結果に改行を付けて出力します
- 改行は 1 行目の末尾に置きます。2 行目の先頭に置く (`printf '\n%s'`) と、1 行目が省略されたときに先頭へ空行が出ます
- directory･branch･session がすべて空のときは改行も出しません。空行でも statusline の高さを 1 行分占有するためです

### レイアウトのトークン設計

`LAYOUT_LINE1` / `LAYOUT_LINE2` は `build_layout` で走査し、各トークンの値を `layout_token` で引きます。

- トークン間の区切りは常に ` | ` です。トークンの内側で別の区切りを使う要素は 1 トークンにまとめています
  - `model_ctx` は `✻ <model>∙<effort> <ctx>` (`∙` とスペース 1 個を内包)
  - `branch` は `truncate_branch 25` でトリムした名前 (末尾のセグメントだけを `highlight` に通す) に `${ab_str:+ $ab_str}${diff_str:+ $diff_str}${pr_str:+ $pr_str}` を続ける (ab / PR が空のときに余分なスペースを残さないよう `:+` で条件付き連結。diff は作業ツリーがクリーンでも `·` を返すため、ブランチがあれば常に出る)
    - `pr_str` は同じ case 節で直前に呼ぶ `pr_token` が設定する。連結を `pr_token` より前に移すと PR が出なくなる
- `model` と `ctx` を別トークンに分けないのは、トークン間の区切りが組み合わせごとに変わり、実装とテストの両方が複雑になるためです
- `build_layout` の第 3 引数で｢空の値を積むか｣を切り替えます。1 行目は `0` (空なら列ごと省略)、2 行目は `1` (空でも積む)
- 2 行目は走査対象の末尾に既定の全トークン (`LAYOUT_LINE2_TOKENS`、`model_ctx|rate|weekly`) を足し、書かれなかったトークンを既定順で補います。これにより `✻` を含む `model_ctx` は消せず、`weekly` を書かない conf でも `weekly` は末尾に補われます
- 各行のトークンの一覧 (`LAYOUT_LINE1_TOKENS` / `LAYOUT_LINE2_TOKENS`) は、既定値、補完、有効なトークンの判定に共通で使います。トークンを足すときは、この一覧と `layout_token` の `case` の両方を直します (一覧だけに足すと、値が空の列が 2 行目に出ます)
- 未知のトークンは黙って無視し、重複は最初の 1 回だけ採ります。`|` での分割と前後の空白 (タブを含む) の除去は `split_tokens` がパラメータ展開だけで行い、`tr` や `awk` は使いません。`split_tokens` は `HIGHLIGHT` の解析と共有しています。同じ規則のループを 2 か所に書くと、片方だけ直したときに同じ文字列の解釈がずれるためです
- トークンから値への対応は連想配列ではなく `case` で引き、値はグローバル変数 `token_value` で返します。macOS の `/bin/bash` 3.2 には連想配列が無く、`$(...)` で受けると fork が増えるためです
  - 例外として、branch / session のトリムは `truncate_branch` / `truncate_label` の command substitution を伴います
  - `PR_STATUS=1` のときは branch で呼ぶ `pr_token` もキャッシュの読み取りで fork します ([PR の状態表示の取得とキャッシュ](#pr-の状態表示の取得とキャッシュ))
- `SHOW_CWD=0` は `directory` トークンが空を返すことで実現しています。フラグとレイアウトで二重に判定する箇所を作らないためです

### ハイライト (`HIGHLIGHT`)

無色の要素を `COLOR_text` で塗る処理は、ヘルパー `highlight <トークン> <文字列>` 1 つに集めています。

- main で jq の読み取りの直後に、`split_tokens "$HIGHLIGHT"` の結果を `|a|b|` の形に連結した `hl_set` を 1 回だけ作ります (`build_layout` の `seen` / `allowed` と同じ形)。`highlight` は `case` で `*"|<トークン>|"*` と照合します
- 結果は `$(...)` で受けずにグローバル変数 `hl_out` に返し、fork しません。指定されていないトークンでは元の文字列がそのまま返るので、無色の要素を出す箇所は条件分岐なしで常に `highlight` を通します。既定 (空) では何も塗らず、ハイライトの有無で fork の回数は変わりません
- `hl_out` は 1 つのグローバル変数なので、続けて呼ぶと上書きされます。`format_limit` の無色の分岐では、チャートの結果を `chart_out` に移してから時刻を通します
- 空の文字列は塗りません。塗ると空の列が ESC だけの空でない値になり、1 行目の｢値が空の列は省略する｣が崩れます。空のときも終了ステータスは 0 にして、呼び出し側が `&&` / `||` でつないでも失敗と取り違えないようにしています
- トリムしてから塗ります。`truncate_label` / `truncate_branch` の文字数に ANSI エスケープを含めないためです
- 1 行目の要素 (directory / branch / session) は `layout_token` で塗ります。`dir_field` は `hl_set` より前に作られるので、作る箇所で塗る設計にすると、`hl_set` の構築位置を動かしただけで directory のハイライトが黙って効かなくなります
- branch は表示中の名前の最後の `/` で分け、後ろだけを塗ります。`/` が無い名前で `${label%/*}` を使うと名前全体が返り `main/main` のように重なるため、`case` で分けます。塗る範囲は表示中の名前から決めるので、トリムの規則が変わってもこの規則は変わりません
- ctx / rate / weekly は `format_ctx` / `format_limit` の無色の分岐 (と欠落の分岐) だけで呼びます。`format_limit` は第 5 引数の列の名前 (`rate` / `weekly`) から `<列の名前>_chart` / `<列の名前>_reset` のトークンを組み立て、rate と weekly で同じコードを使います
- model は `model_effect` が無色 (`static`) のときだけ `highlight` を通し、色付きのときは `paint` で塗ります。無色のモデルは `paint` の `$(...)` を通らないので、その分の fork がありません
- PR のコメントの件数は `format_pr` で `pr_comments` として通します

### rate チャートの土台と右端の現在値

rate チャートは `RATE_CHART_LEN` (既定 12) 文字で、左 `RATE_CHART_LEN − 1` 文字が履歴、右端 1 文字が現在値です。

- `rate_chart` はまず `history_chart /dev/null` (履歴なしのパディング。`RATE_CHART_LEN` 個の `·`) で初期化し、`HISTORY_DIR` が有効なときだけ実際の履歴で上書きします
- そのうえで、残量 (`rate_remaining`) があれば右端 1 文字を `spark_of` の現在値に差し替えます。`rate_chart` は土台のおかげで常に空でないため、分岐条件は `rate_remaining` の有無だけです
- 履歴の追記は `POLL_INTERVAL_SEC` (既定 300 秒) で間引かれるので、差し替えが無いとリセット直後でも右端が古い値のまま残ります
- `${rate_chart:0:$((RATE_CHART_LEN - 1))}` の切り出しは、`LC_ALL=C.UTF-8` で文字数換算になることが前提です (スパーク文字は 3 バイト)

### スパークと残量の計算を fork せずに行う

スパーク文字 (`spark_of`)、使用率の丸め (`round_int`)、残量の計算 (`set_remaining`)、色の決定 (`*_color`) は、結果を `printf -v` で呼び出し側の変数に書き込みます。`$(...)` で受けると呼ぶたびに fork が 1 つ増え、rate のチャートは文字数ぶん呼ぶためです。

- `spark_of` は、整数の値を bash の算術式 `(8p + 50) / 100` で段に直し、`awk` を起動しません。`awk` を使うのは小数 (ctx の使用率) と 9 桁以上の値だけです。rate の履歴と残量は常に整数なので、チャートの文字数によらずスパークのための `awk` は ctx の分だけになります
- 整数 p では、`awk` の `int(p / 100 × 8 + 0.5)` と算術式 `(8p + 50) / 100` が一致します。どちらも 0 に向かって切り捨てるので負の値でも同じで、`8p + 50` は 4 で割ると 2 余り 100 の倍数にならないため、浮動小数点の誤差で段が変わる境目もありません
- 先頭の 0 は `10#` で 10 進数に直します。算術式は `08` を 8 進数として読もうとしてエラーになるためです
- 書き込み先の変数名を受け取る関数のローカル変数には、関数ごとの接頭辞 (`_so_` / `_sr_` / `_ci_`) を付けます。bash の変数は動的スコープなので、呼び出し側と同じ名前のローカル変数があると、`printf -v` は呼び出し側ではなくローカルに書き込みます
- `eval` は使いません。`printf -v` なら値に記号が入っていてもコードとして実行されません

### 履歴ファイルと排他制御

- 履歴は rate だけが持ちます。rate は 5 時間ウィンドウのアカウント単位の値で全セッション共通なので、`${HISTORY_DIR}/rate` の 1 ファイルに集約します。ctx と weekly は現在値の 1 文字だけを描くため履歴を持ちません
- 保存する件数は表示長 (`RATE_CHART_LEN`) ではなく、その上限の `RATE_CHART_LEN_MAX` (20) 件で固定します
  - チャート長を伸ばしたとき、保存済みの履歴がすぐ表示に出ます。表示長で切り詰めると、伸ばした直後は `·` が並びます
  - 履歴ファイルは全セッション共通なので、`CLAUDE_STATUSLINE_CONFIG` で別の conf を読むセッションがあっても、短いチャートのセッションが長いチャートのセッションの履歴を切り詰めません
  - 保存件数より少ない履歴ファイルもそのまま読めるため、移行処理は要りません
- 空の履歴ファイルへの初回追記では、現在値を `RATE_CHART_LEN_MAX` 件書き込みます。初回表示で `·` が並ぶのを避けるためです
- 追記後は `tail -n RATE_CHART_LEN_MAX` を一時ファイルへ書いて `mv` で置き換えます。読み出し側は `tail -n RATE_CHART_LEN` で末尾だけを読むので、切り詰めに失敗してファイルが伸びても表示幅は崩れません
- 複数の statusline が同時に書き込むことがあるため、追記はロックの中で行います。ロック待ちは `LOCK_TIMEOUT_SEC` (2 秒) までで、取れなければその回の追記を飛ばします。statusline は頻繁に呼ばれるので、次の呼び出しで反映されます

### weekly (週間リミット)

- 7 日間のレートリミットの残量を、ctx と同じ 1 文字のスパークで描きます。履歴は持ちません。5 時間用の間引き間隔で 7 日の窓を記録しても傾向を示さないためです
- 整形は rate と同じ `format_limit` を使い、チャートの代わりに `spark_of` の 1 文字、時刻の書式の代わりに `%a` (曜日) を渡します。色の閾値 (`limit_color`)、数値を出す条件、` - ` の区切りを 2 か所に書かないためです
- `%a` は `LC_ALL=C.UTF-8` の下で評価されるため、利用者のロケールによらず `Sun`〜`Sat` の英語の略称になります
- 使用率が欠落しても `· --` で列を残します。ctx (`· --`) や rate (`<チャート> --`) と同じく、｢2 行目は空でも積む｣を保つためです
- 描画コスト
  - 増える: weekly の分として、描画ごとに command substitution が 2 つ (`format_limit` と、その中の `format_reset_time`) と `date` の起動が 1 つ。`resets_at` が無いときは `format_reset_time` を呼ばない
  - 減る: `round_int` / `spark_of` / `*_color` を `printf -v` で返す形にしたことで、次が減る
    - `$(printf ...)` が 3 つ
    - rate のチャート (`RATE_CHART_LEN` 文字) と右端の現在値の分の command substitution と `awk`
    - ctx のスパークを包む command substitution が 1 つ
    - 色の決定 (`model_color` / `effort_color` / `ctx_color` / rate の `limit_color`) の command substitution が 4 つ
  - チャート長によらず、増える分より減る分のほうが多い

### 入力 JSON の読み取り

`jq` は 1 回の起動に数十 ms かかるため、必要な 9 フィールドを 1 回の呼び出しで 1 行ずつ出力し、`read` を 9 回呼んで受け取ります。

- 文字列フィールドは `jq` の中で改行･タブ･CR を空白に置き換えます。値に改行が混ざると行の対応がずれるためです
- `@tsv` で 1 行にまとめる方法は使いません。bash 3.2 では IFS が非空白のとき `read` が連続する区切りを 1 つにまとめてしまい、空フィールドが失われます
- 新しいフィールドは末尾に追加します。途中に挿入すると、既存の変数と行の対応がずれます (`effort` の後に weekly の 2 フィールドがあるのはこのためです)

### 変更行数の集計

- 追跡ファイルは `git diff HEAD --numstat` の 1 回で、ステージ済みと未ステージをまとめて集計します
- 未追跡ファイルは `git status -z` で NUL 区切りに列挙します。パスがクォートされないため、空白や改行を含むパスも扱えます
- 未追跡ファイルごとに `git diff --no-index --numstat -- /dev/null <path>` を呼ぶため、件数に比例して fork が増えます。`UNTRACKED_DIFF_LIMIT` (50) 件を超えた分は行数を取らず、ファイル数だけを数えます

### ahead/behind と `*` の判定

- ahead/behind は `git rev-list --left-right --count '@{upstream}...HEAD'` の 1 回で取ります。ローカルにあるリモート追跡ブランチとの比較なので、ネットワークには出ません
- rev-list が失敗したときは `*` を出します。detached HEAD かどうかは main 側でブランチ取得時に判定済みの値 (`is_detached`) を引数で受け取り、関数内で git を呼び直しません
- ｢upstream 未設定｣と｢ブランチは取れるのに rev-list だけ失敗するリポジトリ内の異常｣は終了コードで区別できません。区別のために git 呼び出しを足すことはせず、どちらも青の `*` として扱います
- ahead の色に `success` (緑) を使わないのは、すぐ右に並ぶ変更行数の `+N` が緑で、境目が分かりにくくなるためです。upstream 未設定の `*` も、ローカルが先行している状態の一種として ahead と同じ青にしています

### directory 列

- 複数のセッションを並行しているときに、どのプロジェクトを操作しているかを見分けるための列です
- `workspace.current_dir` の basename をパラメータ展開 (`${path##*/}`) だけで取り出し、`basename` や git の呼び出しを足しません
- 末尾のスラッシュは先に取り除きます。`/tmp/project/` のような値では `${cwd##*/}` が空になり、実在するディレクトリなのに列が消えるためです。`/` だけは除去すると空になり、｢ルートは列ごと省略｣と同じ結果になります

### ブランチ名の末尾を残すトリム

- `feature/xxx/yyy` のような名前では末尾の `yyy` が作業内容を表すことが多いので、`truncate_branch` は最後の `/` より後ろを残し、中間を `…` で省略します。先頭優先で切ると、長い名前ほど見分けたい部分が消えるためです
- 末尾の上限 22 文字は、25 文字の中に先頭 1 文字 + `…` + `/` + 末尾を収められる最大値です。これより長い末尾や `/` の無い名前は中間省略では収まらない (または区切りが無い) ので、`truncate_label` に委ねて先頭 24 文字 + `…` にします。先頭優先の規則を 2 か所に書かないためです
- パラメータ展開 (`${text##*/}` / `${#tail}` / `${text:0:N}`) だけで組み、外部コマンドを使いません。呼び出し側の command substitution は `truncate_label` のときと同じ 1 回で、fork は増えません
- 守っているテスト
  - 中間省略: `117-branch-trim-keep-tail`、閾値の両側の `118-branch-trim-tail-22` / `119-branch-trim-tail-23`、`121-branch-trim-keep-tail-ab-diff`
  - 中間省略の境界: CJK の `122-branch-trim-keep-tail-cjk`、ちょうど 25 文字の `123-branch-trim-slash-25`、`/` の直後で切る `124-branch-trim-cut-after-slash`
  - 先頭優先のまま: `120-branch-trim-no-slash`、末尾が長い `31-branch-trim` / `41-diff-trim-keeps-stat`
  - 両版のずれ: `tests/script-parity.sh` の `block:paint` / `block:format-layout`

### PR の状態表示の取得とキャッシュ

PR の状態は `gh api graphql` で取りますが、1 回に 1 秒近くかかるため描画経路では呼びません。構造は `maybe_git_fetch` と同じで、描画はキャッシュを読むだけにし、取得は投げっぱなしの子プロセスで行います。

| ファイル | 書く人 | 内容 |
| --- | --- | --- |
| `${HISTORY_DIR}/pr-<key>` | 子プロセス | キャッシュ (タブ区切りの 1 行)。取得に成功したときだけ置き換える |
| `${HISTORY_DIR}/pr-<key>.marker` | 親 (描画側) | 空ファイル。mtime が最後に取得を試みた時刻 |
| `${HISTORY_DIR}/pr-<key>.inflight` | 子プロセス | ディレクトリ。取得している間だけ存在する |

- 入口は `layout_token` の `branch` から呼ぶ `pr_token` です。`PR_STATUS` の確認は `maybe_git_fetch` と同じく関数の中で行います。branch 列を組み立てるときだけ動くので、レイアウトを別に走査して `branch` の有無を調べる必要がなく、分割と空白の扱いが `build_layout` とずれません
- `<key>` は `cwd + 改行 + ローカルのブランチ名` の `cksum` です。描画のたびに今のブランチからキーを作るので、ブランチを切り替えたり `/clear` したりしても前の PR は残りません
- キャッシュとマーカーを別のファイルにしているのは、マーカーの書き方 (`true > "$marker"`) がファイルを空にするためです。兼ねると試行のたびにキャッシュが消えます
- 再取得の間隔はキャッシュに記録した状態から決めます (CI 実行中や push 前後は 30 秒、merged / closed は 900 秒など)。キャッシュの `fetched_at` がマーカーの mtime より古ければ、最後の試行は失敗したとみなします
- 子プロセスは `.inflight` を `mkdir` で作れたときだけ取得します。描画側も `.inflight` があれば取得を起動しないため、ネットワークが詰まっても `gh` が溜まりません
- `gh` は子プロセスの中でさらにバックグラウンドで起動し、0.2 秒ごとに `kill -0` で生存を確かめて、60 秒を過ぎたら `kill` します (TERM で終わらなければ 1 秒後に KILL)。macOS には `timeout(1)` がないためです
  - 経過は sleep の回数に加えて壁時計の `SECONDS` でも測ります。sleep の回数はマシンのスリープ中に進まず、`.inflight` の 90 秒 (壁時計) より長く動き続けることがあるためです
  - テストでは `CLAUDE_STATUSLINE_TEST_PR_TIMEOUT_SEC` で短くします
- 結果は一時ファイルに書いてから `mv` で置き換えます。描画が書きかけのファイルを読まないようにするためです。置き換える前に、既存のキャッシュの `fetched_at` が自分の開始時刻より新しくないことを確かめ、古い結果で新しい結果を上書きしないようにしています。現在より未来の `fetched_at` (時計が戻った後など) は後から始まった取得のものではないので上書きし、描画側も表示しません。そうしないと、時計が追いつくまで古い表示が残り、更新もされません
- 候補の選び方と状態の決め方は `gh` の `--jq` (gh に組み込みの jq) の中で済ませ、キャッシュの 1 行に変換します。`--jq` は `--arg` を受け付けないため、ローカルの HEAD と head のオーナーは環境変数で渡して `$ENV` で読みます。値を式に文字列として埋め込むと、ブランチ名などに含まれる記号で式が壊れます
- ローカルの HEAD と push 先を取る `git` の呼び出しは、子プロセスの中で行います。描画経路に入れると描画のたびに fork が増えます
- 描画側はキャッシュを組み込みの `read` で読み、パラメータ展開でタブごとに分けます。タブは IFS の空白文字なので、`IFS=$'\t' read` で分けると空のフィールドが詰められて列がずれます
- 描画コスト: `PR_STATUS=1` のときは、間隔内の通常経路でも描画ごとに `cksum` / `date` / `stat` の fork が増えます。`PR_STATUS=0` なら増えません

head のブランチ名とオーナーを push 先 (`@{push}`) から決めるのは、ローカルのブランチ名だけで探すと次の誤りが起きるためです。

- 公開リポジトリの `main` にいるとき、他人が自分の fork の `main` から出した PR を拾う (`patch-1` などのありがちな名前でも同じ)
- ローカルの `fix` が `origin/feature/fix` を追跡しているときや、`gh pr checkout` が `<owner>-<branch>` という名前でブランチを作ったときに、PR が見つからない

`MERGED` / `CLOSED` を選ぶのは `headRefOid` がローカルの HEAD と一致するときだけです。マージ済みの PR と同じ名前のブランチを使い回して新しいコミットを積んだときに、古い PR を表示しないためです。

`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` は見ません。Claude Code 標準の PR バッジを消すためにこの変数を設定した人でも、PR の状態表示は使えるようにするためです。`PR_STATUS=1` にすること自体が明示的なオプトインになっています。

## 壊れやすい箇所と守っているテスト

各項目は｢箇所 / 何をしているか / 外すと何が起きるか / 守っているテスト｣の順に書いています。テスト名は `tests/assertions/` のケース名、`tests/git-fetch-behavior.sh` と `tests/pr-status-behavior.sh` のケース名、`tests/script-parity.sh` のチェック名、`tests/regression.sh` の静的チェック名です。

`tests/script-parity.sh` は `npm test` に含まれ、OS に依存しないため CI (ubuntu) でも実行されます。

### ロケール固定

- 箇所: 両版冒頭の `export LC_ALL=C.UTF-8`
- 何をしているか: UTF-8 の記号 (`✻` `▁..█` `…` `↑` `↓` `∙`) を表示し、`${#var}` / `${var:0:N}` を文字数換算にする
- 外すと何が起きるか: 実行環境のロケールが C などのとき、トリムと切り出しがバイト数換算になる。rate チャートの右端差し替えや rainbow の 1 文字切り出しがマルチバイト文字の途中で切れ、表示が崩れる。両版の出力も環境によって食い違う
- 守っているテスト: `tests/script-parity.sh` の `static:locale` (冒頭 20 行に記述があることの静的確認)。出力比較のケースは実行環境のロケールに左右されるため、記述を消しても開発環境が UTF-8 なら落ちないことがある

### Linux 版の bash 4.1+ ゲート

- 箇所: Linux 版冒頭の `BASH_VERSINFO` 判定
- 何をしているか: bash 4.1 未満なら `✻ -- (bash 4.1+ required)` を出して終了する
- 外すと何が起きるか: Linux 版は named fd (`exec {fd}>...`) を使うため、古い bash ではパースエラーになり、statusline にエラー文が出るか何も出なくなる
- 守っているテスト: `tests/regression.sh` の `bash-4.1-gate` (冒頭 20 行にガードのコード片が完全一致で残っていることの静的確認)

### 依存コマンドの確認

- 箇所: macOS 版の `jq` 確認、Linux 版の `jq` と `flock` の確認
- 何をしているか: 足りないときは 1 行のメッセージを出して終了する (文言は [SPEC.md](SPEC.md#起動時チェックとフォールバック出力))
- 外すと何が起きるか: コマンドが見つからないエラーが statusline に流れ、原因が分かりにくくなる
- 守っているテスト: テストなし

### `printf '%s'` の統一

- 箇所: 両版の出力すべて
- 何をしているか: 値の出力に `echo` を使わず `printf '%s'` を使う
- 外すと何が起きるか: セッション名などの値が `-n` / `-e` で始まる場合やバックスラッシュを含む場合に、`echo` がオプションやエスケープとして解釈して値が欠ける
- 守っているテスト: `14-session-name-dash-n`、`tests/script-parity.sh` の `static:no-echo`

### 設定ファイルの読み込みブロック

- 箇所: 冒頭の｢ユーザー設定ファイルの読み込み｣ブロック
- 何をしているか:
  - 内部定数と clamp より前、カスタマイズ設定の直前で conf を読む
  - 読み込み前に短縮名の 11 変数 (`SHOW_MODEL_NAME` / `COLOR_SCHEME` / `GIT_FETCH` / `PR_STATUS` / `SHOW_CWD` / `RATE_CHART_LEN` / `POLL_INTERVAL_SEC` / `GIT_FETCH_INTERVAL_SEC` / `LAYOUT_LINE1` / `LAYOUT_LINE2` / `HIGHLIGHT`) を `unset` する
  - 11 変数の一覧は配列 `STATUSLINE_CONF_VARS` の 1 か所に置き、`unset` と `\r` の除去の両方で使う
  - `[ -f ] && [ -r ]` を満たすときだけ `.` で読み、読めなければ黙って既定値で続ける
  - `/` を含まないパスには `./` を前置する
  - 読み込み直後に 11 変数の末尾の `\r` を取り除く (`printf -v` と間接展開 `${!name%$'\r'}` で書き戻す)
  - 各設定は `${CLAUDE_STATUSLINE_X:-${X:-既定値}}` で読み、env > conf > 既定値 の順にする。env 口の無い数値の設定 (`RATE_CHART_LEN` と間引き間隔) は既定値を `clamp_int` の引数にだけ持ち、空の値も既定値に戻す
- 外すと何が起きるか:
  - 読み込みを clamp より後へ移すと、conf の不正な間引き間隔が丸められず間引きが無効になる
  - 内部定数より後へ移すと、conf で `RATE_CHART_LEN_MAX` などの内部定数を変えられ、保存件数やレンジガードが崩れる
  - `unset` を外すと、外の環境にある同名の変数が conf の代わりに効いてしまう
  - `-r` だけで判定すると、ディレクトリを `.` してエラーが出る
  - `./` を付けないと、`.` が `$PATH` からファイルを探し、`[ -f ]` で確認したものとは別のファイルを読むことがある
  - `\r` を取り除かないと、CRLF で保存した conf の値が `light\r` のようになり、黙って既定値扱いになる
  - 設定を `X=300` のような無条件代入にすると、conf の値が上書きされる
- 守っているテスト:
  - `79-config-show-model-off`〜`86-config-template`、`94-config-layout`〜`96-config-layout-crlf`、`166-highlight-config`〜`169-highlight-env-none`
  - `tests/script-parity.sh` の `block:config-load` / `block:settings`
  - `unset` は、回帰ハーネスが全ケースで短縮名を既定値と異なる値で渡しているため、外すと全ケースが落ちる
  - `./` の前置はテストなし

conf はシェルスクリプトとして読み込みます。JSON や YAML にしないのは、描画のたびに `jq` などのパーサを起動する fork が増えるためです。パーミッションや所有者の確認はしません (`~/.claude/` はユーザー自身の領域のため)。

### 間引き間隔の clamp

- 箇所: `RATE_CHART_LEN_MIN/MAX` / `RATE_WINDOW_SEC` / `POLL_INTERVAL_MIN_SEC` / `GIT_FETCH_INTERVAL_MIN/MAX_SEC` と、直後の `clamp_int` (`clamp_int <変数名> <既定値> <下限> <上限>`) とその呼び出し
- 何をしているか:
  - `RATE_CHART_LEN` を 2〜20、`POLL_INTERVAL_SEC` を 60〜(18000 ÷ `RATE_CHART_LEN`)、`GIT_FETCH_INTERVAL_SEC` を 60〜1800 に丸める
  - `POLL_INTERVAL_SEC` の上限 `POLL_INTERVAL_MAX_SEC` は、丸めた後の `RATE_CHART_LEN` から `RATE_WINDOW_SEC / RATE_CHART_LEN` で求める。チャート全体で 5 時間の窓を覆う間隔で、既定のチャート長 12 では 1500。上限 20 でも 900 で、下限 60 を下回らない (範囲が逆転しない)
  - 呼び出しは `RATE_CHART_LEN` → `POLL_INTERVAL_MAX_SEC` の計算 → `POLL_INTERVAL_SEC` の順に置く
  - 非数値･空･負値は既定値 (12 / 300 / 900) に戻す。既定値はこの呼び出しの引数だけに置く
  - 9 桁以上は比較せずに上限へ丸める
  - 先頭の 0 は `10#` で 10 進数に直す (`08` → `8`)
  - command substitution を使わず、`printf -v` で変数へ直接書き戻す
- 外すと何が起きるか:
  - 間引きの比較は算術式なので、`0` や負値でも構文エラーにならず、間引きが無効になる。`GIT_FETCH=1` では描画のたびに `git fetch` が起動し、rate 履歴は毎回更新されてチャートが傾向を示さなくなる
  - 9 桁以上の判定を外すと、整数範囲を超える値で `[ -lt ]` がエラー終了 (status 2) し、丸めを素通りする
  - 比較を `[[ ]]` に替えると、`[[ ]]` は値を算術式として評価するため、`a[$(cmd)]` のような conf の値の中のコマンドを実行しうる。`[ ]` は整数でなければエラーで終わるだけなので、検証 (`case`) の後でも `[ ]` を使う
  - 既定値を settings ブロックの `${X:-既定値}` と 2 か所に書くと、片方だけ変えたときに空の値と不正な値で戻る先が食い違う
  - `10#` の正規化を外すと、`RATE_CHART_LEN=08` が `$(( ))` や `for (( ))` で `value too great for base` のエラーになる (`POLL_INTERVAL_SEC` などは `[ ]` でしか比較しないので、正規化しなくても出力は変わらない)
  - 順序を入れ替えて `RATE_CHART_LEN` の clamp より前に上限を求めると、丸める前の値 (`0` や `abc`) で割り算をしてエラーになるか、範囲外のチャート長に合わせた上限になる
- 守っているテスト:
  - 挙動: `clamp-zero-interval` (git-fetch-behavior)、`poll-max-follows-chart-len` / `poll-max-default` / `poll-clamp-zero` / `poll-invalid-default` (rate-history-behavior)
  - 出力: `82-config-invalid-values`、`85-config-huge-interval`、`128-rate-chart-len-clamp-zero`〜`134-rate-chart-len-crlf`
  - 両版の一致: `tests/script-parity.sh` の `block:interval-clamp`

既定値はレンジ内にあるため、clamp は既定の出力を変えません。丸めは警告を出さずに行い、描画を続けます (履歴ディレクトリの安全性チェックと同じ｢無効値ならフォールバックして表示は続ける｣方針です)。

### 履歴ディレクトリの安全性チェック

- 箇所: ｢履歴ディレクトリ｣セクション (`HISTORY_DIR`)
- 何をしているか:
  - 既定の `/tmp/claude-statusline-<uid>/` を作り、mode 700 にする
  - mkdir / chmod の前に、既存のパスが symlink なら履歴を無効にする
  - 作成後に｢symlink でない｣｢ディレクトリである｣｢自分の uid が所有している｣｢mode が 700｣を確認し、満たさなければ `HISTORY_DIR` を空にする
  - 無効になっても statusline の描画は続ける (rate チャートは履歴なしで表示する)
- 外すと何が起きるか: `/tmp` は他のユーザーも書けるため、他人が事前に用意したディレクトリや symlink を掴み、履歴やマーカーの読み書きを横取りされる。`CLAUDE_STATUSLINE_HISTORY_DIR` で symlink が渡された場合に、chmod がリンク先の権限を変えてしまう
- 守っているテスト: `48-rate-rightmost-no-history` (symlink を渡して無効化経路を通す)。uid と mode の確認はテストなし

### ブランチ取得の空 `cwd` ガード

- 箇所: main のブランチ取得 (`[ -n "$cwd" ]`)
- 何をしているか: `cwd` が空のとき、および git が無いときは git を呼ばない
- 外すと何が起きるか: `git -C ""` はカレントディレクトリを対象にするため、statusline を起動したディレクトリの無関係なブランチが表示される
- 守っているテスト: テストなし。`73-cwd-empty-no-dir` は空の `cwd` を扱うが、テスト用の fake git は規約の無いパスを git 外として扱うので、ガードを外しても検出できない

### 描画経路にネットワーク I/O と余分な git 呼び出しを入れない

- 箇所: `git_ahead_behind` と main の git 呼び出し
- 何をしているか: ahead/behind は `rev-list` だけで求め、同期の `git fetch` は呼ばない。detached 判定や directory 名の取得のために git を追加で呼ばない
- 外すと何が起きるか: 同期の fetch は数秒から数分かかることがあり、その間 statusline が更新されない。git の呼び出しを 1 つ足すごとに、描画のたびの fork が 1 つ増える
- 守っているテスト: テストなし (fake git は fetch を即座に返すため、同期 fetch を足しても出力は変わらない)。`GIT_FETCH=1` で描画結果が変わらないことは `67-git-fetch-ahead` / `68-git-fetch-detached` / `69-git-fetch-no-upstream` で確認している

### `git_ahead_behind` の `*` 分岐

- 箇所: `git_ahead_behind` の rev-list 失敗時の分岐と第 2 引数 `is_detached`
- 何をしているか: rev-list が失敗したら、detached なら無色の `*`、それ以外なら青の `*` を返す。ahead･behind がともに 0 のときだけ空を返す
- 外すと何が起きるか: 分岐を消すと、upstream の無いブランチと同期済みのブランチが同じ表示になる。無色の `*` を `$(...)` で受けずに出すと、`static` の末尾改行が混ざって 1 行目が崩れる
- 守っているテスト: `32-branch-detached`、`38-diff-detached`、`60-ab-ahead`、`61-ab-behind`、`62-ab-diverged`、`63-ab-synced`、`64-ab-no-upstream`、`65-ab-with-diff`、`66-ab-no-upstream-blue-star`

### `maybe_git_fetch` の入口ガード

- 箇所: `maybe_git_fetch` 冒頭の `[ "$GIT_FETCH" = "1" ] || return` と、repo / branch / detached / `HISTORY_DIR` の確認
- 何をしているか: 既定の `GIT_FETCH=0` では何もせずに戻る。detached、および upstream の無いブランチでは fetch を投げない
- 外すと何が起きるか: オプトインしていない利用者の環境でネットワークアクセスが発生する
- 描画コスト: `GIT_FETCH=1` のときは、間引きで fetch を投げない通常経路でも描画ごとに `cksum` / `date` / `stat` の 3 fork が増える。`GIT_FETCH=0` (既定) では入口で return するため増えない
- 守っているテスト: `60-ab-ahead` (`fetch_marker: absent`)、`67-git-fetch-ahead` (`present`)、`68-git-fetch-detached` / `69-git-fetch-no-upstream` (`absent`)

### fetch 子プロセスの fd 付け替え

- 箇所: `maybe_git_fetch` の `( ... git fetch --quiet >/dev/null 2>&1 </dev/null & )`
- 何をしているか: fetch を投げっぱなしのサブシェルで起動し、stdout･stderr･stdin の 3 つを `/dev/null` に付け替える
- 外すと何が起きるか: 親の command substitution や statusline の呼び出し元が、子プロセスのパイプの EOF (つまり fetch の完了) を待つ。fetch が終わるまで描画が返らず、数秒から数分止まる
- 守っているテスト: `non-blocking` / `fetch-invoked` (git-fetch-behavior)、`tests/script-parity.sh` の `static:fetch-fd-redirect`

### 認証プロンプトを抑える 4 つの環境変数

- 箇所: fetch 子プロセスに渡す `GIT_TERMINAL_PROMPT=0` / `GIT_ASKPASS=/bin/true` / `SSH_ASKPASS=/bin/true` / `SSH_ASKPASS_REQUIRE=force`
- 何をしているか: fetch が認証を求めたとき、端末に触れずにすぐ諦めさせる
- 外すと何が起きるか:
  - fd 0/1/2 を付け替えても、制御端末 (`/dev/tty`) は子プロセスに残る
  - OpenSSH は端末があると `SSH_ASKPASS` を使わずに `/dev/tty` を直接開くため、`SSH_ASKPASS_REQUIRE=force` が無いとパスフレーズやホスト鍵の確認が Claude Code の画面に割り込み、キー入力を奪う
  - `GIT_TERMINAL_PROMPT=0` が抑えるのは git 自身の HTTPS プロンプトだけで、ssh には効かない
  - どれか 1 つが欠けても、いずれかの経路でプロンプトが出る
- 守っているテスト: `tests/script-parity.sh` の `static:no-prompt:maybe_git_fetch:*` (`maybe_git_fetch` に記述が残っていることの静的確認)。プロンプトが実際に出ないことの動作テストはなし

ssh-agent に鍵が無い環境では fetch が黙って失敗し、`↓behind` は更新されません。画面を保護することを優先した結果で、意図した挙動です。

### マーカー書き込み失敗時に fetch しない

- 箇所: `maybe_git_fetch` の `if ! { true > "$marker"; } 2>/dev/null; then`
- 何をしているか: 間引き用マーカー `${HISTORY_DIR}/fetch-<cwd の cksum>` を書けなかったら、ロックを解放して fetch を投げずに戻る
- 外すと何が起きるか: 書けないまま fetch を投げると間引きの基準時刻が残らず、次の描画も同じ経路に入る。statusline は数秒ごとに呼ばれるので、fetch が描画のたびに起動する。古い mtime のまま書き込み不可のマーカーが残っている場合や、同名のディレクトリがある場合に起こる (mtime 判定は通り、`HISTORY_DIR` 自体は書けるのでロックも取れてしまう)
- 守っているテスト: `marker-unwritable` (git-fetch-behavior)

書き込みには `:` ではなく `true` を使います。`:` は POSIX の special built-in で、sh 互換モードではリダイレクトに失敗するとシェルごと終了するためです。エラー出力の抑制は `{ ...; } 2>/dev/null` とブロックごと囲みます。リダイレクトは左から順に処理されるため、`true > "$marker" 2>/dev/null` と後ろに書くと fd 2 を差し替える前に失敗し、`Permission denied` が端末に出ます。

テストでは書き込めない状態をマーカーと同名のディレクトリで作ります。`chmod 400` は root で動く CI では書けてしまうためです。

### marker → unlock → spawn の順序

- 箇所: `maybe_git_fetch` の後半
- 何をしているか: マーカーを書き、ロックを解放してから fetch を起動する。マーカーを書いた時点で他のプロセスは mtime 判定で弾かれるので、ロックはそこで役目を終える
- 外すと何が起きるか: Linux 版で `spawn → unlock` の順にすると、named fd は close-on-exec されないため `( ... & )` の子に複製が渡り、fetch が終わるまで flock が保持される。その間、他の statusline はロック待ちになる。先に閉じれば子は fd を受け取らない
- 守っているテスト: `lock-released` (git-fetch-behavior)。fd の継承を実際に検証できるのは Linux 版だけで、macOS 版ではロックディレクトリの消し忘れを検出する

両版で同じ順序にしておくと、実装の違いをロック機構 (flock / mkdir) だけに閉じ込められます。

### pr 子プロセスの fd 付け替えと環境変数

- 箇所: `pr_spawn_refresh` の `( ... pr_refresh_child ... >/dev/null 2>&1 </dev/null & )` と、その直前の `unset` / `export`
- 何をしているか: 子プロセスを投げっぱなしで起動して fd 0/1/2 を `/dev/null` に付け替え、`gh` 用に次の環境変数を整える
  - 設定する: `GH_PROMPT_DISABLED=1`、`GH_NO_UPDATE_NOTIFIER=1`、`GH_NO_EXTENSION_UPDATE_NOTIFIER=1`。`gh` が内部で git を呼ぶことがあるため、fetch と同じ git 用の 4 つも設定する
  - 外す: `GH_REPO` (cwd ではなくそのリポジトリを問い合わせてしまう)、`GH_FORCE_TTY` と `CLICOLOR_FORCE` (出力が端末向けの書式や色付きになり、キャッシュの形が壊れる)
  - 残す: `GH_TOKEN` / `GITHUB_TOKEN` / `GH_HOST` / `GH_ENTERPRISE_TOKEN` (ユーザーが選んだ認証方法と接続先)
- 外すと何が起きるか: fd を付け替えないと、描画が `gh` の完了を待って止まる ([fetch 子プロセスの fd 付け替え](#fetch-子プロセスの-fd-付け替え) と同じ)。環境変数を外すと、認証や更新通知の表示が Claude Code の画面に割り込んだり、別のリポジトリの PR を表示したりする
- 守っているテスト: `non-blocking` / `env-sanitized` (pr-status-behavior)、`tests/script-parity.sh` の `static:pr-gh-env:*` / `static:no-prompt:pr_spawn_refresh:*` / `static:pr-fd-redirect` (片方の版だけの変更は `block:pr-common` で検出する)

### pr の marker → unlock → spawn の順序とマーカー書き込み失敗

- 箇所: `maybe_pr_refresh` の後半
- 何をしているか: ロック取得 → 間隔の再確認 → マーカーの mtime 更新 → ロック解放 → 子プロセス起動、の順に行う。マーカーを書けなければ子プロセスを起動しない
- 外すと何が起きるか: [marker → unlock → spawn の順序](#marker--unlock--spawn-の順序) と [マーカー書き込み失敗時に fetch しない](#マーカー書き込み失敗時に-fetch-しない) と同じ。Linux 版では取得が終わるまで flock が残り、マーカーを書けないまま起動すると描画のたびに `gh` が起動する
- 守っているテスト: `marker-unwritable` / `throttle` (pr-status-behavior)。flock が子に渡らないことは fetch の `lock-released` と同じ構造で、pr 側には専用のテストはない

### pr の `.inflight` の後始末を trap にしない

- 箇所: `pr_refresh_child` の `mkdir` → `pr_refresh_run` → `rmdir`
- 何をしているか: `.inflight` を作れたときだけ取得し、終わったら `rmdir` する。後始末を EXIT の `trap` にしない
- 外すと何が起きるか: macOS の `/bin/bash` 3.2 では、`&` で起動したサブシェルに張った EXIT の `trap` が走らない。`trap` に任せると `.inflight` が残り、`PR_INFLIGHT_STALE_SEC` (90 秒) が過ぎるまで次の取得が起動しない。kill などで `rmdir` まで届かなかった印も、同じ 90 秒で消える
- `rmdir` するのは、`.inflight` の mtime が作ったときと同じ (自分の印) ときだけ。止まっている間に親が古い印として消し、次の子が作り直した印を消すと、取得が重なる
- 守っているテスト: `throttle` / `branch-switch` / `no-overwrite-by-older` など、取得の完了を `.inflight` の消滅で待つケース (pr-status-behavior)、`single-flight` / `stale-inflight`

### pr のキャッシュの読み取りと値の検証

- 箇所: `pr_cache_load`、`pr_is_positive_int`、`format_pr`
- 何をしているか: キャッシュを信用せず、番号と状態が不正なら列ごと省略し、ほかのフィールドは想定外の値を無いものとして扱う。URL は `https://` で始まり、残りが URL に使う ASCII の英数字と記号だけのときに OSC 8 に埋め込む。許す文字は `[[:cntrl:]]` や `A-Z` を使わずに列挙する。文字クラスや範囲が含む文字は OS のロケール実装で違い (macOS では U+202E も `[[:cntrl:]]` に当たる)、両版の出力が食い違いうるため
  - 番号とコメントの件数は、同じ `pr_is_positive_int` (先頭が 0 でない 9 桁以内の正の整数) で確かめる。件数が 0 か不正なら件数を出さない
- 外すと何が起きるか: キャッシュは `/tmp` 配下のファイルで、壊れることも、`gh` の出力が想定と違うこともある。URL に ESC や BEL が混ざると、OSC 8 が途中で閉じて後続の列の表示が崩れる
- 守っているテスト: `108-pr-stale`〜`112-pr-invalid-optional-fields`、`115-pr-url-non-ascii`、`future-fetched-at` / `comment-count` (pr-status-behavior)

### rate のハイフン区切り

- 箇所: `format_limit`
- 何をしているか: 色が付く残量のとき `chart NN% - HH:MM` とスペース･ハイフン･スペースで区切る。括弧は使わない。weekly も同じ関数で `spark NN% - Mon` と区切る
- 外すと何が起きるか: 表記が SPEC (` - ` 区切り、括弧なし) と食い違い、`02-rate-warning-with-reset` の `not_contains: (22:13)` などが失敗する
- 守っているテスト: `02-rate-warning-with-reset` (`not_contains: (22:13)`)、`03-rate-warning-no-reset`、`05-rate-danger`、`06-rate-critical`、`24`〜`29` の境界ケース、`137-weekly-warning-with-reset` (`not_contains: (Tue)`)、`138-weekly-warning-no-reset`

### 2 行目のトークンは空でも積む

- 箇所: `build_layout "${LAYOUT_LINE2}|${LAYOUT_LINE2_TOKENS}" "|${LAYOUT_LINE2_TOKENS}|" 1`
- 何をしているか: 2 行目は値が空でも列を落とさない。書かれなかったトークンは末尾に補う
- 外すと何が起きるか: 第 3 引数を `0` にすると｢2 行目は常に出す｣が成り立たなくなる。ただし `format_limit` と `model_ctx` は常に空でない値を返す (使用率が欠落しても `<チャート> --` / `· --`) ので、今のテストは通ったまま不変条件だけが失われる
- 守っているテスト: 補完は `89-layout-line2-reorder`、`93-layout-line2-partial`、`91-layout-unknown-token`、`145-layout-line2-weekly-first`。weekly の欠落時に列が残ることは `143-weekly-missing`。空でも積むこと自体はテストなし

### 1 行目の省略と改行の位置

- 箇所: main 末尾の `if [ ${#line1_parts[@]} -gt 0 ]` と `printf '%s\n'`
- 何をしているか: 1 行目に要素があるときだけ｢結合結果 + 改行｣を出す
- 外すと何が起きるか: 要素が無いのに改行を出すと、空行が statusline の高さを 1 行分占める。改行を 2 行目の先頭に移すと、1 行目が無いときに先頭に空行が出る。`join_by` を無条件に 2 回呼ぶ形も同じ結果になる
- 守っているテスト: `72-cwd-root-no-dir`、`73-cwd-empty-no-dir`、`74-show-cwd-off-git-outside`、`77-show-cwd-off-drops-line1`、`90-layout-line1-none` (いずれも `no_line2`)

### rate チャートの土台と右端差し替え

- 箇所: main の `rate_chart=$(history_chart /dev/null)` と `spark_of rate_now_spark "$rate_remaining"` と `rate_chart="${rate_chart:0:$((RATE_CHART_LEN - 1))}${rate_now_spark}"`
- 何をしているか: [rate チャートの土台と右端の現在値](#rate-チャートの土台と右端の現在値) を参照
- 外すと何が起きるか: 差し替えを外すと、右端も間引かれた古い値になり、リセット直後の残量が反映されない。土台の初期化を `HISTORY_DIR` の分岐より後に移すか外すと、履歴が無効なときに `rate_chart` が空になり、右端が描かれない
- 守っているテスト: `47-rate-rightmost-live` / `126-rate-chart-len-seed-pad` (seed で古い履歴を仕込む)、`48-rate-rightmost-no-history` / `127-rate-chart-len-no-history` (履歴を無効化する)

### 色定義ブロックの両版一致

- 箇所: 両版の｢カラースキーム｣ブロック (`_fg` と `case "$COLOR_SCHEME"`)
- 何をしているか: 同じ RGB 値を両版で同じ書き方で定義する
- 外すと何が起きるか: 片方だけ値を変えると、同じ入力で両版の色が食い違う。回帰テストは実行できる側の版しか動かさない (CI では Linux 版のみ、macOS では Linux 版が bash 4.1+ と `flock` の有無で skip される) ため、出力比較だけではドリフトに気づけない
- 守っているテスト: `tests/script-parity.sh` の `block:color-scheme`。light の値は `81-config-light-scheme` / `84-config-crlf` で一部を確認している

### 点滅属性

- 箇所: `limit_color` / `ctx_color` の致命段 (`printf 'static \033[5m%s' "$COLOR_error"`)
- 何をしているか: [rate / weekly / ctx の 3 階調と点滅](#rate--weekly--ctx-の-3-階調と点滅) を参照
- 外すと何が起きるか: 致命段と危険段が色だけで区別されることになり、見た目の段差が小さくなる
- 守っているテスト: `06-rate-critical`、`10-ctx-critical`、`23-ctx-boundary-90`、`29-rate-boundary-remaining-5`、`140-weekly-critical`

### effort の別 paint と `∙`

- 箇所: main の effort 連結 (`effort_field=$(paint "$effort" $effort_effect)` と `SHOW_MODEL_NAME` の分岐)
- 何をしているか: [effort の連結と区切り](#effort-の連結と区切り) を参照
- 外すと何が起きるか: model と effort を 1 回の `paint` で塗ると色が混ざる。`∙` を `paint` に含めると、`max` のときに `∙` が rainbow 循環に入り、語句の色がずれる。`[ -n "$effort" ]` を外すと、effort 非対応モデルで余分な区切りが出る
- 守っているテスト: `51-effort-low`〜`55-effort-max-rainbow`、`56-effort-absent`、`57-model-off-effort`、`58-model-off-no-effort`、`59-model-on-effort-opus`

### directory の末尾スラッシュ除去

- 箇所: main の `dir_path` の `while` ループ
- 何をしているか: [directory 列](#directory-列) を参照
- 外すと何が起きるか: 末尾にスラッシュの付いた `cwd` で、directory 列が丸ごと消える
- 守っているテスト: `78-cwd-trailing-slash`、`72-cwd-root-no-dir`

### 未追跡ファイルの行数取得の上限

- 箇所: `git_diff_stat` の `UNTRACKED_DIFF_LIMIT`
- 何をしているか: 未追跡ファイルの行数取得を 50 件までに抑え、それを超えた分はファイル数だけを数える
- 外すと何が起きるか: 未追跡ファイルが大量にある作業ツリーで、ファイルごとの `git diff --no-index` が描画を遅くする
- 守っているテスト: テストなし (未追跡ファイルの集計そのものは `42-diff-untracked-only`〜`45-diff-untracked-subdir`)

### `highlight` は空の文字列を塗らない

- 箇所: `highlight` の `[ -n "$2" ] || return 0`
- 何をしているか: 空の文字列は `COLOR_text` で囲まずに空のまま返す
- 外すと何が起きるか: 空の session や `SHOW_CWD=0` の directory が ESC だけの空でない値になり、1 行目に余分な ` | ` が出る。1 行目の列がすべて空のときも 1 行目が出るようになる。`HIGHLIGHT` が既定 (空) のときは塗らないので、既存のケースでは表面化しない
- 守っているテスト: `163-highlight-empty-columns`、`164-highlight-empty-line1`

### トリムしてから `highlight` に通す

- 箇所: `layout_token` の branch / session と、main の model の組み立て
- 何をしているか: `truncate_branch` / `truncate_label` でトリムした後の文字列を `highlight` に渡す
- 外すと何が起きるか: 塗ってからトリムすると ANSI エスケープが文字数に数えられ、トリム位置が変わる。`\033[0m` が切り落とされて色が後続の列へ漏れることもある。`HIGHLIGHT` が既定 (空) のときは塗らないので、既存のケースでは表面化しない
- 守っているテスト: `152-highlight-branch-trim-head`、`153-highlight-branch-trim-middle`、`154-highlight-session-trim`

### `HIGHLIGHT` の組み立てと塗る順序

- 箇所: main の `hl_set` の組み立てと、`format_ctx` / `format_limit` / model / `layout_token` での `highlight` の呼び出し
- 何をしているか: [ハイライト (`HIGHLIGHT`)](#ハイライト-highlight) を参照
- 外すと何が起きるか: `hl_set` を要素の組み立てより後に置くと、その要素のハイライトが黙って効かなくなる。`format_limit` で `chart_out` に移さずに時刻を通すと、チャートの代わりに時刻が 2 回出る。branch の `case` を外すと `/` の無い名前が `main/main` になる
- 守っているテスト:
  - `146-highlight-all-dark`〜`170-highlight-pr-comments`
  - 順序は `149-highlight-directory-only`、`chart_out` は `160-highlight-rate-reset-only`、branch の `case` は `150-highlight-branch-no-slash` / `151-highlight-branch-detached`
  - 両版のずれは `tests/script-parity.sh` の `block:paint` / `block:pr-common` / `block:format-layout` / `block:main-render`

## 採らなかった案と経緯

### 1 行構成へ戻す設定

2 行構成に移ったあと、1 行構成へ戻す設定は設けていません。戻せる設定を用意すると、両方の期待値をテストで維持し続ける必要があるためです。`LAYOUT_LINE1` で 1 行目の要素をすべて外すと 1 行目は出なくなりますが、これは git 外などで 1 行目が空になるのと同じ｢1 行目の省略｣で、1 行目の要素を 2 行目に戻すものではありません。Claude Code の statusline は、出力の各行をそのまま 1 行として描画します。

### ブランチ名の先頭セグメントだけを残す / 左から削る

ブランチ名の中間省略では、`feature/…/yyy` のように先頭のセグメントだけを残す形や、`…/yyy` のように左から削る形は採っていません。前者は先頭のセグメントが長いと末尾に使える幅が減り、後者は `feature/` や `hotfix/` のような種類の手がかりが消えます。先頭を 25 文字に収まるだけ残し、`/` の位置にそろえずに切るのは、セグメントの区切りを探す処理を足さずにパラメータ展開だけで済ませるためです。

### セッション名のトリム長 (20 → 40 文字)

セッション名は以前 20 文字でトリムしていましたが、2 行構成にして 1 行目の末尾へ移したことで横幅に余裕ができたため、40 文字に広げました。

### directory 列の取得元

directory 列は `workspace.current_dir` の basename から取ります。次の案は採りませんでした。

- `repo.name` を優先する: git 外では欠落するため、分岐が増える
- `project_dir` を優先する: Claude Code の起動ディレクトリなので、セッション中に `cd` すると表示がずれる

### SSH の `BatchMode=yes`

バックグラウンド fetch の認証を抑えるのに、`GIT_SSH_COMMAND` で `BatchMode=yes` を指定する方法は使っていません。利用者が `core.sshCommand` で設定した独自の ssh 設定を上書きし、黙って壊してしまうためです。代わりに askpass 系の環境変数で抑えています。

### 描画経路での同期 fetch

`↓behind` を最新にするために描画のたびに fetch する方法は採りませんでした。ネットワーク待ちで描画が止まるためです。必要な場合は `GIT_FETCH=1` でオプトインし、別プロセスで投げっぱなしにした fetch の結果を次回以降の描画で反映します。

### fetch の間引きの単位

間引きのマーカーは `cwd` の `cksum` をキーにしています。repo のルート単位にするには `git rev-parse --show-toplevel` などの呼び出しが要るため、cwd 単位のままにしています。そのため、同じリポジトリの別のサブディレクトリや worktree は別々に数えられ、開いている数に比例して fetch の回数が増えます。`cksum` はバイト列の CRC なので、ロケールやマルチバイトのパスに影響されません。

### PR の状態を独立したレイアウトのトークンにする

PR の状態を `LAYOUT_LINE1` の独立したトークンにする案は採りませんでした。PR はブランチに紐付く情報なので、branch 列の中 (diff の右) に半角スペースで区切って置き、有効化は `GIT_FETCH` と同じ形のフラグ `PR_STATUS` で行います。`gh` を起動するのは `PR_STATUS=1` で branch 列を組み立てるときだけなので、branch をレイアウトから外せば `gh` も起動しません。

### stdin の `pr` フィールド

Claude Code が statusline に渡す `pr` フィールドは使いません。フッターの PR バッジと同じ情報源で、同じセッションで PR を切り替えても最初の PR に固定されたまま更新されません。また open の PR があるときしか存在せず、CI の情報もありません。`gh` で自前に取得すれば、同じセッションでも正しい PR を表示できます。

### PR の状態を下線色 (SGR 58) で表す

Claude Code のフッターの PR バッジは下線に色を付けていますが、PR の状態表示は `#<番号>` の文字色で表し、下線 (SGR 4) は文字と同じ色のまま付けます。下線色 (SGR 58) を Claude Code の statusline 描画がそのまま通すかを確認できていないためです。

### `gh pr list --json` とほかのコメントの数え方

`gh pr list --json` / `gh pr view --json` は使いません。どちらも `comments` で返すのは会話タブのコメントだけで ([cli/cli#11477](https://github.com/cli/cli/issues/11477))、行コメントや本文付きのレビューを含みません。件数を知りたいだけなのに本文まで取るため、重くもなります。

コメントの件数は GraphQL の `totalCommentsCount` で取ります。GitHub が数えた件数 (会話のコメント、行コメントとその返信、本文付きのレビュー) を 1 つの値で返し、PR 一覧の吹き出しアイコンの数と一致します。PR の選択に使うほかの値と合わせて、1 回の問い合わせ (コスト 1) で取れます。次の数え方は採っていません。

- REST の `GET /repos/{owner}/{repo}/pulls/{number}` の `comments` と `review_comments`: PR の番号が先に要るため、ブランチから PR を探す問い合わせと合わせて 2 回になる。本文付きのレビューも数えない
- GraphQL で種類ごとの `totalCount` を足す (`comments` + `reviewThreads` + `reviews`): `reviewThreads.totalCount` はコメントではなくスレッドの数なので、返信を数えない。スレッドごとのコメント数を足すにはノードを `first: N` で取る必要があり、上限を超えると数え漏れる。レビューは本文の有無で絞り込めない

### `statusCheckRollup` の各チェックを自前で集約する

CI 記号は `statusCheckRollup.state` (GitHub が集約した値) をそのまま使い、個々のチェックを自前で集約しません。自前で集約すると、失敗したジョブを再実行して成功させても古い失敗が残って `✗` のままになるうえ、取得件数の上限を超えたチェックが落ちるためです。

### rate チャートの長さと履歴の設定

- `HISTORY_LEN` をそのまま公開する: `HISTORY_LEN` は｢conf で変えられない内部定数｣の例として SPEC とテスト `82` が保証していたため、同じ名前を公開すると意味が逆になる。公開する名前は `RATE_CHART_LEN` にし、`HISTORY_LEN` は廃止した
- 履歴ファイルを表示長で切り詰める: 伸ばした直後は `·` が並び、短いチャートのセッションが長いチャートのセッションの履歴を削る。保存件数は `RATE_CHART_LEN_MAX` で固定している ([履歴ファイルと排他制御](#履歴ファイルと排他制御))
- `POLL_INTERVAL_SEC` の上限を固定値にする / 上限をなくす: 前者はチャート長を変えると根拠 (チャート全体で 5 時間を覆う) がなくなり、後者は間引きの意味がなくなる値も通る
- `POLL_INTERVAL_SEC` や `RATE_CHART_LEN` に env の上書き口を付ける: 全セッション共通の履歴ファイルの間引きの基準がセッションごとに変わり、最も短い間隔のセッションが追記を支配する。チャート長も `POLL_INTERVAL_SEC` の上限を決めるため同じ理由で付けない。env を付けたうえで上限だけ env の効かない値から決める案も、チャート長と上限の対応が崩れて上限の根拠がなくなる

### weekly の表示

- 書いたときだけ weekly を出す: `build_layout` にトークンごとの例外が入り、配布テンプレートを写した `LAYOUT_LINE2="model_ctx|rate"` の利用者には新しい列が出ない。2 行目の｢書かなかったトークンは末尾に補う｣規則に従わせた
- 使用率が欠落したら列ごと省く: 既存の期待値は変えずに済むが、｢2 行目は空でも積む｣が崩れる
- rate と同じ履歴チャートにする: 要件は現在の残量だけで、5 時間用の間引き間隔で 7 日の窓を記録しても傾向を示さない
- 曜日に時刻を添える: 曜日だけでは、リセットが今日と同じ曜日のとき (24 時間以内か 6 日以上先か) を区別できないが、要件どおり曜日だけにして SPEC に制約として書いた

### ハイライトの実装

- 色を決める関数 (`ctx_color` / `limit_color` / `model_color`) の無色の戻り値をハイライト色にする: `format_ctx` と `format_limit` は｢色が付いているか｣(effect 指定が `static` でないか) で数値 `NN%` を出すかを決めているため、ハイライトしただけで数値が出るようになる。無色のときは要素ごと (チャートと時刻を別々)、色付きのときは全体を 1 色で塗るので、塗る単位も合わない
- model の｢無色なら `highlight`、色付きなら `paint`｣を汎用のヘルパーにする: 分岐が 1 か所にしか無いので、ヘルパーを足しても重複は減らない
- `HIGHLIGHT` をトークンごとの真偽値の設定 (`HIGHLIGHT_BRANCH=1` など) にする: 設定の数がトークンの数だけ増え、conf の読み込みブロックの一覧も増える。`LAYOUT_LINE*` と同じ書式の 1 変数にし、分割も `split_tokens` で共有した
- 対象外にした無色の要素 (detached の `*`、draft / closed の PR 番号、`--` など) と理由は [SPEC.md](SPEC.md#ハイライト-highlight) にまとめている

### その他

次の案も採っていません。理由はそれぞれのリンク先に書いています。

- upstream 未設定と異常系の区別、ahead の緑: [ahead/behind と `*` の判定](#aheadbehind-と--の判定)
- conf の JSON / YAML 化: [設定ファイルの読み込みブロック](#設定ファイルの読み込みブロック)
- macOS 版での `flock`: [macOS 版と Linux 版の差分](#macos-版と-linux-版の差分)
- レイアウトでの連想配列: [レイアウトのトークン設計](#レイアウトのトークン設計)

## テストで守れていない箇所

次の項目は、外したり変えたりしても現在のテストでは検出されません。変更するときはレビューで確認してください。

- 依存コマンド確認のメッセージ
- 履歴ディレクトリの uid と mode の確認
- `HIGHLIGHT` で塗る範囲が、実際の Claude Code の statusline で読みやすいこと (`COLOR_SCHEME` とテーマが食い違うと読めなくなる。`npm run preview` で目視で確認する)
- ブランチ取得の空 `cwd` ガード
- 描画経路に同期 fetch や git 呼び出しを足していないこと
- 認証プロンプトが実際に出ないこと (記述の有無は `tests/script-parity.sh` で確認)
- 2 行目のトークンを空でも積むこと
- `UNTRACKED_DIFF_LIMIT` による上限
- 設定ファイルのパスへの `./` の前置
- ロケール固定 (記述の有無は `tests/script-parity.sh` で確認。出力比較は実行環境のロケールに左右される)
- PR の状態表示の子プロセスで、`gh` や git の認証プロンプトが実際に出ないこと (記述の有無は `tests/script-parity.sh` で確認)
- PR の状態表示の下線 (SGR 4)、取り消し線 (SGR 9)、OSC 8 のリンクが、実際の Claude Code の statusline で描画されること (端末と Claude Code の描画に依存するため、目視で確認する)
- 実際の GitHub の応答の形 (fake gh は応答の JSON を固定で返す。クエリと `--jq` が実際の `gh` で動くことは手元で確認する)
- `--jq` の式が `gh` 組み込みの gojq で動くこと (fake gh は jq で評価する。jq にしかない関数を使っても検出されない)
