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
  # 子プロセスの起動と本体・描画は両版で同じ。branch 列の組み立てから呼ばれるので format-layout の比較も守る。
  check_block pr-constants '# PR の状態表示の再取得間隔' '# --- PR の状態表示の内部定数ここまで ---'
  check_block pr-common '# --- PR の状態表示 ---' '# maybe_pr_refresh:'
  # スパークと残量の計算 (spark_of / round_int / set_remaining) と、履歴ファイルの読み出し (history_chart)。
  # 間にある history_push はロックの取り方が違うので対象にしない。
  check_block spark '# spark_of <変数名> <0-100 の値>' '# 履歴ファイルに値を append'
  check_block history-chart '# 履歴ファイルから各値を spark' '# 色付けは 3 段構成'
  # 色付け・トリム・git の集計と、rate/ctx の整形からレイアウトの組み立てまで。
  # 出力を決める関数のうち OS 依存の無いもの (truncate_branch / layout_token など) をここで守る。
  check_block paint '# 色付けは 3 段構成' '# GIT_FETCH=1 のときだけ'
  check_block format-layout '# レートリミット残量の文字列を組み立てる' '# --- main ---'
  # main の描画部分 (hl_set の組み立てから、各要素の組み立てと build_layout の呼び出しまで)。
  # 手前の jq の読み取りはコメントが両版で違う (macOS 版だけ bash 3.2 の注記がある) ので含めない。
  check_block main-render '# HIGHLIGHT のトークンを' '# " | " で結合'
  # jq の読み取りのうち、コメントの後の read と jq の式。PR の取得の前倒しに使う署名と session_id も
  # ここで取り出すので、片方の版だけで式や read の数が変わるとフィールドがずれる。
  check_block stdin-read '  IFS= read -r model' '# HIGHLIGHT のトークンを'

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
  # 取得の前倒し。判定と .seen / マーカーの書き込みは block:pr-common の関数にあり、比べる範囲の外の
  # maybe_pr_refresh はそれを呼ぶだけにする。片方の版だけが間隔の判定 (pr_refresh_due) に戻ると、
  # その版では前倒しが効かなくなる。
  local pr_refresh='/^maybe_pr_refresh() {/,/^}/p'
  check_static pr-early:wanted "$pr_refresh" 'pr_refresh_wanted "$marker" "$now" "$seen" "$sig" || return'
  check_static pr-early:claim "$pr_refresh" 'if ! pr_refresh_claim "$marker" "$now" "$seen" "$sig"; then'
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
