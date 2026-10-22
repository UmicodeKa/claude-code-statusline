# statusline 編集ガード

> [!CAUTION]
> このリポジトリのスクリプト (とりわけ `statusline-macos-zsh.sh` / `statusline-debian-bash.sh`) を編集する前に**必ず本書を最後まで読むこと**。過去に PR の目的仕様を読まずに変更を加え、出力フォーマットを破壊した事故が複数回発生している。

## 触ってはいけない仕様

両 statusline スクリプトで**完全に同一の出力を返す**ことが要件。下記は仕様であり、堅牢化･整理の名目で変更しない。

### 出力構造

| 要素 | 仕様 |
| --- | --- |
| 区切り | ` \| ` (スペース･パイプ･スペース、両側スペース必須)。ただし `<model>`↔`<effort>` 間は `∙` (前後スペースなし)、`<effort>` ↔ `<ctx_str>` 間はスペース 1 個でパイプを出さない (下記｢並び｣参照) |
| 行数 | **2 行構成** (UmicodeKa/agent-skills#250)。1 行目 = `[<directory>] [\| <branch><ab><diff>] [\| <session_name>]` (既定。並びは `LAYOUT_LINE1` で変えられる)、2 行目 = `✻ <model>∙<effort> <ctx_str> \| <rate_str>`。複数行は公式サポート済み (`echo`/`print` ごとに 1 行として描画される)。**1 行構成へ戻す設定は設けない** (戻せる口を用意すると両方の期待値をテストで維持し続けることになるため)。`LAYOUT_LINE1` で 1 行目の要素をすべて外すと 1 行目が出なくなるが、これは git 外などで 1 行目が空になるのと同じ｢1 行目の省略｣であり、1 行目の要素を 2 行目へ戻す 1 行構成ではない |
| 並び (1 行目) | `<directory> \| <branch><ab><diff> \| <session_name>`。directory 列が**先頭**、branch 列がその右、`session_name` が**末尾** (= `LAYOUT_LINE1` の既定値 `directory\|branch\|session`。並べ替え･省略はレイアウトでのみ行い、既定値は変えない)。空値は列ごと省略 (区切りも出さない)。**directory･branch･session_name がすべて空のときは 1 行目ごと省略し、改行そのものを出さない** (空行は statusline の高さを 1 行占有してしまう)。実装は 2 行目の `parts` とは**別の配列** (`line1_parts`) で組み立て、要素が 1 つ以上あるときだけ `join_by` の結果 + 改行を出す。**改行は 1 行目の末尾に置く** (2 行目の先頭に置くと 1 行目が無いとき先頭へ空行が出る) |
| 並び (2 行目) | `✻ <model>∙<effort> <ctx_str> \| <rate_str>` (`<model>`↔`<effort>` 間は `∙` (前後スペースなし)、`<effort>` ↔ `<ctx_str>` の間は**スペース 1 個**でパイプを出さない。残りの区切りはすべて ` \| `)。`effort` 欠落時は `∙<effort>` を出さず `✻ <model> <ctx_str> …` に詰める。`SHOW_MODEL_NAME=1` のときだけ `<model>` と `<effort>` を `∙` (無色、前後スペースなし) で区切る (OFF のときは `∙` を出さず `✻ <effort>` とスペース 1 個で連結)。**`session_name` は 2 行目に置かない** (1 行目末尾へ移動済み)。2 行目は**常に出力する** (条件付きで省略されるのは 1 行目のみ)。`LAYOUT_LINE2` (既定 `model_ctx\|rate`) で変えられるのは `model_ctx` と `rate` の**順番だけ** |
| `directory` | `cwd` (`workspace.current_dir`) の basename を `${cwd##*/}` で取る (**追加の `git` 呼び出しを描画経路に足さない**。パラメータ展開のみで完結させる)。25 文字でトリム、超過時は先頭 24 文字 + `…`。`cwd` が `/` または空のとき `${cwd##*/}` は**空文字になる**ため列ごと省略する。色は `COLOR_secondaryText` (dark `153;153;153` / light `102;102;102`) を `paint <text> static "$COLOR_secondaryText"` で塗る。`repo.name` / `project_dir` を優先する案は採らない (前者は git 外で欠落し分岐が増える、後者は起動ディレクトリなので cd するとずれる) |
| `model` | `✻` とモデル名を 13 文字でトリム、超過時は先頭 12 文字 + `…` (U+2026)。色判定 (Fable→紫 / Opus 等→単色) はトリム前の全長で行う。`SHOW_MODEL_NAME=0` のときはモデル名を出さず `✻` 単体を描画する (色は `model_color` のまま=モデル別。記号の色でモデルを判別するため) |
| `effort` | `.effort.level` の値そのまま (`low`/`medium`/`high`/`xhigh`/`max`)。`model` とは**別色･別 paint** で塗る。**トリムしない** (最長 5 文字の固定語彙)。欠落 (effort 非対応モデル) 時は非表示。`max` は rainbow、それ以外は単色 (色閾値表参照)。`SHOW_MODEL_NAME=1` のときは `<model>` との間を `∙` (無色、前後スペースなし) で区切る (`∙` は塗らず effort 語句のみ着色。`max` でも `∙` は rainbow 循環に入らない)、`0` のときは `∙` なしでスペース連結 |
| `branch` | git 外 / `cwd` 空 / `git` 未インストール時は**列ごと省略** (区切りも出さない) |
| `session_name` | 空のとき**末尾要素ごと省く** (区切りも出さない) |
| `branch` | 25 文字でトリム、超過時は先頭 24 文字 + `…` (U+2026)。文字数換算は `LC_ALL=C.UTF-8` 固定に依存 |
| `session_name` | **40 文字**でトリム、超過時は先頭 39 文字 + `…` (U+2026)。文字数換算は `LC_ALL=C.UTF-8` 固定に依存。2 行化で余裕ができたため 20 → 40 に拡大した (UmicodeKa/agent-skills#250)。20 に戻さない。配置は**1 行目の末尾** (branch 列の右。`LAYOUT_LINE1` の既定値での位置) |
| 変更行数 (branch 列内) | ブランチ名の右に `<files><+add><-del>` を**区切りなしで詰めて**併記 (例 `3+13-5`)。ファイル数は `text` (前景色。dark=白 `255;255;255` / light=黒 `0;0;0`)、`+N` は `success` (緑)、`-N` は `error` (赤)。`COLOR_text`/`COLOR_success`/`COLOR_error` は既に実 ESC 化済みなので `$(printf '\033[..m')` でラップせず `static` へ直接渡す。集計は追跡変更 `git diff HEAD --numstat` (ステージ + 未ステージ) + 未追跡 `git status -z` の `??` を `git diff --no-index --numstat -- /dev/null <path>` で取得し全行を `+` に加算。未追跡列挙は `git status -z` (NUL 終端･クォートなし、空白/改行入りパスも安全)。`diff --no-index` は `UNTRACKED_DIFF_LIMIT` (=50) 件まで実行し、超過分は行数取得をスキップしファイル数のみ数える (大量未追跡時の fork による描画遅延対策)。numstat 行数 = 変更ファイル数 (バイナリ行 `-\t-` もファイル数に数えるが行数加算はしない)、`files`/`add`/`del` すべて 0 のとき非表示、`+0`/`-0` はその側を省略、ファイル数は変更があれば常に表示、`truncate` 対象外 (ブランチ名が切れても残す)。ファイル数も `paint`〜`static` 経由で色を付ける (色付き `static` は末尾改行を付けないので出力は崩れない) |
| ahead/behind (branch 列内) | ローカルとリモート追跡ブランチ (`@{upstream}`) の差を、ブランチ名の右**･変更行数の左**に併記 (例 `main ↑2↓3 3+13-5`)。`↑N` (ahead=push 待ち) は `professionalBlue` (青 `106;155;204`、light も同 RGB)、`↓M` (behind=pull 待ち) は `warning` (黄。dark `255;193;7` / light `150;108;30`)。**ahead に `success` (緑) は使わない** (隣接する変更行数の `+add` が緑を使い混ざるため)。ahead を先に置き `↑N↓M` を**区切りなしで詰める**。ahead/behind は**別 paint** で塗る。`COLOR_professionalBlue`/`COLOR_warning` は実 ESC 化済みなので `static` へ直接渡す。取得は `git rev-list --left-right --count '@{upstream}...HEAD'` で**ローカル完結** (左=behind, 右=ahead)。**描画経路 (`git_ahead_behind`) は同期 `git fetch` を呼ばない** (ネットワーク I/O を持ち込まない)。ただし `GIT_FETCH=1` (既定 `0`) のオプトイン時のみ、描画経路とは別のバックグラウンド子プロセス (`maybe_git_fetch`) で投げっぱなしの `git fetch` を行い、その成果は次回以降の再描画の rev-list に反映する (今回の描画は待たない)。rev-list が非ゼロ終了する (ab を出せない) ときは**ブランチ未発行を `*` で可視化**する: **upstream 未設定 (branch は取れるが `@{upstream}` 無し) = 青 `*` (`professionalBlue`)** / **detached HEAD (`branch --show-current` 空･rev-parse 短縮 sha 代替。`@{upstream}` が無く rev-list 失敗) = 無色 `*` (前景色 = `text`。dark 白 / light 黒)**。`*` は ahead/behind と同じ位置 (branch の右･変更行数の左)。**同期済み (ahead=behind=0) のみ `*` を出さずフィールドごと省略** (branch は取れているのに ab だけ空、が正常系として存在)。git 外 (branch 空) は branch 列ごと省略され本フィールドに到達しない。`*` は ASCII (U+002A、1 バイト)。｢branch は取れるのに rev-list だけ失敗｣するリポジトリ内異常系も upstream 未設定と exit code で区別できないため一律 青 `*` 扱い (区別のための追加 `git` 呼び出しはしない)。`↑`=U+2191 / `↓`=U+2193 は `LC_ALL=C.UTF-8` 下で 3 バイト。`↑N↓M`･`*` とも `truncate` 対象外 (ブランチ名が切れても残す。変更行数と同じ扱い) |

### rate (レートリミット) 表示

`format_rate` の最も間違えやすい箇所。**ハイフン区切り･括弧禁止**。

| 残量 | reset > 0 | reset == 0 |
| --- | --- | --- |
| > 40% (色なし) | `chart HH:MM` (数値なし) | `chart` のみ |
| ≤ 40% (色あり) | `chart NN% - HH:MM` (★ ハイフン) | `chart NN%` |

- 数値 `NN%` は **色がつくときだけ表示**する
- 区切りは半角スペース･ハイフン･半角スペース (` - `)、括弧 `()` 禁止
- チャートの**右端 1 文字は履歴サンプリング間隔 (`POLL_INTERVAL_SEC`) と独立に常に現在値の spark** を描く。左 `HISTORY_LEN-1` 文字が履歴の遷移を表す。main で `rate_chart` 右端を `spark_single "$rate_remaining"` に差し替えて実装する。リセット直後でも右端が即座に最新残量を反映する (タイムラグ解消)。`${rate_chart:0:N}` は `LC_ALL=C.UTF-8` 固定下の文字数換算に依存する
- 右端=現在値は **`HISTORY_DIR` の状態と独立**に保つ。`rate_chart` の初期値を `history_chart /dev/null` (履歴なしパディング `······`) にして**常に非空の土台**を置き、`HISTORY_DIR` 有効時のみ実履歴で上書きする。`/tmp` 安全性チェックで `HISTORY_DIR` が無効化されても右端 1 文字は現在値を描く
- 右端差し替えの分岐は `rate_remaining` の有無だけで判定する (`rate_chart` は上記の土台により必ず非空なので条件に含めない)

### ctx (コンテキスト使用率) 表示

履歴は持たず、現在値の 1 文字 spark のみ描画する (UmicodeKa/agent-skills#172)。

| 使用率 | 表示 |
| --- | --- |
| ≥ 70% (色あり) | `spark NN%` (spark は ▁..█ の 1 文字) |
| < 70% (色なし) | `spark` のみ (数値なし) |

### 色閾値

色は Claude Code 公式テーマ (`getTheme`) のセマンティック色を `COLOR_*` 定数経由で参照する (冒頭の｢カラースキーム｣ブロック)。`COLOR_SCHEME` (既定 `dark`、env `CLAUDE_STATUSLINE_COLOR_SCHEME=light` で上書き) で light/dark を切替える。

下表の RGB は dark の値。各セマンティック名 (success/error/warning/claude/permission/autoAccept) は公式キーをそのまま維持し、未使用キーも将来用に保持する。

下表に出ない次のキーも公式テーマからハードコピーしてある (現状は未使用): `planMode` / `effortUltra` / `rate_limit_fill` / `rate_limit_empty` / shimmer 系 / `professionalBlue` / `chromeYellow` / `subtle` / `inactive` / `merged` / `fastMode` / `COLOR_subagent_*` (subagent_cyan を除く)。

`COLOR_subagent_*` は公式 `<color>_FOR_SUBAGENTS_ONLY` の短縮名。

| 指標 | 条件 | 色 (dark の ANSI) |
| --- | --- | --- |
| ctx | ≥ 90% | `error` + 点滅 `\033[5m\033[38;2;255;107;128m` |
| | ≥ 80% | `claude` `\033[38;2;215;119;87m` (橙) |
| | ≥ 70% | `warning` `\033[38;2;255;193;7m` (黄) |
| | < 70% | (色なし) |
| rate 残量 | ≤ 5% | `error` + 点滅 `\033[5m\033[38;2;255;107;128m` |
| | ≤ 15% | `claude` `\033[38;2;215;119;87m` (橙) |
| | ≤ 40% | `warning` `\033[38;2;255;193;7m` (黄) |
| | > 40% | (色なし) |
| model `✻ <model>` | `*Fable*` | `autoAccept` `\033[38;2;175;135;255m` (紫) |
| | `*Opus*` | `claude` `\033[38;2;215;119;87m` (ブランドのオレンジ) |
| | `*Haiku*` | `subagent_cyan` `\033[38;2;8;145;178m` (シアン) |
| | その他 (Sonnet 等) | (色なし) |
| effort `.effort.level` | `low` | `warning` `\033[38;2;255;193;7m` (黄) |
| | `medium` | `success` `\033[38;2;78;186;101m` (緑) |
| | `high` | `permission` `\033[38;2;177;185;249m` (青) |
| | `xhigh` | `autoAccept` `\033[38;2;175;135;255m` (紫。ultracode も入力上 xhigh と同一でこの色) |
| | `max` | rainbow (`RAINBOW_PALETTE` で 1 文字ずつ着色) |
| | 欠落 (effort 非対応) | 非表示 (effort 部とその前のスペースを出さない) |
| ahead `↑N` | ローカル先行 (push 待ち) | `professionalBlue` `\033[38;2;106;155;204m` (青。**`success` 緑は変更行数 `+add` と混ざるため使わない**) |
| behind `↓M` | リモート先行 (pull 待ち) | `warning` `\033[38;2;255;193;7m` (黄。隣接要素に黄がなく被らない) |
| `*` (upstream 未設定) | branch は取れるが `@{upstream}` 無し (rev-list 失敗) | `professionalBlue` `\033[38;2;106;155;204m` (青。ahead と同色 = ローカル先行の一種) |
| `*` (detached HEAD) | `branch --show-current` 空･rev-parse 代替 (rev-list 失敗) | 無色 (前景色 `text`。dark 白 `255;255;255` / light 黒 `0;0;0`) |

rate/ctx は公式パレットの warning/error 2 段しかないため、中間段に `claude` (橙) を混色して警戒→危険→致命の 3 階調を維持する。**致命段の点滅は色ではなく属性** (`\033[5m`) なので、公式色 `error` に重ねて残す。

`*Fable*` は `*Opus*` より前に置く (バージョン非依存の部分一致)。色判定はトリム前の全長で行い、色を塗る対象はトリム後の `✻ <トリム後 model 名>`。effort は model とは別 paint で塗り、トリムしない。

### 履歴サンプリング定数

| 定数 | 値 | 推奨レンジ | 用途 |
| --- | --- | --- | --- |
| `HISTORY_LEN` | 6 | — | スパークライン文字数 (**rate 専用**、ctx は履歴を持たない) |
| `POLL_INTERVAL_SEC` | 480 | 60〜3000 | サンプリング最小間隔 (秒) |
| `LOCK_TIMEOUT_SEC` | 2 | — | ロック待機上限 (秒) |
| `GIT_FETCH_INTERVAL_SEC` | 900 | 60〜1800 | バックグラウンド `git fetch` の最小間隔 (秒)。`maybe_git_fetch` が前回 fetch から未満なら fetch を投げない (`GIT_FETCH=1` 時のみ有効)。間引きは **cwd 単位** (マーカーのキーが `cwd` の `cksum`。repo ルート単位ではないので、同一 repo の別サブディレクトリ/worktree は別枠で数える) |

これらの数値を変更する PR は**別 Issue で目的を定義**してから提案する。

#### 推奨レンジの根拠と clamp

`POLL_INTERVAL_SEC` / `GIT_FETCH_INTERVAL_SEC` は env 上書き口を持たず、conf (`~/.claude/statusline.conf`) で変える運用。**範囲外の値はスクリプト冒頭の clamp ブロックが最寄りの境界へ丸める** (`0` / 負値 / 非数値 / 空は既定値へ戻る)。丸めは無警告で、描画はそのまま継続する (`HISTORY_DIR` の安全性チェックと同じ｢無効値ならフォールバックして表示は続ける｣方針)。

| 定数 | 下限の根拠 | 上限の根拠 |
| --- | --- | --- |
| `GIT_FETCH_INTERVAL_SEC` (60〜1800) | statusline は数秒〜十数秒間隔で呼ばれ得るため、60 未満では間引きが実質機能せず `git fetch` 子プロセスが頻発する (ネットワーク I/O･認証プロセス起動の連発)。間引きは cwd 単位なので、同一 repo を複数 worktree で開くほど実質の fetch 総数は線形に増える | 30 分を超えると `↓behind` 自動最新化のメリットが薄れ、手動 fetch と大差なくなる |
| `POLL_INTERVAL_SEC` (60〜3000) | 同上 (statusline の呼び出し頻度に近づくと間引きの意味が失われ、rate 履歴が毎回更新される) | rate limit は 5 時間 (18000 秒) ウィンドウで `HISTORY_LEN=6` サンプルなので、18000/6=3000 を超えるとウィンドウ全体をカバーしきれずチャートが｢傾向｣として意味を失う |

clamp が無いと、秒数比較 (`[ $((now - mtime)) -lt "$INTERVAL" ]`) は算術式なので `0` / 負値でも構文エラーにならず、間引きが**静かに無効化される**。

### 表示定数

下表の定数はいずれも conf (`~/.claude/statusline.conf`) に短縮名で書いて上書きできる。env が指定されていれば env が勝つ (下記｢削除厳禁の防御コード｣の設定ファイル行を参照)。

| 定数 | 既定 | 用途 |
| --- | --- | --- |
| `SHOW_MODEL_NAME` | `1` | モデル名表示の ON/OFF。`1` = 表示 (`✻ <model>∙<effort>`、`∙` で区切る･前後スペースなし)、`0` = 非表示 (`✻ <effort>`、`∙` なし)。`0` でも `✻` は `model_color` で塗る (記号の色でモデルを判別)。env `CLAUDE_STATUSLINE_SHOW_MODEL_NAME` で上書き可 (テスト･開発者向け) |
| `COLOR_SCHEME` | `dark` | カラースキーム。`dark` / `light` で公式テーマ 2 セットの `COLOR_*` を切替える。env `CLAUDE_STATUSLINE_COLOR_SCHEME` で上書き可 (テスト･開発者向け)。`COLOR_*` は公式テーマ (`getTheme`) のハードコピーで、未使用キーも将来用に保持する |
| `SHOW_CWD` | `1` | 1 行目の directory 列の ON/OFF。`1` = 表示、`0` = 非表示。**`0` で消えるのは directory 列のみで、2 行構成そのものは維持する** (branch 列と session_name は 1 行目に残る)。env `CLAUDE_STATUSLINE_SHOW_CWD` で上書き可 (テスト･開発者向け)。1 行構成へ戻す設定は設けない |
| `LAYOUT_LINE1` | `directory\|branch\|session` | 1 行目のトークン列。書かなかったトークン･値が空のトークン･未知のトークンは列ごと省略。既知トークンが 1 つも無ければ 1 行目ごと出さない (空文字は既定値扱いなので、消すときは `none` 等を書く)。env `CLAUDE_STATUSLINE_LAYOUT_LINE1` で上書き可 |
| `LAYOUT_LINE2` | `model_ctx\|rate` | 2 行目のトークン列。順番だけを変えられ、書かなかったトークンは末尾に補う。env `CLAUDE_STATUSLINE_LAYOUT_LINE2` で上書き可 |
| `GIT_FETCH` | `0` | バックグラウンド `git fetch` のオプトイン。`0` = 無効 (従来動作を完全維持、fetch を一切投げない)、`1` = 有効 (`maybe_git_fetch` が描画経路とは別のバックグラウンド子プロセスで投げっぱなし fetch を行い `↓behind` を自動最新化)。env `CLAUDE_STATUSLINE_GIT_FETCH` で上書き可 (テスト･開発者向け)。`0` (既定) では `maybe_git_fetch` が入口で即 return するため既存出力は完全に不変。`1` のとき描画ごとに `cksum`/`date`/`stat` の 3 fork が増える (間引きで弾かれる通常経路の場合) |

### 削除厳禁の防御コード

| 箇所 | 内容 |
| --- | --- |
| Debian 版冒頭 | `BASH_VERSINFO` による bash 4.1+ ゲート (`exec {fd}>...` を使うため必須) |
| `/tmp` 権限チェック | symlink 判定 / 所有 uid / mode 700 確認 (権限昇格対策) |
| `printf '%s'` の徹底 | `echo` 禁止 (`-n` / `-e` で値が壊れる) |
| 色付けの 3 段構成 (`paint` → `static` / `rainbow`) | 全色付け経路 (model/rate/ctx/diff) が `paint <text> <effect> [arg]` を経由する。色決定関数 (`model_color`/`rate_color`/`ctx_color`) は `"static <ansi>"` / `"static"` / `"rainbow"` の effect 指定を返し、クォートなし展開で paint に渡す。`static` は旧 `colorize` (単色で囲む、無色時は末尾改行付きで素通し) の中身そのもの。エフェクト追加は `paint` に 1 ブランチ足すだけ。経路を `static` 直呼びに戻したり paint を迂回しない |
| `rainbow` の固定パレットと UTF-8 安全実装 | 色付け基盤として `RAINBOW_PALETTE` / `rainbow` / `paint` の rainbow 分岐を残す。**effort=max で `effort_color` が `rainbow` を返すため live 経路から呼ばれる** (以前の｢未使用基盤｣から live 利用へ昇格)。色は `RAINBOW_PALETTE` (7 色の truecolor `"R;G;B"`) を `i` 番目の文字に `palette[i % len]` で循環割り当て (補間なし)。`${#text}` / `${text:i:1}` は `LC_ALL=C.UTF-8` 固定下の文字数換算に依存 (`✻` は 3 バイト)。char 本体は外部プロセスに渡さず bash 内で完結させる (マルチバイト破壊回避) |
| `effort_color` と effort の別 paint 連結 | `effort_color` は effort level に応じた effect 指定 (`static <ansi>` / `rainbow` / `static`) を返す。`effort_field=$(paint "$effort" $effort_effect)` で effort 語句のみ塗り (ON/OFF 共通)、`✻ <model>` とは**別の `paint` 呼び出し**にして色を混ぜない。`SHOW_MODEL_NAME=1` のとき `model_field="${model_field}∙${effort_field}"` と `∙` (**無色リテラル、`paint` を通さない、前後スペースなし**) で区切り連結、`0` のとき `model_field="${model_field} ${effort_field}"` とスペース連結する。`[ -n "$effort" ]` ガードで欠落時は `∙`･effort を一切出さない (既存ケースの出力不変条件)。effort はトリムしない。`∙` を `paint`/effort 色シーケンスに含めたり (`max` で `∙` を rainbow 循環に入れたり)、この `SHOW_MODEL_NAME` 分岐を消さない |
| `✻` の常時表示と `SHOW_MODEL_NAME` 分岐 | `SHOW_MODEL_NAME=0` でも `✻` 単体を `model_color` で塗って必ず残す (記号の色でモデルを判別する)。`✻` 自体を消したり無色化しない |
| カラースキーム定数ブロック (`COLOR_SCHEME` + `_fg` + `case` の `COLOR_*` 定義) | 公式テーマのハードコピー。`_fg` は定義時に R;G;B を `\033[38;2;R;G;Bm` に展開するヘルパで、`COLOR_*` は実 ESC 化済み文字列。各 `*_color` 関数･diff はここを参照する。値を直書きに戻したり、両スクリプトで定義をドリフトさせない (回帰テストは Debian 版を bash 4.1+ / `flock` 不在時にスキップするため、両ファイルの色定義ブロックは diff で一致を確認する) |
| rate/ctx 致命段の点滅属性 (`printf 'static \033[5m%s' "$COLOR_error"`) | 点滅は色ではなく属性。公式パレットは warning/error の 2 段しかないので、危険段に `claude` を混色して 3 階調にしたうえで、致命段は `error` + `\033[5m` で危険段と区別する。点滅を外して `error` 単色に統一しない (致命と危険が同色になる) |
| `format_rate` のハイフン区切り | `chart NN% - HH:MM` (UmicodeKa/agent-skills#156 事故箇所) |
| branch 取得の `[ -n "$cwd" ]` ガード | 空のまま `git -C ""` を呼ぶと CWD 扱いで意図せぬブランチが漏れる |
| `git_ahead_behind` の rev-list 失敗分岐と `is_detached` 引数 | ahead/behind 取得は `git rev-list --left-right --count '@{upstream}...HEAD'` のみで**ローカル完結**。**`git_ahead_behind` 自体に同期 `git fetch` を足さない** (描画経路にネットワーク I/O = 数秒ブロックを持ち込む)。バックグラウンド fetch は `maybe_git_fetch` に分離済みで描画経路 (`git_ahead_behind`) は一切触らない。rev-list が非ゼロ終了したら第2引数 `is_detached` (main 側で検出済み。関数内で git を再呼び出ししない) で分岐し `*` を返す: detached=無色 (前景色) / それ以外 (upstream 未設定･区別不能なリポジトリ内異常系) =青 (`professionalBlue`)。無色 `*` は `static` 素通しが末尾改行を付けるため `out=$(paint ...)` で改行を潰してから出す。**同期済み (ahead=behind=0) のみ空を返しフィールド省略** (`*` を出さない)。git 外は branch 空で本関数が呼ばれず branch 列ごと省略。ahead=`professionalBlue` / behind=`warning` を**別 paint** で塗り、`↑N↓M` を区切りなしで詰める。ahead に緑を使わない (変更行数 `+add` の緑と混ざる)。`↑N↓M`･`*` は変更行数の左に挿入し `truncate` 対象外 |
| `maybe_git_fetch` の fetch 分離と fd リダイレクト | `GIT_FETCH=1` のバックグラウンド fetch は描画経路から完全に分離する。fetch は `( ... & )` の投げっぱなし子プロセスで起動し、`>/dev/null 2>&1 </dev/null` の 3 点セットで stdout/stderr/stdin を付け替える (**削除厳禁**: これを外すと親の command substitution が子の EOF = fetch 完了を待って数秒〜数分ブロックする)。間引きマーカー (`cksum` で **cwd 別**、`HISTORY_DIR` 配下) + ロックで多重 fetch を防ぐ。`GIT_FETCH` 既定 `0` の入口 return を消さない (既存出力不変の保証)。回帰ガードは `tests/git-fetch-behavior.sh` (非ブロッキング･間引き･ロック解放) と `fetch_marker` アサーション (投げる/投げないの分岐) |
| `maybe_git_fetch` の認証プロンプト封じ 4 変数 | `GIT_TERMINAL_PROMPT=0` + `GIT_ASKPASS=/bin/true` + `SSH_ASKPASS=/bin/true` + **`SSH_ASKPASS_REQUIRE=force`** (**4 つで 1 セット、削除厳禁**)。fd 0/1/2 を `/dev/null` に付け替えても**制御端末 (`/dev/tty`) は子プロセスに残る**。OpenSSH は端末があるとき `SSH_ASKPASS` を無視して `/dev/tty` を直接開くため、`SSH_ASKPASS_REQUIRE=force` (= 端末の有無によらず askpass を使う) が無いと、SSH リモートのパスフレーズ/ホスト鍵プロンプトが **Claude Code の TUI に漏れてキー入力を奪う** (pty 実測で確認済み)。`GIT_TERMINAL_PROMPT=0` が封じるのは git 自身の HTTPS プロンプトだけで ssh には効かない。askpass に `/bin/true` (空を返す) を指すことで、資格情報の無い remote では端末に触れず即座に諦める。**副作用は意図的**: ssh-agent に鍵が無い環境では fetch が静かに失敗し `↓behind` が更新されない (TUI 保護を優先)。`GIT_SSH_COMMAND` での `BatchMode=yes` 指定は使わない (ユーザーの `core.sshCommand` を上書きし、独自 ssh 設定を静かに壊すため) |
| `maybe_git_fetch` のマーカー書き込み失敗ガード | 間引きマーカーを書けなかったら**ロックを解放して return し、fetch を spawn しない** (**削除厳禁**)。書けないまま spawn すると間引きの基点が残らず、次の描画も同じ経路に入るため**描画のたびに fetch が多重起動する** (statusline は数秒ごとに呼ばれるので実質の連続 fetch)。到達経路は｢マーカーが古い mtime かつ書き込み不可で残っている｣｢マーカーと同名の dir がある｣等 (mtime 判定は通過し、ロックも `HISTORY_DIR` 自体は書けるので取れてしまう)。マーカー更新に `:` を使わない: `:` は POSIX の special built-in で、sh 互換モードではリダイレクト失敗時に**シェルごと終了**する (非 special の `true` を使う)。エラーメッセージの抑制は `{ true > "$marker"; } 2>/dev/null` と**ブロックごと囲む**: リダイレクトは左から右に処理されるため、後置の `true > "$marker" 2>/dev/null` では fd 2 の差し替え前に失敗し `Permission denied` が端末へ漏れる。回帰ガードは `tests/git-fetch-behavior.sh` の `marker-unwritable` (マーカーと同名 dir で書き込み失敗を再現。`chmod 400` は root で走る CI だと書けてしまうため使わない) |
| `maybe_git_fetch` の `marker → unlock → spawn` 順序 | ロックはマーカーを書いた時点で役目を終える (以降 他プロセスは mtime 判定で弾かれる)。**fetch を投げる前にロックを解放する**。順序を入れ替えて `spawn → unlock` にすると、Debian 版では named fd が close-on-exec されず `( ... & )` の子に複製が渡るため、**fetch 完走まで flock が居座る**。先に閉じれば子は fd をそもそも受け取らない (子側 `{fd}>&-` は不要)。両版で同一順序を保ち、実装差分をロック機構 (flock / mkdir) だけに閉じる |
| 間引き定数の clamp ブロック (`POLL_INTERVAL_MIN/MAX_SEC` / `GIT_FETCH_INTERVAL_MIN/MAX_SEC` と直後の `case` + `[ -lt ]` / `[ -gt ]` 代入) | `POLL_INTERVAL_SEC` / `GIT_FETCH_INTERVAL_SEC` を推奨レンジ (60〜3000 / 60〜1800) へ丸め、非数値･空･負値は既定値 (480 / 900) へ戻し、9 桁以上は上限へ直接丸める (整数範囲を超える桁数だと `[ -lt ]` がエラー終了 (status 2) して丸めが素通りし、間引きが無効化されるため。回帰ガードは `85-config-huge-interval`)。この 2 定数は env 上書き口を持たず**ユーザーが conf で自由に書き換える**運用なので、不正値がそのまま実行時に効いてしまう。秒数比較は算術式のため `0` / 負値でも構文エラーにならず、消すと**間引きが静かに無効化され描画のたびに `git fetch` が多重起動する** (statusline は数秒ごとに呼ばれるので実質の連続 fetch)。`POLL_INTERVAL_SEC` 側は rate 履歴が毎回更新され `HISTORY_LEN=6` のチャートが傾向を示さなくなる。既定値はレンジ内なので clamp は素通しし、**既存の描画出力は完全に不変**。丸めは無警告 (エラーを出さず描画を継続する `HISTORY_DIR` チェックと同じ方針)。fork を増やさないため command substitution を使わず変数へ直接代入する。両スクリプトで**完全に同一の実装**を保つ (OS 依存要素なし)。回帰ガードは `tests/git-fetch-behavior.sh` の `clamp-zero-interval` (conf に `GIT_FETCH_INTERVAL_SEC=0` を書いて 2 回描画し fetch が 1 回に間引かれることを検証) |
| 設定ファイル (`~/.claude/statusline.conf`) の読み込みブロック | 冒頭の｢ユーザー設定ファイルの読み込み｣ブロック (UmicodeKa/agent-skills#257)。**読み込み位置は｢カスタマイズ設定セクションの直前｣= 内部定数･clamp ブロックより前**で固定する。clamp より後に置くと conf の不正値が丸められず間引きが無効化される。内部定数 (`HISTORY_LEN` 等) より後に置くと conf で出力フォーマットを変えられてしまう (`HISTORY_LEN` は conf の対象外)。優先順位は **env (`CLAUDE_STATUSLINE_*`) > conf > 既定値** で、conf は**短縮名** (`SHOW_MODEL_NAME` 等) を単純代入で書く。各設定は `${CLAUDE_STATUSLINE_X:-${X:-既定値}}`、env 口の無い間引き定数は `${X:-既定値}` で読む (無条件代入 `X=480` に戻すと conf の値が黙って上書きされる)。source 前の `unset` (短縮名 8 つ) は外の環境から同名変数が紛れ込むのを防ぐため消さない。判定は `[ -f ] && [ -r ]` (ディレクトリを `.` するとエラーが出るため `-r` 単独にしない)、読めなければ黙って無視する。`/` を含まないパスは `./` を前置する (`.` は `/` の無い引数を `$PATH` から探索し、`[ -f ]` で確認したのと別のファイルを読みうるため)。source 直後に 8 変数の末尾 `\r` を剥がす (CRLF 保存の conf で値が黙って既定値扱いになるのを防ぐ)。パーミッション/所有者チェックはしない (`~/.claude/` はユーザー自身の領域)。JSON/YAML 化しない (描画のたびに `jq` 等の fork が増える)。`CLAUDE_STATUSLINE_CONFIG` で読み込み先を差し替えられ、`tests/regression.sh` / `git-fetch-behavior.sh` / `e2e-preview.sh` は**全ケース共通の前置きで存在しないパスへ固定**する (開発者の実 conf が漏れ込むと環境依存で落ちる/通るテストになる)。conf を使うケースは `tests/config-file/<case>` に中身を置き、解決は `tests/lib/config-file.sh` の `config_for_case` に集約する。回帰ハーネスは短縮名 8 つを全ケースで既定値と異なる値で渡す (`unset` を消すと全ケースが落ちる回帰ガード)。配布テンプレート `statusline.conf` は全項目を既定値で埋め、`86-config-template` / `95-config-template-layout` (symlink) で既定値と一致することを検証する (レイアウトは `\|` を含むため値をクォートで囲む)。回帰ハーネスはマーカーの無い env (`SHOW_MODEL_NAME` 等) を**空文字**で渡す (既定値を直接渡すと conf が常に env に負けて検証できない) |
| 1 行目の組み立て (`line1_parts` 配列と `${#line1_parts[@]} -gt 0` ガード) | 1 行目は 2 行目の `parts` とは**別の配列**で組み立て、要素が 1 つ以上あるときだけ `printf '%s\n'` で `join_by` の結果 + 改行を出す。`LAYOUT_LINE1` は `build_layout` 第 3 引数 `0` で値が空のトークンを積まない。`directory` も `branch` も `session_name` も空のときに**改行だけを出してはいけない** (空行が statusline の高さを 1 行占有する)。**改行を 2 行目側の先頭 (`printf '\n%s'`) へ移さない** (1 行目が省略されたときに先頭へ空行が出る)。`join_by` を無条件に 2 回呼ぶ形へも変えない |
| レイアウトのトークン設計 (`layout_token` / `build_layout`) | UmicodeKa/agent-skills#258。トークン間の区切りは**常に ` \| `** で、特殊区切りで結ばれた要素群は**1 トークンに束ねる**: `model_ctx` = `✻ <model>∙<effort> <ctx_str>` (`∙`･スペース 1 個を内包)、`branch` = `<branch>${ab_str:+ $ab_str}${diff_str:+ $diff_str}` (`:+` の条件付き連結を内包。単純なスペース連結にすると ab/diff が空のとき末尾に余分なスペースが残る)。`model` と `ctx` を別トークンに分解しない (トークン間の区切りが組み合わせで変わり実装もテストも破綻する)。**空なら省略は 1 行目だけ** (`build_layout` 第 3 引数 `0`) に適用し、2 行目は値が空でも無条件に積む (2 行目は常に出力する。`format_rate` が常に非空を返すため既存ケースでは差が表面化せず、テストを通ったまま不変条件だけが壊れる)。2 行目は走査対象の末尾に既定の全トークン (`\|model_ctx\|rate\|`) を足し、書かれなかったトークンを補う (`✻` を消せないようにする)。未知トークンは黙って無視し、重複は最初の 1 回だけ採る。トークン → 値は連想配列ではなく `case` で引き、値は呼び出し側で `$(...)` を挟まず変数 `token_value` で返す (bash 3.2 互換。branch/session のトリムは従来どおり `truncate_label` の command substitution を伴う)。1 行目･2 行目とも同じ `build_layout` で組み立て、走査ロジックを複製しない。分割･前後の空白 (タブ含む) の除去はパラメータ展開のみで `tr` / `awk` を使わない。`SHOW_CWD=0` は `directory` トークンが空を返すことで｢レイアウトから外す｣と等価にする (フラグとレイアウトの二重判定を作らない)。回帰ガードは `87`〜`96` の layout / config ケース (`tests/layout/<case>` に 1 行目 = `LAYOUT_LINE1`、2 行目 = `LAYOUT_LINE2` を置き、`tests/lib/layout.sh` の `layout_for_case` で解決する) |
| 行指定アサーション種別 (`matches_line1` / `matches_line2` / `no_line2` / `not_contains_line1`) | `check_assertions` の `matches` は `[[ "$output" =~ $expected ]]` で**出力全体を 1 つの文字列**として評価するため、2 行出力では `^…$` の両端アンカーが成立しない (`.` は `\n` にもマッチする)。行ごとに両端アンカーを効かせるため `matches_line1` / `matches_line2` を使う。**`matches_line2` を書かないことは｢2 行目が無い｣の検証にならない**ので、2 行目を出さないケースには `no_line2` を必ず付ける。`no_line2` は｢出力が 1 行だけ｣の検証なので、**1 行目 (directory/branch/session) が省略されるケース**で使う (このとき唯一残る行 = モデル行を `matches_line1` で検証する)。`not_contains_line2` は｢モデル行に出ないこと｣の検証で、directory 列 (色付き･ハイフンを含みうる) を誤検知しないために必要。これらを `matches` / `not_contains` に戻さない |
| 両スクリプト冒頭の `export LC_ALL=C.UTF-8` | UTF-8 表示 + トリムの文字数換算に必須。削除/変更すると `${#var}` がバイト数換算に戻り両スクリプトの出力がドリフトする |
| rate チャート右端の現在値差し替え (`rate_chart="${rate_chart:0:$((HISTORY_LEN - 1))}$(spark_single "$rate_remaining")"`) | リセット時のタイムラグ解消のための即時反映。堅牢化/整理名目で消すと右端も履歴サンプリング間引きの古い値に戻る |
| rate チャートの土台底上げ (`rate_chart=$(history_chart /dev/null)` を `HISTORY_DIR` 分岐の**前**に置く) | 右端=現在値を `HISTORY_DIR` の状態と独立に保証する。消すと `HISTORY_DIR` 無効時 (`/tmp` 安全性チェック失敗) に `rate_chart` が空になり右端が描かれず｢常に現在値｣を満たさなくなる |

## 編集前必須チェックリスト

1. **本書を読む** (本ファイル全文)
2. `README.md` の表示例 (1 行目 `agent-skills | main | my-session` / 2 行目 `✻ Opus 4.7∙high ▄ | ... 35% - 18:30` 等) を再確認
3. `git log --oneline` で直近の意図変更履歴を確認。このリポジトリへ移管する前の履歴は `UmicodeKa/agent-skills` の `statusline/` にある (特に UmicodeKa/agent-skills#156)
4. `npm test` を**編集前に**走らせて green を確認 (= ベースラインの確立)

## 編集ルール

### 変更の種類と要件不変

変更は大きく 2 種類に分かれる。どちらも出力 (要件) を変えてはならない点は同じ。

| 種類 | 例 |
| --- | --- |
| 目的仕様の変更 | フォーマットの修正、色閾値の調整、新フィールド追加 |
| 堅牢化 (品質向上) | `echo` を `printf` に統一、サニタイズ強化 |

**守るべきは『出力 (要件) が変わらないこと』であって、スコープの広狭そのものではない。** スコープを絞るのは事故を避ける手段の一つに過ぎない。判断基準は ｢スコープが広いか｣ ではなく ｢既存ケースが 1 つでも落ちないか｣ に置く。

リファクタが全経路に及んでも、`npm test` で既存ケースが不変のまま pass すれば要件不変は機械的に保証されるので、目的仕様の追加とリファクタを同一 PR で行ってよい。逆に、スコープが狭くても要件が変わる変更は単独で検証する。

### 両スクリプト同時編集の原則

`statusline-macos-zsh.sh` と `statusline-debian-bash.sh` は**仕様共通･実装差分のみ**。片方だけ変更したらほぼ確実にドリフトする。共通仕様に関わる変更は両方を同時に修正する。

## 編集後の必須検証

1. `npm test` が green
2. `npm run preview` を端末で実行し、**ANSI 色を含む実出力**を肉眼で確認
3. 両プラットフォームの両スクリプトに変更が入っているか再確認 (片方だけ忘れていないか)
4. PR 説明に｢触ってはいけない仕様｣のどの行に該当する変更かを明記
