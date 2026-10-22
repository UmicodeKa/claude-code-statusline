# コントリビューションガイド

claude-code-statusline への関心をありがとうございます。バグ報告、ドキュメントの改善、機能の提案、プルリクエストのいずれも歓迎します。

このドキュメントでは、開発環境の準備から変更の進め方、プルリクエストを出すまでの流れを説明します。

## 関連ドキュメント

| ドキュメント | 内容 |
| --- | --- |
| [README.md](README.md) | 利用者向けの導入方法と設定 |
| [docs/SPEC.md](docs/SPEC.md) | 出力仕様 (区切り、並び、トリム、色など観測できる振る舞い) |
| [docs/DESIGN.md](docs/DESIGN.md) | 設計判断の理由と、外すと不具合につながる実装上の注意点 |
| [tests/README.md](tests/README.md) | テストハーネスの構成と fixture･assertion の書き方 |

## 基本の考え方

このリポジトリには macOS 版 (`statusline-macos.sh`) と Linux 版 (`statusline-linux.sh`) の 2 本のスクリプトがあります。

- 2 本は**仕様を共有し、実装はプラットフォーム依存の部分だけが異なります** (日付･ファイル時刻の取得コマンド、排他制御の方式など)。
- 同じ入力に対して 2 本は同一の出力を返すことが要件です。片方だけを変更すると出力がずれやすいため、共通の仕様に関わる変更は両方のスクリプトに入れてください。
- リファクタリングや堅牢化など出力を変えない変更では、既存の assertion (`tests/assertions/*`) を書き換えないでください。既存のテストがそのまま通ることが、出力が変わっていないことの確認になります。
- 出力を変える変更では、[docs/SPEC.md](docs/SPEC.md) と該当する assertion を同じプルリクエストで更新してください。
- 判断の基準は変更範囲の広さではなく、既存ケースが 1 つも落ちないかどうかです。既存の assertion を変えずに `npm test` が通るリファクタは、機能追加と同じプルリクエストに含めてかまいません。範囲が小さくても出力が変わる変更は、単独で確認してください。

## 開発環境の準備

### 必要なもの

- bash と `jq` (スクリプトの実行とテストに必要)
- `git`
- Node.js と npm

Node.js は Markdown の lint (`markdownlint-cli2`) と整形、npm スクリプトの並列･直列実行 (`npm-run-all2`) のためだけに使います。statusline スクリプト本体は Node.js に依存しません。

### セットアップ

```sh
git clone https://github.com/UmicodeKa/claude-code-statusline.git
cd claude-code-statusline
npm ci
```

`npm ci` を実行すると `prepare` スクリプト (`scripts/setup-hooks.mjs`) が走り、`git config core.hooksPath .githooks` を設定して同梱の git hooks を有効にします。

- `core.hooksPath` が既に別の値に設定されている場合は上書きせず、警告を表示して終了します。その場合に hooks を有効にするには `git config core.hooksPath .githooks` を手動で実行してください。
- `.git` が無い環境や `git` が無い環境では何もせず、インストール自体は失敗しません。

### ブランチ名の規則

`.githooks/reference-transaction` がブランチ作成時に名前を確認し、規則に合わない名前のブランチ作成を拒否します。許可されているのは次のとおりです。

- 接頭辞 `feature/`、`release/`、`hotfix/`、`dependabot/` で始まる名前
- `main`

確認対象は新規作成のみで、既存ブランチへのコミットやリネーム (`git branch -m`) は対象外です。

```sh
git switch -c feature/your-topic
```

### コミットメッセージのテンプレート

コミットメッセージは `.gitmessage` のテンプレートに沿って、`<種類>[(スコープ)]: <内容>` の形式で書きます。種類には絵文字付きの接頭辞を使います (例 `🐛fix`、`✨feat`、`📝docs`、`♻️refactor`、`💚test`、`🔧ci`、`🧹chore`)。一覧と書き方の例はテンプレート内にあります。

テンプレートを有効にするには次を実行します。

```sh
git config commit.template .gitmessage
```

## よく使うコマンド

| コマンド | 内容 |
| --- | --- |
| `npm test` | 回帰テスト (`tests/regression.sh`) 、バックグラウンド fetch の挙動テスト (`tests/git-fetch-behavior.sh`)、両版の静的一致チェック (`tests/script-parity.sh`) を順に実行 |
| `npm run preview` | 各 fixture の実出力を ANSI 色付きのまま端末に表示 (`tests/e2e-preview.sh`)。`--macos` / `--linux` で片方だけ表示できる (`bash tests/e2e-preview.sh --linux`) |
| `npm run check` | Markdown の整形チェックと lint を実行 |
| `npm run fix` | Markdown の整形と lint の自動修正を実行 |

テストの構成や fixture の追加方法は [tests/README.md](tests/README.md) を参照してください。

## 変更の進め方

1. 変更を始める前に `npm test` を実行し、すべて通ることを確認します (ベースラインの確認)。
2. 変更する箇所に関係する [docs/SPEC.md](docs/SPEC.md) の節と [docs/DESIGN.md](docs/DESIGN.md) の注意点を確認します。
3. 両方のスクリプトに変更を入れます。
4. 出力を変える場合は、[docs/SPEC.md](docs/SPEC.md) と assertion を更新し、必要に応じて fixture を追加します。
5. 次の 3 つで確認します。
   - `npm test` がすべて通る
   - `npm run check` が通る (エラーがあれば `npm run fix` で直せるものが大半です)
   - `npm run preview` で、色を含む実際の表示を目で確認する

### macOS と Linux での確認

テストハーネスは、実行環境で動かせないほうのスクリプトのケースを skip します。skip の条件や CI 用の設定は [tests/README.md](tests/README.md#実行環境と-skip) にまとめています。

- GitHub Actions (`.github/workflows/ci.yml`) は ubuntu 上で `lint` (`npm run check:ci`) と `test` (`npm test`) を実行します。CI で実行されるテストは Linux 版だけです。macOS 版は CI では skip されるため、macOS 版に関わる変更は手元の macOS で `npm test` を実行して確認してください。
- macOS でも `brew install bash flock` で bash 4.1 以上と `flock` を入れると、ハーネスは Linux 版のケースも実行します。
  ただし Linux 版は GNU coreutils の `stat -c` と `date -d` を使い、macOS に入っている BSD 版の `stat` / `date` はこれらのオプションを受け付けません。
  そのため履歴ディレクトリの確認やリセット時刻 (`HH:MM`) の表示が成り立たず、Linux 版のケースは macOS 上では大半が失敗します。
- Linux 版の確認は CI か、Linux のコンテナや仮想マシン上で `npm test` を実行して行ってください。

## Markdown の整形

`npm run fix` は Markdown の句読点や括弧などの表記を統一します (半角の句読点を全角に、全角の括弧･英数字を半角に、といった変換)。変換規則は `scripts/format-markdown.mjs` にあります。

表記ゆれを手で直す必要はありません。気になったら `npm run fix` を実行してください。

## プルリクエスト

プルリクエストのテンプレート (`.github/pull_request_template.md`) に沿って、目的と変更内容を書いてください。あわせて次の点を記載してもらえるとレビューが進めやすくなります。

- 影響する [docs/SPEC.md](docs/SPEC.md) の節
- 出力が変わるかどうか (変わる場合は変更前と変更後の表示例)
- 両方のスクリプトに変更を入れたか (片方だけの場合はその理由)
- `npm test` と `npm run check` の結果、`npm run preview` での表示確認

大きな変更や出力仕様の変更は、先に Issue で目的を共有してもらえると、方向性の相談がしやすくなります。特に履歴サンプリングや間引きの定数 (`HISTORY_LEN` / `POLL_INTERVAL_SEC` / `LOCK_TIMEOUT_SEC` / `GIT_FETCH_INTERVAL_SEC` の既定値や推奨レンジ) を変える場合は、先に Issue で目的を共有してください。

## ライセンス

このリポジトリは [0BSD](LICENSE) ライセンスで公開されています。コントリビューションも同じライセンスで提供されるものとします。
