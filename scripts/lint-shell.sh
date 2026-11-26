#!/usr/bin/env bash
# git で管理しているシェルスクリプトを列挙して ShellCheck にかける。
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
    printf '  macOS:           brew install shellcheck\n'
    printf '  Debian / Ubuntu: sudo apt-get install shellcheck\n'
  } >&2
  exit 1
fi

shellcheck --version | grep '^version:'

files=()
while IFS= read -r -d '' f; do
  files+=("$f")
done < <(git ls-files -z -- '*.sh' 'tests/lib/*-shim/*' '.githooks/*')

if ((${#files[@]} == 0)); then
  printf 'error: ShellCheck の対象ファイルが 1 件も見つかりません。git ls-files のパターンを確かめてください。\n' >&2
  exit 1
fi

printf 'checking %d files\n' "${#files[@]}"
shellcheck -- "${files[@]}"
