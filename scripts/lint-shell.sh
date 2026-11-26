#!/usr/bin/env bash
# リポジトリのシェルスクリプト (.gitignore で除外したものを除く) を列挙して ShellCheck にかける。
# ShellCheck は 0.11.0 以上を前提にする (CI は v0.11.0 に固定している)。
# 設定 (source-path など) はリポジトリのルートの .shellcheckrc にある。
#
# 対象は *.sh、テスト用の shim (tests/lib/*-shim/*)、git hooks (.githooks/*)。
# statusline.conf は単純代入だけの雛形で、全行が SC2034 になるため対象外。
#
# macOS の /usr/bin/env bash は 3.2 のことがあるため、mapfile などの bash 4 の機能は使わない。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v shellcheck >/dev/null 2>&1; then
  {
    printf 'error: shellcheck が見つかりません。インストールしてから再実行してください。\n'
    printf '  macOS: brew install shellcheck\n'
    printf '  Linux: https://github.com/koalaman/shellcheck/releases の v0.11.0 以上 (apt の版は古いことがある)\n'
  } >&2
  exit 1
fi

shellcheck --version | grep '^version:'

# --others --exclude-standard で、まだ git add していない新しいスクリプトも対象に入れる。
# 削除したがステージしていないファイルは index に残って列挙されるため、通常のファイルだけを渡す。
files=()
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  files+=("$f")
done < <(git ls-files -z --cached --others --exclude-standard -- '*.sh' 'tests/lib/*-shim/*' '.githooks/*')

if ((${#files[@]} == 0)); then
  printf 'error: ShellCheck の対象ファイルが 1 件も見つかりません。git ls-files のパターンを確かめてください。\n' >&2
  exit 1
fi

printf 'checking %d files\n' "${#files[@]}"
shellcheck -- "${files[@]}"
