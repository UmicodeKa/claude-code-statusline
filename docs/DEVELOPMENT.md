# 開発ガイド

このドキュメントは、オーナーとコーディングエージェント向けに、開発環境の準備と変更の進め方をまとめたものです。このリポジトリは Issue や Pull Request を受け付けていません (方針は [README.md](../README.md#開発者向け) を参照)。

## 関連ドキュメント

| ドキュメント | 内容 |
| --- | --- |
| [README.md](../README.md) | 利用者向けの導入方法と設定 |
| [SPEC.md](SPEC.md) | 出力仕様 (区切り、並び、トリム、色など観測できる振る舞い) |
| [DESIGN.md](DESIGN.md) | 設計判断の理由と、外すと不具合につながる実装上の注意点 |
| [tests/README.md](../tests/README.md) | テストハーネスの構成と fixture･assertion の書き方 |

## 基本の考え方

このリポジトリには macOS 版 (`statusline-macos.sh`) と Linux 版 (`statusline-linux.sh`) の 2 本のスクリプトがあります。

- 2 本は**仕様を共有し、実装はプラットフォーム依存の部分だけが異なります** (日付･ファイル時刻の取得コマンド、排他制御の方式など)。
- 同じ入力に対して 2 本は同一の出力を返すことが要件です。片方だけを変更すると出力がずれやすいため、共通の仕様に関わる変更は両方のスクリプトに入れます。
- リファクタリングや堅牢化など出力を変えない変更では、既存の assertion (`tests/assertions/*`) を書き換えません。既存のテストがそのまま通ることが、出力が変わっていないことの確認になります。
- 出力を変える変更では、[SPEC.md](SPEC.md) と該当する assertion を同じ変更で更新します。
- 判断の基準は変更範囲の広さではなく、既存ケースが 1 つも落ちないかどうかです。既存の assertion を変えずに `npm test` が通るリファクタは、機能追加と同じ変更に含めてかまいません。範囲が小さくても出力が変わる変更は、単独で確認します。

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

- `core.hooksPath` が既に別の値に設定されている場合は上書きせず、警告を表示して終了します。その場合に hooks を有効にするには `git config core.hooksPath .githooks` を手動で実行します。
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

テストの構成や fixture の追加方法は [tests/README.md](../tests/README.md) を参照してください。

## 変更の進め方

1. 変更を始める前に `npm test` を実行し、すべて通ることを確認します (ベースラインの確認)。
2. 変更する箇所に関係する [SPEC.md](SPEC.md) の節と [DESIGN.md](DESIGN.md) の注意点を確認します。
3. 両方のスクリプトに変更を入れます。
4. 出力を変える場合は、[SPEC.md](SPEC.md) と assertion を更新し、必要に応じて fixture を追加します。
5. 次の 3 つで確認します。
   - `npm test` がすべて通る
   - `npm run check` が通る (エラーがあれば `npm run fix` で直せるものが大半です)
   - `npm run preview` で、色を含む実際の表示を目で確認する

### macOS と Linux での確認

テストハーネスは、実行環境で動かせないほうのスクリプトのケースを skip します。skip の条件や CI 用の設定は [tests/README.md](../tests/README.md#実行環境と-skip) にまとめています。

- GitHub Actions (`.github/workflows/ci.yml`) は ubuntu 上で `lint` (`npm run check:ci`) と `test` (`npm test`) を実行します。CI で実行されるテストは Linux 版だけです。macOS 版は CI では skip されるため、macOS 版に関わる変更は手元の macOS で `npm test` を実行して確認します。
- macOS でも `brew install bash flock` で bash 4.1 以上と `flock` を入れると、ハーネスは Linux 版のケースも実行します。
  ただし Linux 版は GNU coreutils の `stat -c` と `date -d` を使い、macOS に入っている BSD 版の `stat` / `date` はこれらのオプションを受け付けません。
  そのため履歴ディレクトリの確認やリセット時刻 (`HH:MM`) の表示が成り立たず、Linux 版のケースは macOS 上では大半が失敗します。
- Linux 版の確認は CI か、Linux のコンテナや仮想マシン上で `npm test` を実行して行います。

## Markdown の整形

`npm run fix` は Markdown の句読点や括弧などの表記を統一します (半角の句読点を全角に、全角の括弧･英数字を半角に、といった変換)。変換規則は `scripts/format-markdown.mjs` にあります。

表記ゆれを手で直す必要はありません。気になったら `npm run fix` を実行します。

## Pull Request の書き方

Pull Request の説明は、テンプレート (`.github/pull_request_template.md`) に沿って書きます。あわせて記載する内容は [CLAUDE.md](../CLAUDE.md) の｢変更の進め方｣を参照してください。

履歴サンプリングや間引きの定数 (`HISTORY_LEN` / `POLL_INTERVAL_SEC` / `LOCK_TIMEOUT_SEC` / `GIT_FETCH_INTERVAL_SEC` の既定値や推奨レンジ) を変える場合は、先に Issue で目的を整理します。

## ライセンス

このリポジトリは [0BSD](../LICENSE) ライセンスで公開されています。
