# CLAUDE.md

このファイルは、このリポジトリで作業するコーディングエージェント向けの案内です。

## このリポジトリについて

Claude Code の statusline を描画するシェルスクリプトです。macOS 版 (`statusline-macos.sh`) と Linux 版 (`statusline-linux.sh`) は仕様を共有し、実装はプラットフォーム依存の部分 (ロック機構、`stat` の書式など) だけが異なります。両者は同じ入力に対して同一の出力を返すことが要件です。片方だけを編集すると出力が食い違いやすいため、これは人間とエージェントのどちらが編集する場合にも当てはまります。

| ドキュメント | 内容 |
| --- | --- |
| [docs/SPEC.md](docs/SPEC.md) | 出力仕様 (構造、各フィールド、色の閾値、設定項目) |
| [docs/DESIGN.md](docs/DESIGN.md) | 設計判断、変更時の注意点、採用しなかった案 |
| [tests/README.md](tests/README.md) | テストハーネスの構成と規約 |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | 開発環境と変更の手順 |

## 変更の進め方

1. 編集前に `npm test` を実行し、green であることを確認する (ベースライン)。
2. 共通仕様に関わる変更は macOS 版と Linux 版の両方に入れる。
3. 出力が変わる変更では、[docs/SPEC.md](docs/SPEC.md) と `tests/assertions/` の期待値を同じ変更で更新する。
4. 出力を変えないリファクタでは、既存のアサーションを書き換えない。既存ケースがそのまま pass することで出力不変を確認する。
5. 仕上げに `npm test`、`npm run check`、`npm run preview` (ANSI 色を含む実出力の目視確認) を実行する。
6. PR の説明には、影響する SPEC のセクションと、出力が変わるかどうかを書く。

CI は Linux 版のみを実行します。macOS 版の変更はローカルの `npm test` で確認してください。回帰テストは実行できる側のスクリプトだけを検証するため、両版のドリフトは `npm test` に含まれる `tests/script-parity.sh` (OS 非依存、CI でも実行) で検出します。

## 変更時に特に注意が要る箇所

背景と守っているテストは [docs/DESIGN.md](docs/DESIGN.md) にまとめています。

- `maybe_git_fetch` の `>/dev/null 2>&1 </dev/null`: 外すと描画の command substitution がバックグラウンド fetch の完了を待ち、描画が数秒以上ブロックする。([詳細](docs/DESIGN.md#fetch-子プロセスの-fd-付け替え))
- `maybe_git_fetch` の 4 変数 (`GIT_TERMINAL_PROMPT=0` / `GIT_ASKPASS=/bin/true` / `SSH_ASKPASS=/bin/true` / `SSH_ASKPASS_REQUIRE=force`): 1 つでも外すと、SSH のパスフレーズやホスト鍵の確認が Claude Code の TUI に表示されてキー入力を奪う。([詳細](docs/DESIGN.md#認証プロンプトを抑える-4-つの環境変数))
- `maybe_git_fetch` の｢マーカー書き込み → ロック解放 → fetch 起動｣の順序: 入れ替えると Linux 版では fetch の子プロセスにロックの fd が引き継がれ、fetch 完了までロックが残る。([詳細](docs/DESIGN.md#marker--unlock--spawn-の順序))
- マーカー書き込み失敗時に fetch を起動しないガード: 外すと間引きの基点が残らず、描画のたびに fetch が起動する。([詳細](docs/DESIGN.md#マーカー書き込み失敗時に-fetch-しない))
- `pr` トークンの取得 (`maybe_pr_refresh` / `pr_spawn_refresh`) も `maybe_git_fetch` と同じ約束事 (fd の付け替え、git 用の 4 変数、marker → unlock → spawn、マーカー書き込み失敗時に起動しない) を守る。加えて gh 用の 3 変数と `unset GH_REPO GH_FORCE_TTY CLICOLOR_FORCE` を外さない。([詳細](docs/DESIGN.md#pr-子プロセスの-fd-付け替えと環境変数))
- `pr` の `.inflight` の後始末を EXIT の `trap` に移さない。bash 3.2 では `&` で起動したサブシェルの EXIT trap が走らず、印が残って 90 秒間取得が止まる。([詳細](docs/DESIGN.md#pr-の-inflight-の後始末を-trap-にしない))
- 描画経路 (`git_ahead_behind` など) に同期 `git fetch` や追加の `git` / `gh` 呼び出しを足すと、ネットワーク I/O や fork が増えて描画が遅くなる。([詳細](docs/DESIGN.md#描画経路にネットワーク-io-と余分な-git-呼び出しを入れない))
- 2 行目のトークンは値が空でも積む (`build_layout` の第 3 引数 `1`)。空なら省く扱いにすると｢2 行目は常に出力する｣が崩れるが、既存ケースでは表面化しない。([詳細](docs/DESIGN.md#2-行目のトークンは空でも積む))
- 設定ファイルの読み込み位置は、内部定数と clamp ブロックより前。後ろに移すと conf の不正値が丸められず、内部定数も conf で書き換えられるようになる。([詳細](docs/DESIGN.md#設定ファイルの読み込みブロック))
- `HISTORY_DIR` の安全性チェック (symlink、所有 uid、mode 700): 外すと `/tmp` 上で他ユーザーが用意したディレクトリやリンクに書き込みうる。([詳細](docs/DESIGN.md#履歴ディレクトリの安全性チェック))
- 色定義ブロック (`_fg` と `case "$COLOR_SCHEME"`) は両スクリプトで同一に保つ。`npm test` は実行できる側のスクリプトだけを検証するため、ドリフトは `tests/script-parity.sh` で検出する。([詳細](docs/DESIGN.md#色定義ブロックの両版一致))
- 冒頭の `export LC_ALL=C.UTF-8`: 外すと `${#var}` がバイト数換算になり、トリム位置が変わる。([詳細](docs/DESIGN.md#ロケール固定))
- 値の出力は `printf '%s'` を使い、`echo` は使わない。`echo` は値が `-n` や `-e` のとき出力が変わる。([詳細](docs/DESIGN.md#printf-s-の統一))
- Linux 版冒頭の bash 4.1+ チェック: named fd (`exec {fd}>...`) を使うため、外すと古い bash でパースエラーになる。([詳細](docs/DESIGN.md#linux-版の-bash-41-ゲート))
- rate 表示の区切りはハイフン (`chart NN% - HH:MM`) で、括弧は使わない。([詳細](docs/DESIGN.md#rate-のハイフン区切り))

## 公開リポジトリとしての注意

- 秘密情報やトークンをコミットしない。
- `/Users/<名前>/...` のような個人環境のパスを書かない。
- 非公開のリポジトリ、Issue、セッションへの参照を書かない。
- Claude Code 内部の関数名を書かない。配色の出典は｢Claude Code の light/dark テーマに合わせた配色｣と書く。
- 例には `my-project` や `my-session` のような架空の名前を使う。
- ドキュメントやコメントには、経緯よりも｢何が起きるか、なぜか｣を書く。

## コマンド

| コマンド | 内容 |
| --- | --- |
| `npm test` | 回帰テスト (`tests/regression.sh`) 、fetch 挙動テスト (`tests/git-fetch-behavior.sh`)、PR 取得の挙動テスト (`tests/pr-status-behavior.sh`)、両版の静的一致チェック (`tests/script-parity.sh`) |
| `npm run preview` | ANSI 色付きの実出力を端末に表示する (`tests/e2e-preview.sh`) |
| `npm run check` | Markdown の整形チェックと markdownlint |
| `npm run fix` | Markdown の整形と markdownlint の自動修正 |
