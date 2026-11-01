日本語 | [🌍 English version here](./README.en.md)

# テスト

macOS 版 (`statusline-macos.sh`) と Linux 版 (`statusline-linux.sh`) が同じ入力に対して同じ出力を返すことを確かめるテスト群です。出力の仕様は [docs/SPEC.md](../docs/SPEC.md)、各防御コードとそれを守るテストの対応は [docs/DESIGN.md](../docs/DESIGN.md)、開発環境の準備は [docs/DEVELOPMENT.md](../docs/DEVELOPMENT.md) を参照してください。

## ハーネスの役割

| スクリプト | 実行方法 | 役割 |
| --- | --- | --- |
| `regression.sh` | `npm run test:regression` | fixture を両スクリプトに流し、出力を assertion と突き合わせる |
| `git-fetch-behavior.sh` | `npm run test:fetch` | `GIT_FETCH=1` のバックグラウンド fetch の挙動を検証する |
| `pr-status-behavior.sh` | `npm run test:pr` | PR の状態表示のバックグラウンド取得の挙動と、`--jq` による変換を検証する |
| `rate-history-behavior.sh` | `npm run test:history` | rate 履歴ファイルの書き込み (初回の埋め込み、間引き、保存件数) と、間引き間隔の丸めを検証する |
| `e2e-preview.sh` | `npm run preview` | 実際の ANSI 色付き出力を端末に流し、目視で確認する |
| `script-parity.sh` | `npm run test:parity` | 両スクリプトの共通ブロックの一致と、必要な記述が残っていることを静的に確かめる |
| `translation-parity.sh` | `npm run test:translation` | 日本語のドキュメントと英語版 (`*.en.md`) の構造が食い違っていないことを静的に確かめる |

`npm test` は `test:regression`、`test:fetch`、`test:pr`、`test:history`、`test:parity`、`test:translation` を順に実行します。`e2e-preview.sh` は合否を判定しないため `npm test` には含まれません。

### regression.sh

- `fixtures/*.json` を 1 件ずつ両スクリプトの標準入力に渡し、同名の `assertions/*.txt` で出力を検証します。assertion ファイルが無い fixture は失敗として数えます。
- 出力は `lib/escape-ansi.sh` で ESC (0x1b) を文字列 `\e` に、BEL (0x07。OSC 8 の終端) を文字列 `\a` に置き換えてから比較します。
- `TZ=UTC` で実行するため、リセット時刻 (`HH:MM`) は UTC で決まります。
- fixture 以外に、Linux 版冒頭 20 行に bash 4.1+ ゲートのコード片がそのまま残っていることを静的に確認するチェック (`bash-4.1-gate`) が 1 件あります。

### git-fetch-behavior.sh

fetch は投げっぱなしの非同期処理で描画出力に現れないため、fake git のフック (後述) を使って出力以外の不変条件を確かめます。入力は `fixtures/67-git-fetch-ahead.json` (upstream あり) で固定です。ケースは次の 6 つで、両版それぞれで実行します。

| ケース名 | 確かめること |
| --- | --- |
| `fetch-invoked` | fetch が実際に起動される |
| `non-blocking` | fetch が 5 秒かかっても描画は 3 秒未満で返る |
| `throttle` | 間引き間隔内の 2 回目の描画では fetch を投げない |
| `lock-released` | fetch の実行中にロックが残っていない (Linux 版は `flock -n`、macOS 版はロック dir の有無で確認) |
| `marker-unwritable` | 間引きマーカーを書けないときは fetch を投げない |
| `clamp-zero-interval` | conf に `GIT_FETCH_INTERVAL_SEC=0` を書いても下限へ丸められ、間引きが効く |

`marker-unwritable` は、マーカーと同名のディレクトリを先に作ることで書き込み失敗を再現します。`chmod` で書き込みを禁止する方法は、root で動く CI では書けてしまうため使っていません。

### pr-status-behavior.sh

PR の状態表示の取得も投げっぱなしの非同期処理のため、fake gh のフック (後述) を使って出力以外の不変条件を確かめます。各ケースは一時ディレクトリの中に fake git の規約を名前に埋めた実在のディレクトリを作り、それを `workspace.current_dir` として渡します。子プロセスは cwd に `cd` してから `gh` を呼ぶため、cwd が実在しないと取得まで進みません。ケースは次のとおりで、両版それぞれで実行します。

| ケース名 | 確かめること |
| --- | --- |
| `invoked` | `PR_STATUS=1` のときに `gh` が起動され、次の描画に PR が出る |
| `not-invoked-when-disabled` | `PR_STATUS=0` のときと、`PR_STATUS=1` でも branch 列を描画しないときは `gh` を起動せず、`pr-*` のファイルも作らない |
| `non-blocking` | `gh` が 5 秒かかっても、描画は 3 秒未満で返る |
| `throttle` | 間隔内の 2 回目の描画では `gh` を起動しない |
| `single-flight` | 取得の実行中 (`.inflight` がある) は、間隔を過ぎても次の `gh` を起動しない |
| `stale-inflight` | 90 秒より古い `.inflight` は消され、取得が再開される |
| `timeout` | `gh` が終わらなくても打ち切られ、`.inflight` が消える (`CLAUDE_STATUSLINE_TEST_PR_TIMEOUT_SEC=1` で 1 秒にする) |
| `no-overwrite-by-older` | 自分の開始時刻より新しい `fetched_at` のキャッシュがあれば、上書きしない |
| `branch-switch` | 同じ cwd でブランチを変えると別のキャッシュキーになり、前のブランチの PR を表示しない |
| `push-branch-name` | ローカル名と push 先の名前が違うとき、push 先の名前とオーナーで問い合わせる (URL の 3 形式) |
| `marker-unwritable` | マーカーを書けないときは `gh` を起動しない |
| `gh-failure-keeps-cache` | `gh` が非ゼロで終了したとき、キャッシュを書き換えず前回の表示を残す |
| `env-sanitized` | `GH_REPO` / `GH_FORCE_TTY` / `CLICOLOR_FORCE` が `gh` に渡らず、gh 用の 3 変数と git 用の 4 変数が設定され、`GH_TOKEN` は残る |
| `no-gh` | `gh` が PATH にないときは何も起動せず、列を省略する |
| `refresh-interval` | キャッシュの状態とマーカーの経過時間から、30 / 300 / 900 秒の間隔で起動する (前回の試行が失敗したときは 300 秒) |
| `not-invoked-without-prerequisites` | detached HEAD と、symlink の履歴ディレクトリ (無効になる) では `gh` を起動しない |
| `future-fetched-at` | `fetched_at` が現在より未来のキャッシュは表示せず、取得の結果で置き換える |
| `comment-count` | キャッシュのコメントの件数は、先頭が 0 でない 9 桁以内の正の整数のときだけ出す (`0`、`012`、10 桁、`-1` は出さない) |
| `early-on-change` | stdin の `pr` の署名が前回と変わった描画で、間隔を待たずに取得が 1 回だけ起動する (`review_state` だけの変化も含む) |
| `early-seen-missing` | `.seen` がないとき、`pr` があれば 1 回起動し、なければ起動せず `.seen` も作らない |
| `early-mismatch-persists` | stdin の `pr` とキャッシュが食い違ったままでも、起動し続けない (最低間隔が過ぎた後も) |
| `early-branch-switch` | ブランチを切り替えても、署名が同じなら起動しない。署名が変われば切り替え先のキーで起動する |
| `early-save-failure` | `.seen` を書けないときは前倒しで起動せず、マーカーも書き換えない。間隔が過ぎれば通常の取得は起動する。マーカーを書けないときも起動しない |
| `early-waits-inflight` | 取得の実行中は前倒しせず `.seen` も書かない。取得が終わった後の描画で起動する |
| `early-min-interval` | 前回の前倒しから 30 秒以内は前倒しせず `.seen` も書かない。過ぎた後に起動する。通常の取得の直後でも前倒しする |
| `early-seen-bad-time` | `.seen` の時刻が数字でない (空、`abc`、`0123`)、または未来なら、最低間隔は過ぎたものとみなす |
| `early-alternating` | 同じ `session_id` で署名が交互に変わっても、30 秒に 1 回を超えて起動しない |
| `early-two-sessions` | 同じブランチを開いた 2 つのセッションの署名が食い違っても、それぞれの最初の 1 回で止まる |
| `early-mr` | `pr.kind` が `mr` なら起動せず、`.seen` も作らない |
| `early-session-id` | `session_id` が空、許さない文字 (`/`、`.`、空白、非 ASCII) を含む、129 文字以上なら前倒しせず、`.seen` も作らない。`served:` で始まる値、数値、128 文字ちょうどは前倒しする |
| `early-stdin-robust` | 値に改行や制御文字を含む `pr` や `session_id`、オブジェクトでない `pr` (文字列、数値、配列、真偽値) でも、描画が `pr` も `session_id` もないときと一致し、`.seen` は 2 行のまま |
| `early-no-extra-commands` | 署名が変わらない描画と、最低間隔で見送る描画では、外部コマンドの起動が `pr` も `session_id` もない描画と同じ回数のまま |
| `jq-fork-same-name` | 他人の fork の同名ブランチの OPEN より、自分の MERGED (HEAD 一致) を選ぶ |
| `jq-review-null-approved` | `reviewDecision` が `null` でも、`latestReviews` の `APPROVED` で approved になる |
| `jq-nullable-fields` | `statusCheckRollup` が `null` なら CI は空、`totalCommentsCount` が `null` なら件数は 0 |
| `jq-merged-head-mismatch` | MERGED の `headRefOid` がローカルの HEAD と違えば PR なし |
| `jq-base-owner` | push 先がないときは base リポジトリのオーナーで候補を絞る |
| `jq-other-owner` | push 先のオーナーと違うオーナーの PR は拾わない |
| `jq-open-changes-requested` | `reviewDecision` が `null` なら `latestReviews` の `CHANGES_REQUESTED` を優先する。`totalCommentsCount` (2 桁) をそのまま件数にする。`FAILURE` は fail |
| `jq-open-review-required` | `REVIEW_REQUIRED` は `latestReviews` に `APPROVED` があっても pending |
| `jq-closed-error` | CLOSED (HEAD 一致) は closed でレビュー状態は空。`ERROR` は fail |

- `jq-*` は、`pr-responses/` の GraphQL 応答を fake gh に返させ、本体の `--jq` の式を本物の `jq` で評価した結果のキャッシュを確かめます。`gh` 組み込みの `--jq` は gojq なので、jq にしかない関数を使っても検出できません。
- `no-gh` は、本体と fake git が使うコマンドだけを symlink したディレクトリを `PATH` にします。本物の `gh` は `jq` と同じディレクトリ (`/usr/bin` や `/opt/homebrew/bin`) にあることが多く、ディレクトリごと外せないためです。
- `early-*` は、`session_id` と `pr` を含む入力を描画させ、`gh` の呼び出し回数と `.seen` の中身を確かめます。各ケースは、間隔による取得が起動しないキャッシュとマーカーを置いてから始めます。`.seen` の時刻は中身に書くので、最低間隔は `.seen` を書き直して再現します。
- `early-no-extra-commands` は、主な外部コマンドを、呼ばれた名前を記録してから本物を `exec` するラッパーで隠して数えます。外部コマンドを伴わないサブシェル (組み込みだけの `$(...)`) の fork は検出できません。

### rate-history-behavior.sh

最新の保存値はチャート右端の現在値で隠れるため、履歴に追記したかどうかは描画出力に現れません。本スクリプトは描画の後に履歴ファイル (`<履歴ディレクトリ>/rate`) の中身を直接見ます。仕込む古い値 (`50`) と描画で渡す現在の残量 (`90`) を変えておき、末尾の行が現在の残量になったかで追記の有無を判定します。mtime は `lib/age-file.sh` でずらします。ケースは次のとおりで、両版それぞれで実行します。

| ケース名 | 確かめること |
| --- | --- |
| `init-fill` | 空の履歴に 1 回描画すると、現在値が 20 行 (`RATE_CHART_LEN_MAX`) 書かれる |
| `throttle` | 間隔内 (10 秒前に更新) の描画では追記しない |
| `append-after-interval` | mtime が間隔 (既定 300 秒) より古ければ 1 行追記する |
| `storage-cap` | 25 行のファイルに追記すると末尾 20 行に切り詰める |
| `poll-max-follows-chart-len` | conf の `RATE_CHART_LEN=20` と `POLL_INTERVAL_SEC=3000` で、1000 秒前の履歴に追記する (上限が 900 に丸められている) |
| `poll-max-default:*` | conf の `POLL_INTERVAL_SEC=99999` で、1400 秒前には追記せず、1600 秒前には追記する (既定のチャート長 12 での上限 1500) |
| `poll-clamp-zero` | conf の `POLL_INTERVAL_SEC=0` で、30 秒前の履歴に追記しない (下限 60) |
| `poll-invalid-default:*` | conf の `POLL_INTERVAL_SEC=abc` で、250 秒前には追記せず、350 秒前には追記する (既定 300) |

conf は一時ファイルに書いて渡します。`RATE_CHART_LEN` と `POLL_INTERVAL_SEC` には env の上書き口が無いため、開発者のシェルの環境変数で結果は変わりません。

### e2e-preview.sh

- 全 fixture について、入力 JSON と実出力を並べて表示します。
- rate チャートが右肩下がりの遷移として見えるよう、fixture の現在値から 20 件 (本体が保存する件数) のダミー履歴を作って仕込みます。刻みは 5 で、古い側は 100 で頭打ちになります。
- 履歴は `mktemp -d` で作った一時ディレクトリを `CLAUDE_STATUSLINE_HISTORY_DIR` に渡して隔離し、本番の `/tmp/claude-statusline-<uid>/` には触れません。一時ディレクトリはケースの表示後に削除します。
- `--macos` / `--linux` で片方の版だけを表示できます。オプションなしでは macOS 版を表示し、bash 4.1+ が見つかれば Linux 版も表示します。
- このスクリプトは独自の bash 探索を持ち、`flock` の有無は確認しません。

### script-parity.sh

`regression.sh` は実行できる側の版しか検証しないため、CI (ubuntu) では macOS 版が、手元の macOS では Linux 版が実行されず、片方だけを直したずれを同じ実行の中で検出できません。`script-parity.sh` は OS に依存しない静的な比較だけを行い、どの OS でも実行できます。チェックは次のとおりです。

| チェック名 | 確かめること |
| --- | --- |
| `block:config-load` | 設定ファイルの読み込みブロックが両版で一字一句一致する |
| `block:settings` | カスタマイズ設定ブロックが両版で一致する |
| `block:interval-clamp` | 間引き定数の clamp ブロックが両版で一致する |
| `block:color-scheme` | カラースキーム定義ブロックが両版で一致する |
| `block:pr-constants` | PR の状態表示の内部定数が両版で一致する |
| `block:pr-common` | PR の状態表示の共通部分 (クエリ、`--jq`、キャッシュの読み書き、子プロセスの起動と本体、描画) が両版で一致する |
| `block:spark` | スパークと残量の計算 (`spark_of` / `round_int` / `set_remaining`) が両版で一致する |
| `block:history-chart` | 履歴ファイルの読み出し (`history_chart`) が両版で一致する。ロックの取り方が違う `history_push` は対象外 |
| `block:paint` | 色付け、ハイライト、トリム、git の集計 (`paint` / `highlight` / `*_color` / `truncate_label` / `truncate_branch` / `git_diff_stat` / `git_ahead_behind`) が両版で一致する |
| `block:format-layout` | rate / ctx の整形とレイアウトの組み立て (`format_limit` / `format_ctx` / `layout_token` / `split_tokens` / `build_layout` / `join_by`) が両版で一致する |
| `block:main-render` | main の描画部分 (`hl_set` の組み立て、rate チャート、branch / ab の取得、model と effort の組み立て、directory、`build_layout` の呼び出し) が両版で一致する。手前の jq の読み取りはコメントが両版で違うので対象外 |
| `block:stdin-read` | jq の読み取りのうち、コメントの後の `read` と jq の式 (PR の取得の前倒しに使う署名と `session_id` を含む) が両版で一致する |
| `static:locale` | 先頭 20 行に `export LC_ALL=C.UTF-8` がある |
| `static:no-prompt:<関数>:*` | `maybe_git_fetch` と `pr_spawn_refresh` のそれぞれに、`GIT_TERMINAL_PROMPT=0` / `GIT_ASKPASS=/bin/true` / `SSH_ASKPASS=/bin/true` / `SSH_ASKPASS_REQUIRE=force` が残っている |
| `static:fetch-fd-redirect` | `maybe_git_fetch` に `>/dev/null 2>&1 </dev/null` が残っている |
| `static:pr-gh-env:*` | `pr_spawn_refresh` に `GH_PROMPT_DISABLED=1` / `GH_NO_UPDATE_NOTIFIER=1` / `GH_NO_EXTENSION_UPDATE_NOTIFIER=1` と、`unset GH_REPO GH_FORCE_TTY CLICOLOR_FORCE` が残っている |
| `static:pr-fd-redirect` | `pr_spawn_refresh` に `>/dev/null 2>&1 </dev/null` が残っている |
| `static:pr-early:*` | `maybe_pr_refresh` が、取得の前倒しの判定 (`pr_refresh_wanted`) と、ロックの中の確かめ直しと書き込み (`pr_refresh_claim`) を呼んでいる |
| `static:no-echo` | コメント以外の行で `echo` を使っていない |

- `block:*` は、開始マーカーのコメント行 (行頭一致) から終了マーカー行の手前までを取り出して比較します。マーカーのコメントを書き換えるとブロックを取り出せず、失敗になります。`block:stdin-read` だけは、直前のコメントが両版で違うため、最初の `read` の行を開始マーカーにしています。
- `static:*` は、両版それぞれに固定文字列が含まれることを確かめます。関数名を挙げたチェックは、その関数の範囲 (`<関数>() {` から次の行頭の `}` まで) だけを探します。

### translation-parity.sh

日本語のドキュメントを正本とし、英語版 (`*.en.md`) を手で同期する運用のため、日本語版だけを更新した取り残しを検出します。翻訳の質は見ず、OS に依存しない構造の比較だけを行います。対象は `README.md`、`docs/SPEC.md`、`docs/DESIGN.md`、`docs/DEVELOPMENT.md`、`tests/README.md` とそれぞれの英語版です。

| チェック名 | 確かめること |
| --- | --- |
| `lang-link:<名前>` | 冒頭の 1 行が互いの言語版へのリンクになっている |
| `headings:<名前>` | 見出しの数が一致する |
| `tables:<名前>` | 表の行数が一致する |
| `spans:<名前>` | 日本語版のコードスパン (設定変数名やコマンド) が英語版にすべて含まれる。英語版にだけあるスパンは翻訳で生じるため比べない |
| `lists:<名前>` | 箇条書きの項目の数と字下げ (入れ子の深さ) が一致する。折り返しで字下げが落ちると入れ子が崩れる |

- コードブロックの中は数えません。日本語の文字やプレースホルダ (`<名前>` など) を含むコードスパンは翻訳で変わるため、比べません。

## ディレクトリ構成

ケース名は `NN-説明` の形式 (例 `30-branch-on`) で、fixture と assertion は同じケース名で対応します。それ以外のディレクトリは、ケース名と同名のファイルを置いたケースだけに効く｢マーカー｣です。

| パス | 内容 |
| --- | --- |
| `fixtures/<case>.json` | statusline に渡す入力 JSON |
| `assertions/<case>.txt` | そのケースの期待値 |
| `seeds/<case>.txt` | rate 履歴として仕込む値 (1 行 1 値、古い順) |
| `disable-history/<case>` | 空ファイル。履歴ディレクトリを無効化する |
| `show-model-off/<case>` | 空ファイル。`CLAUDE_STATUSLINE_SHOW_MODEL_NAME=0` を渡す |
| `show-cwd-off/<case>` | 空ファイル。`CLAUDE_STATUSLINE_SHOW_CWD=0` を渡す |
| `git-fetch-on/<case>` | 空ファイル。`CLAUDE_STATUSLINE_GIT_FETCH=1` を渡す |
| `config-file/<case>` | 設定ファイルとして読ませる中身 |
| `layout/<case>` | 1 行目 = `LAYOUT_LINE1`、2 行目 = `LAYOUT_LINE2` |
| `highlight/<case>` | 1 行目 = `CLAUDE_STATUSLINE_HIGHLIGHT` |
| `pr-cache/<case>` | PR の状態表示のキャッシュとして仕込む 1 行 (`lib/pr-cache.sh`) |
| `hyperlink-off/<case>` | 空ファイル。`FORCE_HYPERLINK=0` を渡す |
| `pr-status-on/<case>` | 空ファイル。`CLAUDE_STATUSLINE_PR_STATUS=1` を渡す |
| `pr-responses/*.json` | `pr-status-behavior.sh` で fake gh に返させる GraphQL の応答 |
| `lib/` | ハーネス間で共有するヘルパと fake git / fake gh |

マーカーごとの補足です。

- `seeds/`: コピー直後の履歴ファイルは mtime が新しいため、本体はサンプリング間隔内と判断して追記しません。仕込んだ値がそのままチャートの左側に使われ、右端だけが現在値になることを確かめられます。
- `disable-history/`: 履歴ディレクトリへの symlink を `CLAUDE_STATUSLINE_HISTORY_DIR` に渡し、本体の symlink 判定で履歴機能を無効にします。履歴が無効でもチャート右端に現在値が出ることの検証に使います。
- `git-fetch-on/`: fetch は fake git が受けるため、実際のネットワークには出ません。fetch 有効時も描画出力が変わらないことを確かめます。
- `config-file/`: 通常ファイルのほか、ディレクトリ (読めない conf の再現。`83-config-unreadable`) や、配布テンプレート `statusline.conf` への symlink (`86-config-template` / `95-config-template-layout`) も置けます。
  - `86-config-template` / `95-config-template-layout` は配布テンプレート `statusline.conf` を読ませ、出力が既定値のときと一致することで、テンプレートの値が既定値とずれていないことを確かめます。`86` は branch / session の無い fixture のため、1 行目の並びの一致は `95` で確かめます。
    - テンプレートは `HIGHLIGHT` だけをおすすめの設定 `branch|pr_number` にしています。どちらも PR を表示しない fixture のため、`pr_number` は出力に現れません。
  - レイアウトの値は `|` を含むため、テンプレートではクォートで囲んでいます。
- `layout/`: 空行は｢指定なし｣を意味します。
- `highlight/`: マーカーが無いケースでは空で渡します (conf → 既定値。既定は `branch`)。conf の `HIGHLIGHT` を確かめるケース (`166-highlight-config` など) は `config-file/` を使い、env が conf に勝つことは両方のマーカーを置いて確かめます。前後の空白やタブも含めて 1 行目をそのまま渡します (`165-highlight-tokens`)。
- `pr-cache/`: 1 行目をキャッシュの 1 行として書きます。`printf %b` で展開するのでタブは `\t`、ESC は `\033` と書けます。`fetched_at` は現在時刻に依存するため、`@NOW@` (現在時刻) と `@STALE@` (現在時刻 - 4000 秒) を仕込む直前に置き換えます。1 行目が空ならキャッシュを置きません。どの場合も新しいマーカーを置くため、描画は取得を起動せず、仕込んだキャッシュがそのまま読まれます
- `hyperlink-off/`: マーカーが無いケースでは `FORCE_HYPERLINK` を空で渡し、開発者のシェルの値が混ざらないようにしています
- `pr-status-on/`: マーカーが無いケースでは `CLAUDE_STATUSLINE_PR_STATUS` を空で渡します。PR は fake gh が受け、`pr-cache/` で仕込んだキャッシュを branch 列に出すケースで使います

`lib/` の中身は次のとおりです。

| ファイル | 役割 |
| --- | --- |
| `lib/escape-ansi.sh` | ESC を `\e` に、BEL を `\a` に置き換える (`perl` を使用) |
| `lib/config-file.sh` | `config_for_case` で conf のパスを解決する。マーカーが無ければ存在しないパス (`NO_CONFIG`) を返す |
| `lib/layout.sh` | `layout_for_case` でレイアウト文字列を解決する |
| `lib/highlight.sh` | `highlight_for_case` でハイライトの指定を解決する |
| `lib/find-debian-bash.sh` | Linux 版を実行できる bash を探す。CI 用の必須化チェックも持つ |
| `lib/is-macos-host.sh` | macOS ホストかどうかを判定する |
| `lib/git-shim/git` | テスト用の fake git |
| `lib/gh-shim/gh` | テスト用の fake gh |
| `lib/pr-cache.sh` | `seed_pr_cache_for_case` で PR の状態表示のキャッシュとマーカーを仕込む |
| `lib/age-file.sh` | `age_file` でファイルの mtime を N 秒前にする (`touch -t` と BSD / GNU の `date` の両対応) |

## assertion ファイルの書き方

1 行に 1 つ、`種別: 期待値` の形式で書きます。空行と `#` で始まる行は無視されます。

- 区切りは `:` (コロンと半角スペース) です。区切りが無い行は書き間違いとして失敗します。
- 期待値の中の ESC は、可読化後の文字列 `\e` として書きます。`contains` などの固定文字列ではそのまま `\e`、正規表現 (`matches*`) では `\\e` と書きます。
- 1 ファイル内の assertion がすべて通ったときにケースが成功します。

### 種別一覧

| 種別 | 対象 | 判定 |
| --- | --- | --- |
| `equals` | 出力全体 | 完全一致 |
| `contains` | 出力全体 | 固定文字列を含む |
| `not_contains` | 出力全体 | 固定文字列を含まない |
| `matches` | 出力全体 | ERE に一致 |
| `matches_line1` | 1 行目 | ERE に一致 |
| `matches_line2` | 2 行目 | ERE に一致。2 行目が無ければ失敗 |
| `not_contains_line1` | 1 行目 | 固定文字列を含まない |
| `not_contains_line2` | 2 行目 | 固定文字列を含まない。2 行目が無ければ成功 |
| `no_line2` | 出力全体 | 出力が 1 行だけ (期待値は慣例で `true`) |
| `fetch_marker` | 履歴ディレクトリ | 間引きマーカーの有無 (`present` / `absent`) |
| `exit_code` | 終了コード | 一致 |

上記以外の種別名は失敗として扱われます。

### 行指定の種別を使う理由

出力は 2 行構成のため、行ごとに検証する種別を用意しています。

- `matches` は出力全体を 1 つの文字列として評価します。`.` が改行にも一致し、`^…$` も行単位には効かないため、行の形をそのまま固定したいときは `matches_line1` / `matches_line2` を使います。
- `matches_line2` を書かないことは｢2 行目が無い｣ことの検証になりません。1 行目 (directory / branch / commit / session_name) が省略されて 1 行だけになるケースには `no_line2` を付け、残った唯一の行 (モデル行) を `matches_line1` で検証します。
- `no_line2` は、末尾の改行を保持した出力 (`output_raw`) で判定します。コマンド置換は末尾の改行をすべて取り除くため、そのままでは｢1 行目の後に空行だけを出す｣退行を検出できません。ハーネスはセンチネル文字を付けて出力を取得し、末尾の改行を残しています。
- `not_contains_line1` / `not_contains_line2` は、特定の行に出ないことを確かめます。たとえば `not_contains_line2` を使うと、1 行目の directory 列に含まれうる文字 (ハイフンや色シーケンス) を誤検知せずに、モデル行に出ないことを検証できます。

### 正規表現の注意

glibc の正規表現は UTF-8 マルチバイト文字の範囲指定 (例 `[▁-█]`) を解釈しないため、スパーク文字は `[▁▂▃▄▅▆▇█]` のように列挙します。

### 例

```text
# branch=main の git リポジトリ。session_name は空なので 1 行目の session 列は省略
matches_line2: ^✻ Sonnet 4\.6 [▁▂▃▄▅▆▇█] \| [▁▂▃▄▅▆▇█]{12} 22:13 \| · --$
matches_line1: ^sl-repo#branch=main;ab=0… \| main \| a1b2c3d$
contains: | main
```

## fake git (`lib/git-shim/git`)

実際の git リポジトリを作らずに branch･コミットハッシュ･変更行数･ahead/behind の経路を検証するため、ハーネスは `PATH` の先頭に `lib/git-shim/` を差し込み、本物の git を隠します。
fake git は statusline が使うサブコマンド (`branch --show-current` / `rev-parse --short HEAD` / `diff HEAD --numstat` / `status -z` / `diff --no-index --numstat` / `rev-list --left-right --count` / `fetch`) だけを実装しています。
PR の状態表示の子プロセスが使う `rev-parse HEAD` / `rev-parse --abbrev-ref '@{push}'` / `remote get-url` も実装しています。

リポジトリの状態は、fixture の `workspace.current_dir` の `#` 以降に書きます。複数指定は `;` で区切ります。

```text
/tmp/sl-repo#branch=main;diff=12,3;untracked=new.txt:5;ab=2,3
```

| 規約 | 意味 |
| --- | --- |
| `branch=<name>` | `branch --show-current` が `<name>` を返す |
| `detached` | detached HEAD。`rev-parse` が短縮 sha を返し、`rev-list` は常に失敗する |
| `unborn` | まだコミットが無い (`branch=<name>` と併用する)。`rev-parse --short HEAD` / `rev-parse HEAD` / `diff HEAD --numstat` / `rev-list` は失敗する (`ab` があっても失敗する)。`status -z` は動く |
| `short=<hex>` | `rev-parse --short HEAD` が返す値 (既定 `a1b2c3d`)。`core.abbrev` を大きくしたときの長いハッシュを再現する |
| `diff=<add>,<del>` | 追跡ファイルの変更行数 |
| `diff=bin` | バイナリの変更 1 件 |
| `diff=<add>,<del>+bin` | 数値の変更とバイナリの変更の両方 |
| `untracked=<file>:<n>,...` | 未追跡ファイルとその行数 (`<n>` に `bin` でバイナリ) |
| `ab=<ahead>,<behind>` | upstream との差。`ab=0,0` は同期済み |
| `head=<sha>` | `rev-parse HEAD` が返すローカルの HEAD (既定 `0123456789abcdef0123456789abcdef01234567`) |
| `push=<remote>~<branch>` | `rev-parse --abbrev-ref '@{push}'` が返す値。`~` は `/` として返す (例 `push=origin~feature~fix`) |
| `owner=<login>` | `remote get-url` が返す URL のオーナー |
| `urlform=https\|scp\|ssh` | その URL の形式 (既定 `https`) |

- `ab` を書かなければ upstream 未設定として扱います (`rev-list` が失敗する)。
- `push` を書かなければ、まだ push していないものとして扱います (`@{push}` が失敗する)。`pr-status-behavior.sh` は cwd を実在のディレクトリにするため、パスに `/` を書けず、`~` で代用しています。`owner` も同じ理由で、URL そのものではなく規約から組み立てます。
- 環境変数 `STATUSLINE_TEST_BRANCH=<name>` があると `branch` 規約を上書きします。cwd を変えずにブランチだけを切り替える検証 (`branch-switch`) に使います。
- `#` 以降が無いパスは git 外として扱います。
- `fetch` は何もせずに終了します。`git-fetch-behavior.sh` は次の環境変数で fetch の挙動を観測します。
  - `STATUSLINE_TEST_FETCH_SLEEP=<秒>`: fetch を指定秒だけ遅らせる
  - `STATUSLINE_TEST_FETCH_SENTINEL=<path>`: fetch 1 回ごとにファイルへ 1 行追記する

directory 列は `current_dir` の basename から作られるため、規約文字列もその一部として表示されます (上の例の `sl-repo#branch=main;ab=0…`)。

## fake gh (`lib/gh-shim/gh`)

PR の状態表示の子プロセスが呼ぶ `gh api graphql ... --jq <式>` だけを受ける fake です。`regression.sh` / `pr-status-behavior.sh` / `e2e-preview.sh` は `PATH` に `lib/gh-shim/` を差し込み、本物の gh (ネットワーク) に出ないようにしています。

- 既定では何もせずに失敗します (終了コード 1)。`regression.sh` と `e2e-preview.sh` はキャッシュと新しいマーカーを仕込むため、通常は取得自体が起動されません
- `head` が `-F` で渡されたときは失敗します。本物の `gh` の `-F` は値を型変換し (`123` や `true` が数値や真偽値になる)、`@` で始まる値をファイルとして読むためです
- `pr-status-behavior.sh` は次の環境変数で挙動を制御します
  - `STATUSLINE_TEST_GH_SENTINEL=<path>`: 呼び出し 1 回ごとに、`head` 変数と、子プロセスが設定･除去する環境変数 (gh 用と git 用) の値を 1 行追記する
  - `STATUSLINE_TEST_GH_SLEEP=<秒>`: 応答を指定秒だけ遅らせる
  - `STATUSLINE_TEST_GH_EXIT=<code>`: 応答の代わりに指定の終了コードで終わる
  - `STATUSLINE_TEST_GH_RESPONSE=<path>`: GraphQL の応答 JSON。`--jq` の式を本物の `jq -r` で評価して出す

## 実行環境の隔離

ケースの結果が開発者の環境に左右されないよう、ハーネスは全ケース共通で次の前置きを付けて statusline を起動します。

- 履歴ディレクトリ: `regression.sh` / `git-fetch-behavior.sh` / `pr-status-behavior.sh` / `e2e-preview.sh` のいずれも、ケースごとに `mktemp -d` で作った一時ディレクトリを `CLAUDE_STATUSLINE_HISTORY_DIR` に渡し、終了時に削除します。本番の `/tmp/claude-statusline-<uid>/` には触れません。実 uid で作られたディレクトリなので本体の所有者チェックを通り、初回起動時の履歴書き込みも実際に動きます。
- 設定ファイル: `CLAUDE_STATUSLINE_CONFIG` は、`config-file/` にマーカーがあるケースを除き、存在しないパスに固定します。開発者の `~/.claude/statusline.conf` を読むことはありません。すべてのハーネスが `lib/config-file.sh` を通してこの規則に従います。
- `CLAUDE_STATUSLINE_*` の環境変数: マーカーが無いときは空文字で渡します。本体は空を未設定と同じに扱うため、conf → 既定値の順にフォールバックします。既定値を直接渡すと conf の値が常に環境変数に負け、conf の検証ができなくなるためです。`CLAUDE_STATUSLINE_COLOR_SCHEME` も空で渡し、開発者のシェルの値が混ざらないようにしています。
  - `CLAUDE_STATUSLINE_HIGHLIGHT` は `regression.sh` / `pr-status-behavior.sh` / `e2e-preview.sh` のすべてで必ず渡します。渡さないと、ハイライトを export している開発者の手元だけで、branch などを含むケースが落ちます。
- 短縮名の変数: `regression.sh` は `SHOW_MODEL_NAME` や `LAYOUT_LINE1` などの短縮名 11 個を、全ケースで既定値と異なる値にして渡します (`HIGHLIGHT` は全トークンを指定した値)。本体は conf を読む前にこれらを `unset` するため、出力には影響しません。この `unset` が消えると全ケースが失敗するので、その回帰ガードを兼ねています。
- git / gh: 前述の fake git と fake gh を `PATH` の先頭に置きます。
- `FORCE_HYPERLINK`: `regression.sh` と `e2e-preview.sh` は、`hyperlink-off/` にマーカーがあるケースを除き空で渡します。

## 実行環境と skip

| 版 | 実行条件 | 条件を満たさないとき |
| --- | --- | --- |
| macOS 版 | macOS ホスト (`uname -s` が `Darwin`) | skip (BSD 系コマンド前提のため) |
| Linux 版 | bash 4.1 以上と `flock` | skip |

- 両版に共通して `jq` が必要です。`regression.sh` は `perl` も使います。
- Linux 版の bash は `bash` (`PATH` 上)、`/opt/homebrew/bin/bash`、`/usr/local/bin/bash` の順に探します。macOS の `/bin/bash` は 3.2 のため対象外です。
- macOS に bash 4.1+ と `flock` を入れると Linux 版のケースも実行対象になりますが、Linux 版は GNU coreutils の `stat -c` / `date -d` を使うため macOS 上では失敗します。Linux 版は CI (ubuntu) で検証します。
- skip が発生したことは結果の末尾に表示されます (`regression.sh` は skip した件数も表示します)。
- CI は ubuntu で Linux 版だけを実行し、`STATUSLINE_TEST_REQUIRE_DEBIAN=1` を設定しています。この変数が `1` のとき、Linux 版を実行できない環境では skip せずにエラー終了します。全件 skip のまま成功扱いになるのを防ぐためです。macOS 版は CI で実行されないため、macOS 版に関わる変更は手元で `npm test` を実行して確認します。

## ケースを追加するとき

1. `fixtures/<NN-name>.json` に入力を、`assertions/<NN-name>.txt` に期待値を置きます。既存ケースは通し番号で並んでいます。
2. 環境変数や設定を変えたいときは、該当するマーカーディレクトリに同名のファイルを置きます。
3. `npm test` で両版が通ることを確かめ、`npm run preview` で実際の色を目視します。

出力を変えないリファクタリングでは既存の assertion を書き換えません。出力が変わる変更では、[docs/SPEC.md](../docs/SPEC.md) と assertion を同時に更新します。
