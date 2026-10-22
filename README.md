# statusline

Claude Code のステータスラインをカスタマイズするスクリプト集。macOS と Debian/Ubuntu の両環境に対応し、同一の表示内容を提供する。

## 概要

ステータスラインを次のような 2 行で表示する。

```text
agent-skills | main ↑2↓3 3+13-5 | my-session
✻ Opus 4.7∙high ▆ 72% | ▇▆▅▄▃▃ 35% - 18:30
```

コンテキスト使用率が高まる、またはレートリミット残量が減ると、色と数値で警告する。詳細は [提供する機能](#提供する機能) を参照。

## 使い方

### 要件

#### 共通要件

**依存コマンド** (両環境共通):

`bash`, `jq`, `awk`, `date`, `stat`, `mktemp`, `find`, `tail`, `mv`, `rm`, `git` (ブランチ名･変更行数表示用、無い場合はブランチ列が省略されるだけで他は動く)

#### macOS 固有の要件

- macOS (Darwin) であること
- bash 3.2 以上 (macOS デフォルトシェルが zsh でも bash として実行される)
- BSD 版 `stat` (`-f %m` オプション対応) / BSD 版 `date` (`-r <epoch>` オプション対応)
- `jq` がインストール済みであること (`brew install jq`)
- `C.UTF-8` ロケールが利用可能であること (現行 macOS は標準搭載)

#### Debian 固有の要件

- Debian/Ubuntu 系 Linux であること
- bash 5 系以上
- `jq` がインストール済みであること (`sudo apt install jq`)
- `flock` がインストール済みであること (`sudo apt install util-linux`)
- GNU 版 `stat` (`-c %Y` オプション対応) / GNU 版 `date` (`-d "@<epoch>"` オプション対応)
- `C.UTF-8` ロケールが利用可能であること (Debian 11 以降は標準搭載)

#### スクリプトの違い

表示内容･動作仕様は共通。プラットフォーム依存の実装のみが異なる。

| 項目 | statusline-macos-zsh.sh | statusline-debian-bash.sh |
| --- | --- | --- |
| 対応環境 | macOS + zsh (bash 3.2+) | Debian/Ubuntu 系 Linux + bash 5 系 |
| 排他制御 | `mkdir` の原子性 + stale ロック検出 | `flock(1)` (プロセス終了時に自動解放) |
| date/stat | BSD 版 (`date -r`, `stat -f %m`) | GNU 版 (`date -d "@.."`, `stat -c %Y`) |
| ロケール固定 | `LC_ALL=C.UTF-8` をスクリプト冒頭で固定 | `LC_ALL=C.UTF-8` をスクリプト冒頭で固定 |
| 起動時チェック | `jq` 欠如時に `brew install` を促して終了 | `jq`/`flock` 欠如時に `apt install` を促して終了 |

### セットアップ

#### macOS / zsh

1. 依存パッケージをインストールする (未導入の場合)。

   ```bash
   brew install jq
   ```

2. スクリプトを配置する。

   ```bash
   cp statusline-macos-zsh.sh ~/.claude/statusline.sh
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

#### Debian 系 Linux / bash

1. 依存パッケージをインストールする (未導入の場合)。

   ```bash
   sudo apt install jq util-linux
   ```

2. スクリプトを配置する。

   ```bash
   cp statusline-debian-bash.sh ~/.claude/statusline.sh
   chmod +x ~/.claude/statusline.sh
   ```

3. `~/.claude/settings.json` に以下を追加して、Claude Code を再起動する。

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh"
     }
   }
   ```

> [!NOTE]
> `C.UTF-8` ロケールが存在しない古い環境 (Debian 10 以前、古い macOS など) では、スクリプト冒頭の `LC_ALL=C.UTF-8` を `en_US.UTF-8` など利用可能なロケールへ差し替える。両スクリプト共通。

### カスタマイズ

設定ファイル `~/.claude/statusline.conf` に下表の定数を書くと、スクリプト本体を編集せずに挙動を変えられる。スクリプトを再コピーして更新しても設定は保持される。一部の定数は環境変数 `CLAUDE_STATUSLINE_*` でも上書きできる (値はすべて文字列として渡す)。

| 定数 | デフォルト | env 変数 | 説明 |
| --- | --- | --- | --- |
| `POLL_INTERVAL_SEC` | `480` | — | 履歴サンプリング間隔 (秒)。**推奨レンジ 60〜3000** |
| `SHOW_MODEL_NAME` | `1` | `CLAUDE_STATUSLINE_SHOW_MODEL_NAME` | モデル名の表示 ON/OFF。`"1"` = 表示 (`✻ <model>∙<effort>`、`∙` で区切る)、`"0"` = 非表示 (`✻ <effort>`)。`"0"` でも ✻ はモデル色で残す |
| `COLOR_SCHEME` | `dark` | `CLAUDE_STATUSLINE_COLOR_SCHEME` | カラースキーム。`"dark"` / `"light"` で公式テーマを切替える |
| `GIT_FETCH` | `0` | `CLAUDE_STATUSLINE_GIT_FETCH` | バックグラウンド `git fetch` のオプトイン。`"0"` = 無効 (従来動作、ネットワークに出ない)、`"1"` = 有効 (描画とは独立にバックグラウンドで fetch を投げ `↓behind` を自動最新化。描画はブロックしない)。下記の認証まわりの注意を参照 |
| `SHOW_CWD` | `1` | `CLAUDE_STATUSLINE_SHOW_CWD` | 1 行目のディレクトリ名表示の ON/OFF。`"1"` = 表示、`"0"` = 非表示。`"0"` でも 2 行構成は維持し、ブランチ列は 1 行目に残る (1 行構成へ戻す設定は無い) |
| `GIT_FETCH_INTERVAL_SEC` | `900` | — | バックグラウンド `git fetch` の最小間隔 (秒)。`GIT_FETCH=1` のとき、この間隔未満の連続呼び出しでは fetch を投げない。間引きは **cwd 単位** (同一 repo でもサブディレクトリや worktree が違えば別枠)。**推奨レンジ 60〜1800** |
| `LAYOUT_LINE1` | `directory\|branch\|session` | `CLAUDE_STATUSLINE_LAYOUT_LINE1` | 1 行目の表示要素の並び。下記｢レイアウト｣を参照 |
| `LAYOUT_LINE2` | `model_ctx\|rate` | `CLAUDE_STATUSLINE_LAYOUT_LINE2` | 2 行目の表示要素の並び。下記｢レイアウト｣を参照 |

レートリミットチャートの文字数 `HISTORY_LEN` (`6`) は出力フォーマットの一部なので変更できない (conf に書いても無視される)。履歴の保存先 `HISTORY_DIR` も conf の対象外で、変える場合は env `CLAUDE_STATUSLINE_HISTORY_DIR` を使う。

#### 設定ファイル (`~/.claude/statusline.conf`)

上表の定数名をそのまま、シェルの変数代入で書く。存在しなければ読み込まれず、既定値で動く。全項目をデフォルト値で埋めたテンプレート [`statusline.conf`](statusline.conf) をコピーし、変えたい行だけ書き換えるのが手早い。

```bash
cp statusline.conf ~/.claude/statusline.conf
```

```bash
# ~/.claude/statusline.conf
COLOR_SCHEME=light
GIT_FETCH=1
POLL_INTERVAL_SEC=600
GIT_FETCH_INTERVAL_SEC=1200
```

同じ定数を複数の場所で指定したときは、次の順に優先される。

| 優先度 | 出所 | 例 |
| --- | --- | --- |
| 高 | env 変数 (`CLAUDE_STATUSLINE_*`) | `CLAUDE_STATUSLINE_COLOR_SCHEME=dark` |
| 中 | `~/.claude/statusline.conf` | `COLOR_SCHEME=light` |
| 低 | スクリプト内の既定値 | `dark` |

- conf に書くのは**短縮名** (`COLOR_SCHEME`) で、env 変数名 (`CLAUDE_STATUSLINE_COLOR_SCHEME`) ではない。env 変数名で書くと env 側の値を上書きしてしまい、上の優先順位が崩れる
- 環境変数 `CLAUDE_STATUSLINE_CONFIG` で読み込むファイルを差し替えられる (テスト用)
- 読めないとき (権限が無い･ディレクトリである等) は黙って無視し、既定値で描画を続ける

> [!WARNING]
> conf は**シェルスクリプトとして読み込まれる** (`.` で source する)。変数代入以外のコマンドも描画のたびに実行されるため、信頼できない内容を書かないこと。標準出力に何か出すコマンドはその文字列が statusline に混ざり、`exit` を書くと描画そのものが止まる。`=` の前後にスペースを入れる (`COLOR_SCHEME = light`) と代入ではなくコマンド実行になる。

#### レイアウト (`LAYOUT_LINE1` / `LAYOUT_LINE2`)

表示要素 (トークン) を `|` で区切って並べる。トークン間は常に ` | ` で結合される。conf に書くときは `|` がシェルのパイプとして解釈されないよう**クォートで囲む**。

```bash
# ~/.claude/statusline.conf
LAYOUT_LINE1="session|directory|branch"
LAYOUT_LINE2="rate|model_ctx"
```

| 行 | トークン | 内容 |
| --- | --- | --- |
| 1 行目 | `directory` | ディレクトリ名 |
| | `branch` | ブランチ名 + ahead/behind + 変更行数 (1 塊で並べ替わる) |
| | `session` | セッション名 |
| 2 行目 | `model_ctx` | `✻ <model>∙<effort> <ctx>` (1 塊で並べ替わる) |
| | `rate` | レートリミット |

- 1 行目: 書かなかったトークンは出ない。値が空のトークン (git 外の `branch` 等) は区切りごと省略し、すべて空なら 1 行目ごと出さない
- 2 行目: 変えられるのは `model_ctx` と `rate` の**順番だけ**。書かなかったトークンは末尾に補われ、2 行目は常に両方を出す
- `model` と `ctx`、`branch` と変更行数のように 1 トークンに束ねた要素は、個別に並べ替えられない
- 未知のトークンは黙って無視する。前後の空白 (スペース･タブ) は無視し、同じトークンを重ねて書くと最初の 1 回だけ採る
- 空文字は既定値扱い。1 行目を丸ごと消したいときは `LAYOUT_LINE1="none"` のように既知でないトークンだけを書く
- `SHOW_CWD=0` は `LAYOUT_LINE1` から `directory` を外すのと同じ効果で、レイアウトと併用できる

#### 間引き間隔 (`POLL_INTERVAL_SEC` / `GIT_FETCH_INTERVAL_SEC`) の推奨レンジ

この 2 つは env 変数を持たないため、値を変えるには conf に書く。**推奨レンジを外れた値は起動時に最寄りの境界へ自動で丸められる** (警告は出ない)。`0`･負値･数値でない値は既定値 (`480` / `900`) へ戻る。

| 定数 | 推奨レンジ | 下限の理由 | 上限の理由 |
| --- | --- | --- | --- |
| `POLL_INTERVAL_SEC` | 60〜3000 秒 | statusline は数秒〜十数秒間隔で呼ばれるため、60 秒を下回ると間引きの意味が失われ履歴が毎回更新される | レートリミットは 5 時間 (18000 秒) ウィンドウで履歴は 6 サンプル。18000 ÷ 6 = 3000 秒を超えるとウィンドウ全体をカバーできず、チャートが傾向を示さなくなる |
| `GIT_FETCH_INTERVAL_SEC` | 60〜1800 秒 | 60 秒を下回ると間引きが実質機能せず、`git fetch` の子プロセスが頻発する (ネットワークアクセスと認証プロセスの起動が連続する)。間引きは cwd 単位なので、同じリポジトリを複数の worktree で開いているほど fetch の総数は増える | 30 分を超えると `↓behind` の自動最新化が遅すぎて、手動 `git fetch` と大差なくなる |

#### `GIT_FETCH=1` を有効にするときの注意

バックグラウンド fetch は**認証を一切求めない**。ターミナルにパスフレーズ入力やホスト鍵確認のプロンプトが割り込むと Claude Code の TUI を壊し、キー入力まで奪われるため、`GIT_TERMINAL_PROMPT=0` と `SSH_ASKPASS_REQUIRE=force` で対話を封じて即座に諦めさせている。

したがって次の場合、fetch は**静かに失敗し `↓behind` は更新されない** (エラーも表示されない。これは意図した挙動):

- SSH リモートで、鍵がパスフレーズ付きかつ ssh-agent に登録されていない
- ホスト鍵が `known_hosts` に無い (初回接続) / 変わっている
- HTTPS リモートで、資格情報ヘルパに認証情報が保存されていない

自動最新化を効かせたい場合は、あらかじめ `ssh-add` で鍵を agent に登録するか、資格情報ヘルパを設定しておくこと。

## 提供する機能

### 表示内容

**2 行構成**で表示する。

- **1 行目**: **ディレクトリ → ブランチ → セッション**
- **2 行目**: **モデル → effort → コンテキスト → レートリミット**

モデルと effort の間は `∙` (前後スペースなし)、effort とコンテキストの間はスペース 1 個で詰め、残りの要素は両行とも `|` 区切りで連結する。

空の要素は列ごと省略する (区切りも出さない)。1 行目はディレクトリ･ブランチ･セッションが**すべて空のとき行ごと省略**し、空行を出さない (モデル行のみの 1 行出力になる)。

| 要素 | 説明 |
| --- | --- |
| `✻ モデル名` | ✻ アイコンとモデル名をモデルに応じた色で表示 (13 文字でトリム)。モデル名表示は `SHOW_MODEL_NAME` で ON/OFF 可能 (OFF でも ✻ はモデル色で残す)。直後に effort を `∙` 区切りで、さらにコンテキスト使用率をスペース区切りで併記する |
| effort (推論強度) | 入力 JSON の `effort.level` (`low` / `medium` / `high` / `xhigh` / `max`) を別色で表示 (トリムしない)。モデル名表示 ON のときは `∙` (前後スペースなし) で区切る、OFF のときは `∙` なしでスペース連結。`∙` は着色せず effort 語句のみを塗る (`max` でも `∙` はレインボー循環に入らない)。effort 非対応モデルで欠落時は非表示 |
| コンテキスト使用率 | 現在値 1 文字のスパークライン (70% 以上のときのみ数値%を併記) |
| レートリミット残量 | 履歴 6 サンプルのスパークライン + リセット時刻 (残量 40% 以下のときのみ数値%を併記) |
| ブランチ名 | カレントディレクトリの git ブランチ名 (25 文字でトリム、detached HEAD では短縮 sha)。git 外では列ごと省略。右にリモート追跡ブランチとの差 `↑ahead↓behind` (例 `↑2↓3`)、続けて作業ツリーの変更行数 `<ファイル数><+追加 緑><-削除 赤>` を区切りなしで詰めて併記 (例 `3+13-5`、クリーン時は非表示、片方 0 はその側を省略)。ahead/behind は既定ではネットワークに出ず直近の fetch/pull 時点の差を表示する。`GIT_FETCH=1` でオプトインすると、描画とは独立にバックグラウンド fetch を投げて `↓behind` を自動最新化する (cwd ごとに `GIT_FETCH_INTERVAL_SEC` (既定 15 分) で間引き、投げっぱなしで描画はブロックしない) |
| セッション名 | 現在のセッション名 (40 文字でトリム、設定されている場合のみ)。1 行目の末尾に置く |
| ディレクトリ名 | カレントディレクトリ名 (`workspace.current_dir` の basename、25 文字でトリム)。1 行目の**先頭**に副次色 (`secondaryText`) で表示する。複数セッションを並行しているときに、いまどのプロジェクトを触っているかを判別するための列。`cwd` が `/` または空で basename が空になる場合は列ごと省略。`SHOW_CWD` で ON/OFF 可能 (OFF でもブランチ列とセッション名は 1 行目に残る)。git を追加で呼ばずパラメータ展開のみで求める |

#### 入力 JSON フィールド

stdin 経由で Claude Code から渡される JSON のうち、次のフィールドを使う。

| フィールド | 用途 |
| --- | --- |
| `model.display_name` | モデル名･色分け |
| `context_window.used_percentage` | コンテキスト使用率 |
| `rate_limits.five_hour.used_percentage` | レートリミット使用率 |
| `rate_limits.five_hour.resets_at` | レートリミットリセット時刻 (epoch 秒) |
| `session_name` | セッション名 |
| `workspace.current_dir` | カレントディレクトリ (ブランチ名の取得と、1 行目のディレクトリ名表示に使う) |
| `effort.level` | 推論強度 (`low` / `medium` / `high` / `xhigh` / `max`)･色分け。欠落時は非表示 |

### 表示例

通常 (閾値未満、クリーン):

```text
agent-skills | main | my-session
✻ Opus 4.7∙high ▄ | ▇▆▅▄▃▂ 18:30
```

ブランチに変更あり (ファイル数 / +追加 緑 / -削除 赤 を詰めて表示):

```text
agent-skills | main ↑2↓3 3+13-5 | my-session
✻ Opus 4.7∙high ▄ | ▇▆▅▄▃▂ 18:30
```

トリム後も変更行数を併記 / 削除 0 は省略:

```text
agent-skills | feature/improve-awesome-… 1+8 | agent-skills-refactoring-and-cleanup-pr…
✻ Opus 4.7∙high ▆ 72% | ▇▆▅▄▃▃ 35% - 18:30
```

ctx 危険域 + 削除のみ (セッション名なし):

```text
agent-skills | hotfix/bug-1234 2-5
✻ Opus 4.7∙high ▇ 92% | ▇▆▅▄▃▂ 18:30
```

effort をモデル名の右に `∙` 区切り (前後スペースなし) で別色併記 (`max` はレインボー)。`SHOW_MODEL_NAME=0` ではモデル名を出さず `✻` (モデル色) + effort のみ (`∙` なし):

```text
agent-skills | main | my-session
✻ Opus 4.7∙xhigh ▄ | ▇▆▅▄▃▂ 18:30

agent-skills | main | my-session
✻ xhigh ▄ | ▇▆▅▄▃▂ 18:30
```

Fable は `✻` とモデル名が紫 (公式テーマの `autoAccept`)。テキストでは色を表現できないため、見た目は端末で確認する:

```text
agent-skills | main | my-session
✻ Fable 5∙high ▄ | ▇▆▅▄▃▂ 18:30
```

ブランチが取れない場合 (git 外) は 1 行目からブランチ列だけが落ちる:

```text
agent-skills | my-session
✻ Opus 4.7∙high ▄ | ▇▆▅▄▃▂ 18:30
```

ディレクトリ名･ブランチ･セッション名がいずれも無い場合は 1 行目ごと省略し、モデル行だけの 1 行出力になる (空行を出さない):

```text
✻ Opus 4.7∙high ▄ | ▇▆▅▄▃▂ 18:30
```

### カラーパレット

statusline で使えるのは、Claude Code 公式テーマ (`getTheme`) からハードコピーした**事前定義のセマンティックカラー**と、effort `max` 専用の**レインボーパレット**の 2 つ。`COLOR_SCHEME` (既定 `dark`) で light / dark を切替える。

#### 事前定義セマンティックカラー

スクリプト内では `COLOR_<キー>` 定数 (truecolor ANSI、`\033[38;2;R;G;Bm`) として全色を保持している。RGB は公式テーマの値、#hex はエディタでの色プレビュー用 (スクリプトでは RGB を使用)。

| キー (公式) | dark RGB | dark | light RGB | light |
| --- | --- | --- | --- | --- |
| `autoAccept` | `175;135;255` | #AF87FF | `135;0;255` | #8700FF |
| `bashBorder` | `253;93;177` | #FD5DB1 | `255;0;135` | #FF0087 |
| `claude` | `215;119;87` | #D77757 | `215;119;87` | #D77757 |
| `permission` | `177;185;249` | #B1B9F9 | `87;105;247` | #5769F7 |
| `secondaryBorder` | `136;136;136` | #888888 | `153;153;153` | #999999 |
| `text` | `255;255;255` | #FFFFFF | `0;0;0` | #000000 |
| `secondaryText` | `153;153;153` | #999999 | `102;102;102` | #666666 |
| `suggestion` | `177;185;249` | #B1B9F9 | `87;105;247` | #5769F7 |
| `remember` | `177;185;249` | #B1B9F9 | `0;0;255` | #0000FF |
| `success` | `78;186;101` | #4EBA65 | `44;122;57` | #2C7A39 |
| `error` | `255;107;128` | #FF6B80 | `171;43;63` | #AB2B3F |
| `warning` | `255;193;7` | #FFC107 | `150;108;30` | #966C1E |
| `diff_added` | `34;92;43` | #225C2B | `105;219;124` | #69DB7C |
| `diff_removed` | `122;41;54` | #7A2936 | `255;168;180` | #FFA8B4 |
| `diff_addedDimmed` | `71;88;74` | #47584A | `199;225;203` | #C7E1CB |
| `diff_removedDimmed` | `105;72;77` | #69484D | `253;210;216` | #FDD2D8 |
| `diff_addedWord` | `56;166;96` | #38A660 | `47;157;68` | #2F9D44 |
| `diff_removedWord` | `179;89;107` | #B3596B | `209;69;75` | #D1454B |
| `diff_addedWordDimmed` | `46;107;58` | #2E6B3A | `144;194;156` | #90C29C |
| `diff_removedWordDimmed` | `139;57;69` | #8B3945 | `232;165;173` | #E8A5AD |
| `planMode` | `0;102;102` | #006666 | `51;102;102` | #336666 |
| `effortUltra` | `135;0;255` | #8700FF | `135;0;255` | #8700FF |
| `rate_limit_fill` | `87;105;247` | #5769F7 | `51;102;255` | #3366FF |
| `rate_limit_empty` | `39;47;111` | #272F6F | `23;46;114` | #172E72 |
| `claudeShimmer` | `245;149;117` | #F59575 | `255;183;101` | #FFB765 |
| `permissionShimmer` | `137;155;255` | #899BFF | `101;152;255` | #6598FF |
| `warningShimmer` | `200;158;80` | #C89E50 | `255;183;50` | #FFB732 |
| `professionalBlue` | `106;155;204` | #6A9BCC | `106;155;204` | #6A9BCC |
| `chromeYellow` | `251;188;4` | #FBBC04 | `251;188;4` | #FBBC04 |
| `subtle` | `175;175;175` | #AFAFAF | `175;175;175` | #AFAFAF |
| `inactive` | `102;102;102` | #666666 | `102;102;102` | #666666 |
| `merged` | `135;0;255` | #8700FF | `135;0;255` | #8700FF |
| `fastMode` | `255;106;0` | #FF6A00 | `255;106;0` | #FF6A00 |
| `fastModeShimmer` | `255;150;50` | #FF9632 | `255;150;50` | #FF9632 |
| `subagent_red` | `220;38;38` | #DC2626 | `204;0;0` | #CC0000 |
| `subagent_orange` | `217;119;87` | #D97757 | `255;128;0` | #FF8000 |
| `subagent_yellow` | `202;138;4` | #CA8A04 | `255;204;0` | #FFCC00 |
| `subagent_green` | `22;163;74` | #16A34A | `0;204;0` | #00CC00 |
| `subagent_cyan` | `8;145;178` | #0891B2 | `0;178;178` | #00B2B2 |
| `subagent_blue` | `106;155;204` | #6A9BCC | `0;102;204` | #0066CC |
| `subagent_purple` | `130;125;189` | #827DBD | `128;0;128` | #800080 |
| `subagent_pink` | `196;102;134` | #C46686 | `255;102;178` | #FF66B2 |

> [!NOTE]
> セマンティックキー (`success` / `error` / `warning` / `claude` / `permission` / `autoAccept` / `planMode` / `effortUltra` …) は公式キーをそのまま維持する。`subagent_*` は公式 `<color>_FOR_SUBAGENTS_ONLY` の短縮名。現状の表示で実際に使うのは一部のみだが、将来用に全色を保持している。
>
> 致命段に重ねる点滅 (`\033[5m`) は色ではなく ANSI 属性であり、上表の RGB とは独立。

#### レインボーパレット (effort `max` 専用、light / dark 共通)

effort `max` のみ 1 文字ずつ下記 7 色 (赤→橙→黄→緑→青→藍→紫) で着色する。`COLOR_SCHEME` に依存しない固定パレット (`RAINBOW_PALETTE`)。

| # | RGB | hex |
| --- | --- | --- |
| 0 | `235;95;87` | #EB5F57 |
| 1 | `245;139;87` | #F58B57 |
| 2 | `250;195;95` | #FAC35F |
| 3 | `145;200;130` | #91C882 |
| 4 | `130;170;220` | #82AADC |
| 5 | `155;130;200` | #9B82C8 |
| 6 | `200;130;180` | #C882B4 |

#### ✻ アイコンとモデル名の色 (モデル別)

色は Claude Code 公式テーマ (light / dark) のセマンティック色をそのまま使う。`COLOR_SCHEME` (既定 `dark`) で切替える。下表の色名は公式テーマのキー。

| モデル | 色 (公式キー) |
| --- | --- |
| Fable | 紫 (`autoAccept`) |
| Opus | オレンジ (`claude`) |
| Sonnet | 無色 |
| Haiku | シアン (`subagent_cyan`) |

判定はモデル名の部分一致で行うため、バージョンを問わず適用される (例 `Fable 5` / `Fable 5 (1M context)` はいずれも紫)。

#### effort (推論強度) の色

| level | 色 (公式キー) |
| --- | --- |
| low | 黄 (`warning`) |
| medium | 緑 (`success`) |
| high | 青 (`permission`) |
| xhigh | 紫 (`autoAccept`) |
| max | レインボー (1 文字ずつ 7 色パレットで着色) |
| 欠落 (effort 非対応モデル) | 非表示 |

ultracode は入力 JSON 上 `xhigh` と区別できないため専用色を持たない (`xhigh` と同じ紫になる)。

#### コンテキスト使用率の色

| 使用率 | 色 (公式キー) |
| --- | --- |
| 90% 以上 | 赤 + 点滅 (`error` + `\033[5m`) |
| 80% 以上 | 橙 (`claude`) |
| 70% 以上 | 黄 (`warning`) |
| それ以外 | 無色 |

#### レートリミット残量の色

| 残量 | 色 (公式キー) |
| --- | --- |
| 5% 以下 | 赤 + 点滅 (`error` + `\033[5m`) |
| 15% 以下 | 橙 (`claude`) |
| 40% 以下 | 黄 (`warning`) |
| それ以上 | 無色 |

公式テーマは警告 (`warning`) と異常 (`error`) の 2 段しか持たないため、中間の危険段に `claude` (橙) を混色して 3 階調にしている。致命段は色 (`error`) ではなく点滅属性で警告段と区別する。

### 変更行数表示 (ブランチ列)

ブランチ名の右に作業ツリーの変更行数を `<ファイル数><+追加><-削除>` の形式で区切りなしで詰めて併記する (例 `3+13-5` = 3 ファイル変更, +13 行, -5 行)。

| 項目 | 仕様 |
| --- | --- |
| 表示順 | `<ファイル数><+追加><-削除>` を区切りなしで詰めて連結 |
| 変更ファイル数 | 先頭に表示 (プレフィックス記号なし、前景色 `text` = ブランチ名と同色) |
| 集計範囲 | 追跡変更 `git diff HEAD --numstat` (ステージ済み + 未ステージ) + 未追跡ファイル |
| 未追跡ファイル | 含める。`git status -z` (NUL 終端) で列挙し、各ファイルを `git diff --no-index --numstat` で全行を追加 (+) として加算 (gitignore 対象は除外)。未追跡が 50 件を超えた分は行数取得をスキップしファイル数のみ数える (描画遅延対策) |
| バイナリファイル | numstat が行数を `-` で返すため行数加算からは除外。ただしファイル数にはカウントする |
| 色 | ファイル数は前景色 (`text`、dark=白 / light=黒)、追加 `+N` は緑 (`success`)、削除 `-N` は赤 (`error`) |
| クリーン時 (ファイル数 0 かつ追加 0 かつ削除 0) | 何も表示せずブランチ名のみ |
| 片方が 0 のとき | その側を省略 (追加のみ→`3+8`、削除のみ→`2-5`)。ファイル数は変更があれば常に表示 |
| トリム | ブランチ名のみ 25 文字でトリム。変更行数はトリム対象外 (ブランチ名が切れても残る) |

### 履歴の仕組み

- 履歴は **レートリミットのみ**に持つ (コンテキストは現在値 1 文字 spark のため履歴不要)
- 履歴ファイルは `/tmp/claude-statusline-<uid>/` 配下にパーミッション 700 で作成
- `POLL_INTERVAL_SEC` (既定 480 秒) 間隔でサンプリング (連続呼び出しはスキップ)
- チャートの**右端 1 文字は常に現在値を反映** (サンプリング間隔と独立)。左 5 文字が履歴の遷移を表す。レートリミットのリセット直後でも右端が即座に最新残量を示すため、リセット時の表示タイムラグが生じない
- レートリミット履歴は全セッション共通の 1 ファイル
- 履歴ファイルの読み書きは排他制御し、ロック待機は最大 2 秒 (`LOCK_TIMEOUT_SEC`)
- `/tmp` は再起動で自動消滅するため長期蓄積しない

### トリム仕様

- モデル名･ブランチ名･セッション名･ディレクトリ名は **bash の `${#var}` / `${var:0:N}` で文字数換算**してトリムする
- トリム上限は要素ごとに異なる: **モデル名 13 文字 / ブランチ名 25 文字 / セッション名 40 文字 / ディレクトリ名 25 文字**
- 上限以下: そのまま表示
- 上限超: 先頭 (上限 − 1) 文字 + `…` (U+2026) (例: ブランチ名は先頭 24 文字 + `…`)
- 文字数カウントはスクリプト冒頭で固定する `LC_ALL=C.UTF-8` に依存する。`${#var}` はロケール依存で `C` ロケール下ではバイト数換算になるため、両スクリプトとも UTF-8 ロケールを明示固定して文字数換算へ揃えている
- ASCII 文字は 1 文字 = 1 バイトなので、ロケールに関係なく上限文字数でトリムされる
- 日本語など CJK 文字も 1 文字としてカウントされ、上限文字数までは `…` トリムされない。ただし CJK の表示幅は端末上およそ 2 倍のため、トリムされなくても表示が崩れて見えることがある (運用上 CJK は想定外)
- 表示幅ベースの厳密なトリムが必要な場合は別 Issue で検討する

## 開発者向け

statusline を編集する前に必ず以下を参照する。

- [CLAUDE.md](./CLAUDE.md) — 編集時の必須チェックリストと触ってはいけない仕様の一覧 (過去の事故防止)
- 回帰テスト: `npm test` — 次の 2 本を続けて実行する
  - `tests/regression.sh` — 出力フォーマットの自動検証
  - `tests/git-fetch-behavior.sh` — バックグラウンド `git fetch` の挙動検証 (非ブロッキング･間引き･ロック解放。出力に現れないため別建て)
- E2E プレビュー: `npm run preview` — ANSI 色を含む実出力を端末で目視確認

回帰テストと E2E プレビューは、本番履歴 dir (`/tmp/claude-statusline-<実uid>/`) の汚染を防ぐ仕組みを備える。具体的には `CLAUDE_STATUSLINE_HISTORY_DIR` 環境変数で `HISTORY_DIR` を上書きし、`mktemp -d` で作った一時 dir に履歴を隔離する。実行終了後は一時 dir を削除する。
