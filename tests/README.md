# テスト

macOS 版 (`statusline-macos.sh`) と Linux 版 (`statusline-linux.sh`) が同じ入力に対して同じ出力を返すことを確かめるテスト群です。出力の仕様は [docs/SPEC.md](../docs/SPEC.md)、各防御コードとそれを守るテストの対応は [docs/DESIGN.md](../docs/DESIGN.md)、開発環境の準備は [CONTRIBUTING.md](../CONTRIBUTING.md) を参照してください。

## ハーネスの役割

| スクリプト | 実行方法 | 役割 |
| --- | --- | --- |
| `regression.sh` | `npm run test:regression` | fixture を両スクリプトに流し、出力を assertion と突き合わせる |
| `git-fetch-behavior.sh` | `npm run test:fetch` | `GIT_FETCH=1` のバックグラウンド fetch の挙動を検証する |
| `e2e-preview.sh` | `npm run preview` | 実際の ANSI 色付き出力を端末に流し、目視で確認する |
| `script-parity.sh` | `npm run test:parity` | 両スクリプトの共通ブロックの一致と、必要な記述が残っていることを静的に確かめる |

`npm test` は `test:regression`、`test:fetch`、`test:parity` を順に実行します。`e2e-preview.sh` は合否を判定しないため `npm test` には含まれません。`npm test` は `test:parity` として `script-parity.sh` も実行します。

### regression.sh

- `fixtures/*.json` を 1 件ずつ両スクリプトの標準入力に渡し、同名の `assertions/*.txt` で出力を検証します。assertion ファイルが無い fixture は失敗として数えます。
- 出力は `lib/escape-ansi.sh` で ESC (0x1b) を文字列 `\e` に置き換えてから比較します。
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

### e2e-preview.sh

- 全 fixture について、入力 JSON と実出力を並べて表示します。
- rate チャートが右肩下がりの遷移として見えるよう、fixture の現在値から 6 件のダミー履歴を作って仕込みます。
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
| `static:locale` | 先頭 20 行に `export LC_ALL=C.UTF-8` がある |
| `static:fetch-no-prompt:GIT_TERMINAL_PROMPT` | `GIT_TERMINAL_PROMPT=0` が残っている |
| `static:fetch-no-prompt:GIT_ASKPASS` | `GIT_ASKPASS=/bin/true` が残っている |
| `static:fetch-no-prompt:SSH_ASKPASS` | `SSH_ASKPASS=/bin/true` が残っている |
| `static:fetch-no-prompt:SSH_ASKPASS_REQUIRE` | `SSH_ASKPASS_REQUIRE=force` が残っている |
| `static:fetch-fd-redirect` | fetch 子プロセスの `>/dev/null 2>&1 </dev/null` が残っている |
| `static:no-echo` | コメント以外の行で `echo` を使っていない |

- `block:*` は、開始マーカーのコメント行 (行頭一致) から終了マーカー行の手前までを取り出して比較します。マーカーのコメントを書き換えるとブロックを取り出せず、失敗になります。
- `static:*` は、両版それぞれに固定文字列が含まれることを確かめます。

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
| `lib/` | ハーネス間で共有するヘルパと fake git |

マーカーごとの補足です。

- `seeds/`: コピー直後の履歴ファイルは mtime が新しいため、本体はサンプリング間隔内と判断して追記しません。仕込んだ値がそのままチャートの左側に使われ、右端だけが現在値になることを確かめられます。
- `disable-history/`: 履歴ディレクトリへの symlink を `CLAUDE_STATUSLINE_HISTORY_DIR` に渡し、本体の symlink 判定で履歴機能を無効にします。履歴が無効でもチャート右端に現在値が出ることの検証に使います。
- `git-fetch-on/`: fetch は fake git が受けるため、実際のネットワークには出ません。fetch 有効時も描画出力が変わらないことを確かめます。
- `config-file/`: 通常ファイルのほか、ディレクトリ (読めない conf の再現。`83-config-unreadable`) や、配布テンプレート `statusline.conf` への symlink (`86-config-template` / `95-config-template-layout`) も置けます。
  - `86-config-template` / `95-config-template-layout` は配布テンプレート `statusline.conf` を読ませ、出力が既定値のときと一致することで、テンプレートの値が既定値とずれていないことを確かめます。`86` は branch / session の無い fixture のため、1 行目の並びの一致は `95` で確かめます。
  - レイアウトの値は `|` を含むため、テンプレートではクォートで囲んでいます。
- `layout/`: 空行は｢指定なし｣を意味します。

`lib/` の中身は次のとおりです。

| ファイル | 役割 |
| --- | --- |
| `lib/escape-ansi.sh` | ESC を `\e` に置き換える (`perl` を使用) |
| `lib/config-file.sh` | `config_for_case` で conf のパスを解決する。マーカーが無ければ存在しないパス (`NO_CONFIG`) を返す |
| `lib/layout.sh` | `layout_for_case` でレイアウト文字列を解決する |
| `lib/find-debian-bash.sh` | Linux 版を実行できる bash を探す。CI 用の必須化チェックも持つ |
| `lib/is-macos-host.sh` | macOS ホストかどうかを判定する |
| `lib/git-shim/git` | テスト用の fake git |

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
- `matches_line2` を書かないことは｢2 行目が無い｣ことの検証になりません。1 行目 (directory / branch / session_name) が省略されて 1 行だけになるケースには `no_line2` を付け、残った唯一の行 (モデル行) を `matches_line1` で検証します。
- `no_line2` は、末尾の改行を保持した出力 (`output_raw`) で判定します。コマンド置換は末尾の改行をすべて取り除くため、そのままでは｢1 行目の後に空行だけを出す｣退行を検出できません。ハーネスはセンチネル文字を付けて出力を取得し、末尾の改行を残しています。
- `not_contains_line1` / `not_contains_line2` は、特定の行に出ないことを確かめます。たとえば `not_contains_line2` を使うと、1 行目の directory 列に含まれうる文字 (ハイフンや色シーケンス) を誤検知せずに、モデル行に出ないことを検証できます。

### 正規表現の注意

glibc の正規表現は UTF-8 マルチバイト文字の範囲指定 (例 `[▁-█]`) を解釈しないため、スパーク文字は `[▁▂▃▄▅▆▇█]` のように列挙します。

### 例

```text
# branch=main の git リポジトリ。session_name は空なので 1 行目の session 列は省略
matches_line2: ^✻ Sonnet 4\.6 [▁▂▃▄▅▆▇█] \| [▁▂▃▄▅▆▇█]{6} 22:13$
matches_line1: ^\\e\[38;2;153;153;153msl-repo#branch=main;ab=0…\\e\[0m \| main$
contains: | main
```

## fake git (`lib/git-shim/git`)

実際の git リポジトリを作らずに branch･変更行数･ahead/behind の経路を検証するため、ハーネスは `PATH` の先頭に `lib/git-shim/` を差し込み、本物の git を隠します。
fake git は statusline が使うサブコマンド (`branch --show-current` / `rev-parse --short HEAD` / `diff HEAD --numstat` / `status -z` / `diff --no-index --numstat` / `rev-list --left-right --count` / `fetch`) だけを実装しています。

リポジトリの状態は、fixture の `workspace.current_dir` の `#` 以降に書きます。複数指定は `;` で区切ります。

```text
/tmp/sl-repo#branch=main;diff=12,3;untracked=new.txt:5;ab=2,3
```

| 規約 | 意味 |
| --- | --- |
| `branch=<name>` | `branch --show-current` が `<name>` を返す |
| `detached` | detached HEAD。`rev-parse` が短縮 sha を返し、`rev-list` は常に失敗する |
| `diff=<add>,<del>` | 追跡ファイルの変更行数 |
| `diff=bin` | バイナリの変更 1 件 |
| `diff=<add>,<del>+bin` | 数値の変更とバイナリの変更の両方 |
| `untracked=<file>:<n>,...` | 未追跡ファイルとその行数 (`<n>` に `bin` でバイナリ) |
| `ab=<ahead>,<behind>` | upstream との差。`ab=0,0` は同期済み |

- `ab` を書かなければ upstream 未設定として扱います (`rev-list` が失敗する)。
- `#` 以降が無いパスは git 外として扱います。
- `fetch` は何もせずに終了します。`git-fetch-behavior.sh` は次の環境変数で fetch の挙動を観測します。
  - `STATUSLINE_TEST_FETCH_SLEEP=<秒>`: fetch を指定秒だけ遅らせる
  - `STATUSLINE_TEST_FETCH_SENTINEL=<path>`: fetch 1 回ごとにファイルへ 1 行追記する

directory 列は `current_dir` の basename から作られるため、規約文字列もその一部として表示されます (上の例の `sl-repo#branch=main;ab=0…`)。

## 実行環境の隔離

ケースの結果が開発者の環境に左右されないよう、ハーネスは全ケース共通で次の前置きを付けて statusline を起動します。

- 履歴ディレクトリ: `regression.sh` / `git-fetch-behavior.sh` / `e2e-preview.sh` のいずれも、ケースごとに `mktemp -d` で作った一時ディレクトリを `CLAUDE_STATUSLINE_HISTORY_DIR` に渡し、終了時に削除します。本番の `/tmp/claude-statusline-<uid>/` には触れません。実 uid で作られたディレクトリなので本体の所有者チェックを通り、初回起動時の履歴書き込みも実際に動きます。
- 設定ファイル: `CLAUDE_STATUSLINE_CONFIG` は、`config-file/` にマーカーがあるケースを除き、存在しないパスに固定します。開発者の `~/.claude/statusline.conf` を読むことはありません。3 つのハーネスすべてが `lib/config-file.sh` を通してこの規則に従います。
- `CLAUDE_STATUSLINE_*` の環境変数: マーカーが無いときは空文字で渡します。本体は空を未設定と同じに扱うため、conf → 既定値の順にフォールバックします。既定値を直接渡すと conf の値が常に環境変数に負け、conf の検証ができなくなるためです。`CLAUDE_STATUSLINE_COLOR_SCHEME` も空で渡し、開発者のシェルの値が混ざらないようにしています。
- 短縮名の変数: `regression.sh` は `SHOW_MODEL_NAME` や `LAYOUT_LINE1` などの短縮名 8 つを、全ケースで既定値と異なる値にして渡します。本体は conf を読む前にこれらを `unset` するため、出力には影響しません。この `unset` が消えると全ケースが失敗するので、その回帰ガードを兼ねています。
- git: 前述の fake git を `PATH` の先頭に置きます。

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
