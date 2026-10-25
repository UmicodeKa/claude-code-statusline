# claude-code-statusline

Claude Code のステータスラインをカスタマイズするスクリプト集。macOS 版 (`statusline-macos.sh`) と Linux 版 (`statusline-linux.sh`) があり、どちらも同じ表示内容を出力する。

> [!NOTE]
> 本リポジトリは Anthropic とは無関係の非公式プロジェクトです。

> [!NOTE]
> 本リポジトリは個人用で、Issue や Pull Request への対応は保証しません。フォークして自由に改変して使えます ([開発者向け](#開発者向け))。

## 概要

ステータスラインを次のような 2 行で表示する。

```text
my-project | main ↑2↓3 3+13-5 | my-session
✻ Opus 4.7∙high ▆ 72% | ▇▇▇▆▆▆▅▅▄▄▃▃ 35% - 18:30 | ▅ Thu
```

- 1 行目: ディレクトリ名 / git ブランチ (リモートとの差･変更行数つき。[`PR_STATUS=1`](#pr_status1-で-pr-の状態を表示する) で GitHub の PR の状態も表示) / セッション名
- 2 行目: モデル名と推論強度 (effort) / コンテキスト使用率 / 5 時間のレートリミット残量の推移とリセット時刻 / 週間 (7 日間) のレートリミット残量とリセットの曜日

コンテキスト使用率が高まる、またはレートリミット残量が減ると、色と数値で知らせる。

## 要件

| 項目 | macOS 版 | Linux 版 |
| --- | --- | --- |
| OS | macOS | GNU coreutils を使う Linux (動作確認は Debian/Ubuntu) |
| bash | `/bin/bash` (3.2 以上) | 4.1 以上 |
| 必須コマンド | `jq` | `jq`, `flock` (util-linux に含まれる) |
| 任意 | `git` | `git` |
| 任意 (`PR_STATUS=1`) | `gh` (最新版) | `gh` (最新版) |
| ロケール | `C.UTF-8` (現行 macOS は標準搭載) | `C.UTF-8` (Debian 11 以降は標準搭載) |

- `git` が無い場合や git 管理外のディレクトリでは、ブランチ列が省略されるだけで他は表示される
- `gh` は `PR_STATUS=1` のときだけ必要。最新版を前提にしている (動作確認は 2.103)
- ログインシェル (zsh など) は問わない
- 上記以外は `awk`, `date`, `stat`, `mkdir` など各 OS の標準コマンドだけを使う
- 色は 24bit カラー (truecolor) で出力する。truecolor に対応した端末を使う

## セットアップ

リポジトリを取得し、そのディレクトリで以下を行う。

```bash
git clone https://github.com/UmicodeKa/claude-code-statusline.git
cd claude-code-statusline
mkdir -p ~/.claude
```

### macOS

1. 依存パッケージをインストールする (未導入の場合)。

   ```bash
   brew install jq
   ```

2. スクリプトを配置する。

   ```bash
   cp statusline-macos.sh ~/.claude/statusline.sh
   chmod +x ~/.claude/statusline.sh
   ```

3. `~/.claude/settings.json` に以下を追加する。

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh"
     }
   }
   ```

4. Claude Code を再起動するとステータスラインに反映される。

### Linux

1. 依存パッケージをインストールする (未導入の場合)。

   ```bash
   sudo apt install jq util-linux
   ```

2. スクリプトを配置する。

   ```bash
   cp statusline-linux.sh ~/.claude/statusline.sh
   chmod +x ~/.claude/statusline.sh
   ```

3. `~/.claude/settings.json` に macOS の手順 3 と同じ `statusLine` 設定を追加し、Claude Code を再起動する。

## カスタマイズ

### 設定ファイル

`~/.claude/statusline.conf` に設定を書くと、スクリプト本体を編集せずに挙動を変えられる。ファイルが無ければ既定値で動く。全項目を既定値で埋めたテンプレート [`statusline.conf`](statusline.conf) をコピーし、変えたい行だけ書き換えるのが手早い。

```bash
cp statusline.conf ~/.claude/statusline.conf
```

```bash
COLOR_SCHEME=light
GIT_FETCH=1
LAYOUT_LINE1="session|directory|branch"
```

| 設定 | 既定値 | 内容 |
| --- | --- | --- |
| `SHOW_MODEL_NAME` | `1` | `0` でモデル名を隠し `✻` (モデル別の色) と effort だけにする |
| `COLOR_SCHEME` | `dark` | `dark` / `light` で配色を切替える |
| `SHOW_CWD` | `1` | `0` で 1 行目のディレクトリ名を隠す |
| `LAYOUT_LINE1` | `directory\|branch\|session` | 1 行目の要素と並び |
| `LAYOUT_LINE2` | `model_ctx\|rate\|weekly` | 2 行目の並び |
| `HIGHLIGHT` | `branch` | 無色の要素のうち目立たせるもの ([詳細](#ハイライト)) |
| `GIT_FETCH` | `0` | `1` でバックグラウンド `git fetch` を有効にする |
| `PR_STATUS` | `0` | `1` でブランチ列に PR の状態を表示する ([詳細](#pr_status1-で-pr-の状態を表示する)) |
| `RATE_CHART_LEN` | `12` | レートリミットのチャートの文字数 (2〜20) |
| `POLL_INTERVAL_SEC` | `300` | レートリミット履歴を記録する間隔 (秒) |
| `GIT_FETCH_INTERVAL_SEC` | `900` | バックグラウンド `git fetch` の最小間隔 (秒) |

- 値は `名前=値` のシェル変数代入で書く
- 変数代入以外のコマンドも描画のたびに実行される。標準出力に何か出すコマンドはその文字列が statusline に混ざり、`exit` を書くと描画が止まる。`COLOR_SCHEME = light` のように `=` の前後にスペースを入れると代入ではなくコマンド実行になる
- 読めないファイル (権限が無い、ディレクトリである等) は無視して既定値で描画する
- 各項目の詳しい挙動は [docs/SPEC.md](docs/SPEC.md) を参照

### 優先順位

同じ設定を複数の場所で指定したときは、環境変数 > 設定ファイル > 既定値 の順に優先される。

- 環境変数は `CLAUDE_STATUSLINE_<名前>` (例 `CLAUDE_STATUSLINE_COLOR_SCHEME=light`)。主にテストや一時的な切替向け
- `RATE_CHART_LEN`、`POLL_INTERVAL_SEC`、`GIT_FETCH_INTERVAL_SEC` には環境変数が無く、設定ファイルでだけ変えられる
- 設定ファイルには短縮名 (`COLOR_SCHEME`) を書く。環境変数名で書くと環境変数側の値を上書きしてしまう

### レイアウト

`LAYOUT_LINE1` / `LAYOUT_LINE2` には表示要素 (トークン) を `|` で区切って並べる。`|` を含むため、設定ファイルでは値をクォートで囲む (`HIGHLIGHT` も同じ)。

| 行 | トークン | 内容 |
| --- | --- | --- |
| 1 行目 | `directory` | ディレクトリ名 |
| 1 行目 | `branch` | ブランチ名 + リモートとの差 + 変更行数 (+ `PR_STATUS=1` なら PR の状態) |
| 1 行目 | `session` | セッション名 |
| 2 行目 | `model_ctx` | モデル名･effort･コンテキスト使用率 |
| 2 行目 | `rate` | 5 時間のレートリミット |
| 2 行目 | `weekly` | 週間 (7 日間) のレートリミット |

- 1 行目は書いたトークンだけが出る。`LAYOUT_LINE1="none"` のように既知でないトークンだけを書くと 1 行目ごと消える
- 2 行目は並び順だけを変えられる。書かなかったトークンは末尾に補われ、常に 3 つとも出る (`weekly` を書かなくても末尾に出る)
- 1 行構成へ戻す設定は無い

### ハイライト

ディレクトリ名やブランチ名など、色を付けずに端末の前景色で表示する要素のうち、`HIGHLIGHT` に書いたものを `COLOR_SCHEME` の文字色 (dark は白、light は黒) で塗って目立たせる。トークンは `|` で区切って並べる。

```bash
HIGHLIGHT="directory|branch|session|rate_chart|rate_reset"
```

| トークン | 塗る要素 |
| --- | --- |
| `directory` | ディレクトリ名 |
| `branch` | ブランチ名の最後の `/` より後ろ (`feature/xxx/yyy` なら `yyy`) |
| `session` | セッション名 |
| `model` | `✻` とモデル名 (Sonnet など色の付かないモデルのとき) |
| `ctx_chart` | コンテキスト使用率のスパーク |
| `rate_chart` / `rate_reset` | 5 時間のレートリミットのチャート / リセット時刻 |
| `weekly_chart` / `weekly_reset` | 週間のレートリミットのスパーク / リセットの曜日 |
| `pr_comments` | PR のコメントの件数 |

- 警戒域の ctx やレートリミット、Opus などのモデル色のように、もともと色が付いている状態ではその色が優先される
- 既定は `branch` (ブランチ名の末尾だけ)。どれも塗らないときは `HIGHLIGHT="none"` のように未知のトークンだけを書く (未知のトークンは無視され、空の値は既定値になる)
- `COLOR_SCHEME` を Claude Code のテーマに合わせておく。食い違うと、明るい背景に白い文字が重なるなどして読めなくなる
- 環境変数 `CLAUDE_STATUSLINE_HIGHLIGHT` を空にしても設定ファイルの値は消えない。一時的に無効にするときは `none` などの未知のトークンを渡す

### 数値の設定の範囲

`RATE_CHART_LEN` は 2〜20 文字、`POLL_INTERVAL_SEC` は 60〜(18000 ÷ `RATE_CHART_LEN`) 秒 (既定のチャート長 12 では 60〜1500)、`GIT_FETCH_INTERVAL_SEC` は 60〜1800 秒の範囲で使う。範囲外の値 (`0` を含む) は最寄りの境界へ自動で丸められ、空･負値･数値でない値は既定値に戻る (警告は出ない)。範囲の根拠は [docs/SPEC.md](docs/SPEC.md) を参照。

`POLL_INTERVAL_SEC` の上限は、チャート全体で 5 時間のレートリミットの枠を覆う間隔。チャートを短くすると長い間隔を選べ、長くすると細かい刻みで 5 時間を覆う。

### `GIT_FETCH=1` を使うときの注意

既定では `↑ahead↓behind` は最後に `git fetch` / `git pull` した時点の差を表示し、ネットワークにはアクセスしない。`GIT_FETCH=1` にすると、描画とは別のバックグラウンド処理で `git fetch` を実行し、次回以降の描画で `↓behind` が最新化される。fetch はカレントディレクトリごとに `GIT_FETCH_INTERVAL_SEC` (既定 15 分) に 1 回までに間引かれる。

バックグラウンド fetch は認証プロンプトを出さない。パスフレーズ入力やホスト鍵確認が Claude Code の画面に割り込むのを避けるためで、次の場合は fetch が表示なしで失敗し、`↓behind` は更新されない。

- SSH リモートで、鍵がパスフレーズ付きかつ ssh-agent に登録されていない
- ホスト鍵が `known_hosts` に無い (初回接続) か、変わっている
- HTTPS リモートで、資格情報ヘルパに認証情報が保存されていない

自動最新化を使うには、あらかじめ `ssh-add` で鍵を ssh-agent に登録するか、資格情報ヘルパを設定しておく。

### `PR_STATUS=1` で PR の状態を表示する

`PR_STATUS=1` にすると、現在のブランチに紐付く GitHub の PR をブランチ列の右端 (変更行数の右) に半角スペースで区切って表示する。既定 (`0`) では表示せず、`gh` で GitHub に問い合わせることもない。

```bash
PR_STATUS=1
```

```text
my-project | feature/login ↑1 3+10-2 #12✓ 3 | my-session
```

- `#12` には下線が付き、色は PR の状態を表す (approved 緑、レビュー待ち青紫、changes requested 赤、draft 無色、merged 紫 + 取り消し線、closed 無色 + 取り消し線)
- `✓` / `✗` / `●` は CI の成功 / 失敗 / 実行中で、`#12` に続けて表示する。チェックが無ければ出ない
- 末尾の `3` は PR のコメントの件数 (会話、行コメントとその返信、本文付きのレビュー)。GitHub の PR 一覧で吹き出しアイコンに出る数と同じで、0 件なら出ない
- PR が無い、または取得できないときは何も出ない
- `LAYOUT_LINE1` から `branch` を外すと PR も表示されず、`gh` も起動しない

使うための準備:

1. 最新版の `gh` をインストールする (`brew install gh` / [Linux](https://github.com/cli/cli#installation))
2. `gh auth login` で認証する
3. fork 構成などでリモートが複数あるときは、リポジトリで `gh repo set-default` を実行して PR の問い合わせ先を決めておく (決まっていないと取得に失敗し、表示されない)

動作について:

- 取得はバックグラウンドで行い、描画は待たない。そのため切り替え直後の数回の描画では表示されず、取得が終わった次の描画から出る
- statusline は Claude Code にイベントがあったときにしか更新されない。アイドル中に CI の完了なども反映させたいときは、`~/.claude/settings.json` の `statusLine` に `"refreshInterval": 30` を足す。描画はキャッシュを読むだけなので、30 秒ごとに再実行しても負荷は小さい
- 再取得の間隔は状態に応じて 30〜900 秒。1 回の問い合わせは GitHub API の GraphQL で 1 ポイントで、`gh` のほかの利用と同じ枠 (1 時間 5000 ポイント) を使う
- `#12` は OSC 8 のリンクで、対応端末 (iTerm2 など) では Cmd+click / Ctrl+click で PR を開ける。Terminal.app は OSC 8 に対応していないためクリックできない。SSH や tmux 越しではエスケープ列が落ちてリンクにならないことがある。環境変数 `FORCE_HYPERLINK=0` でリンクを出さなくできる
- Claude Code 標準のフッターの PR バッジとは別の場所に表示されるため、両方が並んで見える。標準のバッジは同じセッションで PR を切り替えると更新されないことがあるが、こちらは毎回いまのブランチの PR を表示する
- GitHub 以外 (GitLab など) のリモートには対応しない

## 表示内容

| 要素 | 内容 |
| --- | --- |
| ディレクトリ名 | カレントディレクトリ名。25 文字を超えると `…` で省略 |
| ブランチ名 | git ブランチ名。25 文字を超えると `…` で省略。最後の `/` より後ろが 22 文字以下なら、そこを残して中間を省略 (`feature/improve-sta…/trim`)。detached HEAD では短縮 sha |
| `↑N↓M` | リモート追跡ブランチとの差。`↑` が push 待ち、`↓` が pull 待ち。同期済みなら出ない |
| `*` | リモート追跡ブランチが無い (青) / detached HEAD (無色) |
| `3+13-5` | 作業ツリーの変更 (ファイル数 / 追加行 / 削除行)。未追跡ファイルを含む。変更が無ければ `·` |
| `#12✓ 3` | PR の番号･CI･コメントの件数 (`PR_STATUS=1` のときだけ) |
| セッション名 | 設定されているときだけ表示。40 文字を超えると `…` で省略 |
| `✻ モデル名` | モデル別の色で表示。13 文字を超えると `…` で省略 |
| effort | 推論強度 (`low` / `medium` / `high` / `xhigh` / `max`)。対応しないモデルでは出ない |
| コンテキスト使用率 | 1 文字のバー (`▁`〜`█`)。70% 以上で数値を併記 |
| レートリミット | 5 時間枠の残量の推移を `RATE_CHART_LEN` 文字 (既定 12) のバーで表示し、右端は常に現在値。残量 40% 以下で数値を併記し、リセット時刻を添える |
| 週間リミット | 7 日間枠の残量を 1 文字のバーで表示し、リセットの曜日 (`Sun`〜`Sat`) を添える。残量 40% 以下で数値を併記。値が無ければ `· --` |

- 値が無い要素は区切りごと省略する。1 行目の要素がすべて無いときは 1 行目ごと出さない。2 行目の要素は値が無くても省略しない
- レートリミットの履歴はすべてのセッションで共有する

### 表示例

通常 (警告なし、変更なし):

```text
my-project | main · | my-session
✻ Opus 4.7∙high ▄ | ▇▇▇▆▆▆▆▅▅▅▄▄ 18:30 | ▅ Thu
```

ブランチに変更と PR あり (`PR_STATUS=1`)、コンテキストとレートリミットが警告域:

```text
my-project | main ↑2↓3 3+13-5 #12✓ 3 | my-session
✻ Opus 4.7∙high ▆ 72% | ▇▇▇▆▆▆▅▅▄▄▃▃ 35% - 18:30 | ▅ Thu
```

週間リミットが警告域 (残量 22%):

```text
my-project | main · | my-session
✻ Opus 4.7∙high ▄ | ▇▇▇▆▆▆▆▅▅▅▄▄ 18:30 | ▂ 22% - Thu
```

長い名前は省略される (変更行数は省略されない):

```text
my-project | feature/improve-sta…/trim 1+8 | my-project-refactoring-and-cleanup-work…
✻ Opus 4.7∙high ▄ | ▇▇▇▆▆▆▆▅▅▅▄▄ 18:30 | ▅ Thu
```

`SHOW_MODEL_NAME=0`:

```text
my-project | main · | my-session
✻ xhigh ▄ | ▇▇▇▆▆▆▆▅▅▅▄▄ 18:30 | ▅ Thu
```

git 管理外でセッション名も無い:

```text
my-project
✻ Opus 4.7∙high ▄ | ▇▇▇▆▆▆▆▅▅▅▄▄ 18:30 | ▅ Thu
```

## 色の早見表

配色は Claude Code の light/dark テーマに合わせたもので、`COLOR_SCHEME` で切替える。下表は dark の場合の見え方。RGB 値を含む全パレットは [docs/SPEC.md](docs/SPEC.md) を参照。

| 対象 | 色 |
| --- | --- |
| モデル | Fable は紫、Opus はオレンジ、Haiku はシアン、それ以外 (Sonnet など) は無色 |
| effort | `low` 黄、`medium` 緑、`high` 青、`xhigh` 紫、`max` は 1 文字ずつ虹色 |
| コンテキスト使用率 | 70% 以上で黄、80% 以上でオレンジ、90% 以上で赤の点滅 |
| レートリミット残量 (5 時間 / 週間) | 40% 以下で黄、15% 以下でオレンジ、5% 以下で赤の点滅 |
| ブランチ列 | `↑` 青、`↓` 黄、追加行 緑、削除行 赤 |
| PR 番号 | 下線付き。approved 緑、pending 青紫、changes requested 赤、draft 無色、merged 紫 + 取り消し線、closed 無色 + 取り消し線 |
| PR の CI | `✓` 緑、`✗` 赤、`●` 黄 |

## 更新とアンインストール

### 更新

リポジトリを最新化し、使っている版のスクリプトを再度コピーする。`~/.claude/statusline.conf` はそのまま引き継がれる。設定ファイルに書いた値は既定値より優先されるため、既定値に従わせたい項目は設定ファイルから行を消す。

```bash
cd claude-code-statusline
git pull
cp statusline-macos.sh ~/.claude/statusline.sh
```

Linux では `statusline-linux.sh` をコピーする。

### アンインストール

1. `~/.claude/settings.json` から `statusLine` の設定を取り除く。
2. 配置したファイルを削除する。

   ```bash
   rm ~/.claude/statusline.sh ~/.claude/statusline.conf
   ```

3. 履歴ディレクトリ `/tmp/claude-statusline-<uid>/` は再起動で消える。すぐに消したい場合は `rm -r "/tmp/claude-statusline-$(id -u)"` を実行する。

## トラブルシューティング

### `✻ -- (...)` とだけ表示される

必要なコマンドや bash のバージョンが足りないときに、次の 1 行を表示して終了する。

| 表示 | 対処 |
| --- | --- |
| `✻ -- (jq required: brew install jq)` | macOS で `jq` をインストールする |
| `✻ -- (jq required: sudo apt install jq)` | Linux で `jq` をインストールする |
| `✻ -- (flock required: sudo apt install util-linux)` | Linux で `flock` をインストールする |
| `✻ -- (bash 4.1+ required)` | Linux 版を bash 4.1 以上で実行する |

### 何も表示されない

- `chmod +x ~/.claude/statusline.sh` で実行権限が付いているか確認する
- `~/.claude/settings.json` の `command` のパスが配置先と一致しているか確認する
- 手動で実行して出力を確認する。次のように 2 行目 (`✻ Unknown ...` など) が出れば、スクリプト自体は動いている

  ```bash
  echo '{}' | ~/.claude/statusline.sh
  ```

- `~/.claude/statusline.conf` に変数代入以外の行 (`exit` など) が無いか確認する

### 文字化けする

スクリプトは冒頭でロケールを `C.UTF-8` に固定している。`C.UTF-8` が無い古い環境 (Debian 10 以前など) では `✻` やバーが崩れたり、名前の省略位置がずれたりする。スクリプト冒頭の `export LC_ALL=C.UTF-8` を `en_US.UTF-8` など利用可能な UTF-8 ロケールに書き換える。

### `↓behind` が更新されない

既定では `git fetch` を実行しないため、`↓` は最後に fetch / pull した時点の値になる。自動で最新化するには `GIT_FETCH=1` を設定する。設定しても更新されない場合は、[`GIT_FETCH=1` を使うときの注意](#git_fetch1-を使うときの注意) の認証条件を確認する。

### PR が表示されない

- `PR_STATUS=1` になっているか、`LAYOUT_LINE1` に `branch` があるか確認する
- `gh auth status` で認証済みか、リポジトリで `gh pr view` が PR を表示できるか確認する。リモートが複数あるときは `gh repo set-default` を実行する
- ブランチを push していない、または push 先のブランチに PR が無いときは表示されない。マージ済み･クローズ済みの PR は、ローカルの HEAD がその PR の最後のコミットと一致するときだけ表示する
- 取得に失敗し続けると、最後に成功してから 30 分で表示が消える

### 色がおかしい

- 端末が truecolor (24bit カラー) に対応しているか確認する。非対応の端末では近似色になったり、制御文字がそのまま見えたりする
- 明るい背景の端末では `COLOR_SCHEME=light` を設定する

## プライバシーとセキュリティ

- `~/.claude/statusline.conf` はシェルスクリプトとして読み込まれ、描画のたびに実行される。信頼できない内容を書かない
- ネットワークにアクセスするのは、`GIT_FETCH=1` (`git fetch`) と `PR_STATUS=1` (`gh` による GitHub API への問い合わせ) を有効にしたときだけ
- レートリミットの履歴や PR のキャッシュは `/tmp/claude-statusline-<uid>/` にパーミッション 700 で保存する。他ユーザー所有やシンボリックリンクの場合は使わず、履歴と PR の状態なしで表示を続ける

## 開発者向け

このリポジトリは個人用で、Issue や Pull Request への対応は保証しない。受け付けても取り込むとは限らない。フォークして自由に改変して使ってよい ([0BSD](LICENSE))。

開発環境の準備やテストの実行方法は [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)、出力の仕様は [docs/SPEC.md](docs/SPEC.md) にまとめている。

## ライセンス

[0BSD](LICENSE)。著作権表示も不要で、自由にコピー･改変･再配布してよい。
