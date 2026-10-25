#!/usr/bin/env bash
# 両 statusline スクリプトの静的な一致チェック。
#
# regression.sh は実行できる側のスクリプトだけを検証する (macOS 版は macOS ホスト、
# Linux 版は bash 4.1+ と flock がある環境)。そのため CI (ubuntu) では macOS 版が、
# 手元の macOS では Linux 版が走らず、片方だけを直したドリフトを同じ実行の中で
# 検出できない。ここでは OS に依存しない比較だけを行い、どちらの環境でも走らせる。
#
#   1. block:<名前>   : OS 依存要素の無い共通ブロックが両スクリプトで一字一句一致する
#   2. static:<名前>  : 消すと出力や挙動が静かに壊れる記述が両スクリプトに残っている
#
# ブロックは開始マーカー行 (行頭一致) から終了マーカー行の手前までを取り出す。
# マーカーのコメントを書き換えるとブロックが取れなくなり、FAIL として検出される。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"

MACOS_SCRIPT="$REPO_DIR/statusline-macos.sh"
DEBIAN_SCRIPT="$REPO_DIR/statusline-linux.sh"

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }

total=0
failed=0

pass() {
  total=$((total + 1))
  printf '  %s %s\n' "$(green ok)" "$1"
}

fail() {
  total=$((total + 1))
  failed=$((failed + 1))
  printf '  %s %s: %s\n' "$(red FAIL)" "$1" "$2" >&2
}

# 開始マーカー行から終了マーカー行の手前までを出力する。開始が見つからなければ空。
extract_block() {
  local file=$1 start=$2 end=$3
  awk -v s="$start" -v e="$end" '
    !p && index($0, s) == 1 { p = 1; print; next }
    p && index($0, e) == 1 { exit }
    p { print }
  ' "$file"
}

check_block() {
  local name=$1 start=$2 end=$3
  local macos linux
  macos="$(extract_block "$MACOS_SCRIPT" "$start" "$end")"
  linux="$(extract_block "$DEBIAN_SCRIPT" "$start" "$end")"
  if [ -z "$macos" ] || [ -z "$linux" ]; then
    fail "block:$name" "start marker not found: $start"
  elif [ "$macos" = "$linux" ]; then
    pass "block:$name"
  else
    fail "block:$name" "differs between scripts"
    diff <(printf '%s\n' "$macos") <(printf '%s\n' "$linux") | sed 's/^/      /' >&2 || true
  fi
}

# 両スクリプトの指定範囲に固定文字列が含まれることを確認する。
check_static() {
  local name=$1 range=$2 needle=$3
  local file missing=""
  for file in "$MACOS_SCRIPT" "$DEBIAN_SCRIPT"; do
    # パイプ (sed | grep -q) にしない: grep -q が一致した時点で終了すると sed が SIGPIPE で
    # 落ち、pipefail 下ではパイプ全体が失敗扱いになって、一致しているのに FAIL になりうる。
    if ! grep -qF -- "$needle" <<<"$(sed -n "$range" "$file")"; then
      missing="$missing $(basename "$file")"
    fi
  done
  if [ -z "$missing" ]; then
    pass "static:$name"
  else
    fail "static:$name" "'$needle' not found in${missing}"
  fi
}

# コメント行を除いた行に echo コマンドが無いことを確認する (値に -n / -e が来ると壊れるため
# printf '%s' に統一している)。行頭からコメント記号までに echo が現れる行を検出する。
check_no_echo() {
  local file hits=""
  for file in "$MACOS_SCRIPT" "$DEBIAN_SCRIPT"; do
    if grep -nE '^[^#]*\becho\b' "$file" >/dev/null; then
      hits="$hits $(basename "$file")"
    fi
  done
  if [ -z "$hits" ]; then
    pass "static:no-echo"
  else
    fail "static:no-echo" "echo used in${hits} (use printf '%s')"
  fi
}

main() {
  printf 'statusline script parity checks\n'
  printf 'scripts:\n  macOS:  %s\n  Linux:  %s\n\n' "$MACOS_SCRIPT" "$DEBIAN_SCRIPT"

  check_block config-load '# === ユーザー設定ファイルの読み込み ===' '# === カスタマイズ設定'
  check_block settings '# === カスタマイズ設定' '# === 内部定数'
  check_block interval-clamp '# --- 間引き定数の推奨レンジ ---' '# --- カラースキーム ---'
  check_block color-scheme '# --- カラースキーム ---' 'esac'
  # PR の状態表示。ロックの取り方が違う maybe_pr_refresh を除き、定数・キャッシュの読み書き・
  # 子プロセスの起動と本体・描画は両版で同じ。branch 列の組み立てから呼ばれるので layout の比較も守る。
  check_block pr-constants '# PR の状態表示の再取得間隔' '# --- PR の状態表示の内部定数ここまで ---'
  check_block pr-common '# --- PR の状態表示 ---' '# maybe_pr_refresh:'
  check_block layout '# レイアウトのトークンを描画済み文字列に引く' '# 配列を区切り文字で結合する'

  # ロケール固定はトリムの文字数換算に効くため冒頭 (先頭 20 行) にあることまで見る。
  check_static locale '1,20p' 'export LC_ALL=C.UTF-8'
  # バックグラウンドの子プロセスの認証プロンプト封じ。4 つで 1 セット (1 つ欠けても TUI に漏れる)。
  # fetch と pr の両方の子プロセスで要るので、関数の範囲ごとに確かめる。
  local fn var
  for fn in maybe_git_fetch pr_spawn_refresh; do
    for var in GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true SSH_ASKPASS=/bin/true SSH_ASKPASS_REQUIRE=force; do
      check_static "no-prompt:$fn:${var%%=*}" "/^${fn}() {/,/^}/p" "$var"
    done
  done
  # fetch 子プロセスの fd 付け替え。外すと描画が fetch 完了まで待たされる。
  check_static fetch-fd-redirect '/^maybe_git_fetch() {/,/^}/p' '>/dev/null 2>&1 </dev/null'
  # PR の状態表示の子プロセス。gh のプロンプトと更新通知を封じる 3 つと、出力や問い合わせ先を
  # 変えてしまう 3 つの除去。fd の付け替えは外すと描画が gh の完了まで待たされる。
  local pr_spawn='/^pr_spawn_refresh() {/,/^}/p'
  check_static pr-gh-env:GH_PROMPT_DISABLED "$pr_spawn" 'GH_PROMPT_DISABLED=1'
  check_static pr-gh-env:GH_NO_UPDATE_NOTIFIER "$pr_spawn" 'GH_NO_UPDATE_NOTIFIER=1'
  check_static pr-gh-env:GH_NO_EXTENSION_UPDATE_NOTIFIER "$pr_spawn" 'GH_NO_EXTENSION_UPDATE_NOTIFIER=1'
  check_static pr-gh-env:unset "$pr_spawn" 'unset GH_REPO GH_FORCE_TTY CLICOLOR_FORCE'
  check_static pr-fd-redirect "$pr_spawn" 'pr_refresh_child "$cwd" "$branch" "$cache" "$inflight" >/dev/null 2>&1 </dev/null &'
  check_no_echo

  printf '\n'
  if [ "$failed" -eq 0 ]; then
    printf '%s: %d/%d passed\n' "$(green PASS)" "$total" "$total"
    exit 0
  else
    printf '%s: %d/%d failed\n' "$(red FAIL)" "$failed" "$total" >&2
    exit 1
  fi
}

main "$@"
