#!/usr/bin/env bash
# テストハーネスの起動環境の隔離を確かめるテスト。
#
# 各ハーネスは statusline を lib/statusline-env.sh の sl_run 経由で起動し、継承した環境を捨てて
# 許可した変数だけを渡す (許可リスト方式)。本スクリプトは、敵対的な環境で次を確かめる:
#
#   sl_run:*         : sl_run 自体の約束 (既定値、継承した変数を捨てる、PATH の組み方、PATH= の拒否、
#                      上書きが次の起動に残らない、conf の GIT_FETCH / PR_STATUS が env に勝つ)
#   pass:*           : 各ハーネスが全件 pass する
#   no-real-git-gh:* : 各ハーネスの実行中、statusline が本物の git / gh に届かない
#
# 敵対的な環境は次のように作る:
#
#   1. 呼ばれたら引数を記録して失敗する git / gh のスタブを、外側の PATH の先頭に置く。
#   2. 本体が読む環境変数 (CLAUDE_STATUSLINE_* / FORCE_HYPERLINK / COLORFGBG / CLAUDE_CONFIG_DIR / HOME) を
#      敵対的な値で export する (fetch と PR の取得を有効にし、レイアウトや配色を変え、実在する conf を指す)。
#   3. その環境で各ハーネスを実行し、全件 pass することと、スタブへの呼び出しが 0 件であることを確かめる。
#
# sl_run を経由した起動は fake git / fake gh (lib/git-shim, lib/gh-shim) がスタブより前に来るので、
# 記録は残らない。sl_run を経由しない直接起動は外側の PATH をそのまま使うのでスタブに当たり、
# 敵対的な環境変数も混ざるので出力の比較でも落ちる。
# e2e-preview.sh は目視用で pass / fail を返さないため対象外。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/statusline-env.sh
source "$TESTS_DIR/lib/statusline-env.sh"

HARNESSES=(
  regression.sh
  git-fetch-behavior.sh
  pr-status-behavior.sh
  rate-history-behavior.sh
  color-scheme-behavior.sh
)

# バックグラウンドの子プロセス (fetch / PR の取得) がスタブに届くまで待つ秒数。
SETTLE_SEC=1

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }

TMP_ROOT="$(mktemp -d -t claude-statusline-isolation.XXXXXX)"
trap 'rm -r "$TMP_ROOT" 2>/dev/null || true' EXIT

STUBS="$TMP_ROOT/stubs"
CALLS="$TMP_ROOT/calls.log"
mkdir -p "$STUBS"
: > "$CALLS"

# 記録用のスタブ。env -i の下でも記録できるよう、ログのパスを埋め込む。
for cmd in git gh; do
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s"\nexit 1\n' "$cmd" "$CALLS" > "$STUBS/$cmd"
  chmod +x "$STUBS/$cmd"
done

# 敵対的な conf / settings.json / 履歴ディレクトリ。直接起動されると、これらが出力を変える。
HOSTILE_HOME="$TMP_ROOT/home"
HOSTILE_CFG="$TMP_ROOT/claude-config"
HOSTILE_HIST="$TMP_ROOT/hist"
mkdir -p "$HOSTILE_HOME/.claude" "$HOSTILE_CFG" "$HOSTILE_HIST"
chmod 700 "$HOSTILE_HIST"
HOSTILE_CONF="$TMP_ROOT/statusline.conf"
printf 'GIT_FETCH=1\nPR_STATUS=1\nSHOW_CWD=0\nLAYOUT_LINE1=session\n' > "$HOSTILE_CONF"
cp "$HOSTILE_CONF" "$HOSTILE_HOME/.claude/statusline.conf"
printf '{"theme":"light"}\n' > "$HOSTILE_CFG/settings.json"

export PATH="$STUBS:$PATH"
export HOME="$HOSTILE_HOME"
export CLAUDE_CONFIG_DIR="$HOSTILE_CFG"
export COLORFGBG="0;15"
export FORCE_HYPERLINK=0
export CLAUDE_STATUSLINE_CONFIG="$HOSTILE_CONF"
export CLAUDE_STATUSLINE_HISTORY_DIR="$HOSTILE_HIST"
export CLAUDE_STATUSLINE_COLOR_SCHEME=light
export CLAUDE_STATUSLINE_GIT_FETCH=1
export CLAUDE_STATUSLINE_PR_STATUS=1
export CLAUDE_STATUSLINE_SHOW_CWD=0
export CLAUDE_STATUSLINE_SHOW_MODEL_NAME=0
export CLAUDE_STATUSLINE_HIGHLIGHT=directory
export CLAUDE_STATUSLINE_LAYOUT_LINE1=session
export CLAUDE_STATUSLINE_LAYOUT_LINE2=session
export CLAUDE_STATUSLINE_TEST_PR_TIMEOUT_SEC=1

failed=0
total=0

pass_case() {
  total=$((total + 1))
  printf '  %s %s\n' "$(green ok)" "$1"
}
fail_case() {
  total=$((total + 1))
  printf '  %s %s\n' "$(red FAIL)" "$1" >&2
  printf '%s\n' "$2" | sed 's/^/    /' >&2
  failed=$((failed + 1))
}

# sl_run COMMAND を env にして、statusline に渡る環境を NAME=value の行で返す。
sl_env() { sl_run "$@" -- env; }

# 環境 $1 (sl_env の出力) で、変数 $2 の値が $3 であることを確かめる。$3 が <unset> なら未設定を期待する。
env_has() {
  local line
  line=$(printf '%s\n' "$1" | grep "^$2=" || true)
  if [ "$3" = "<unset>" ]; then
    [ -z "$line" ]
  else
    [ "$line" = "$2=$3" ]
  fi
}

expect_env() {
  local name=$1 env_out=$2 var=$3 want=$4
  if env_has "$env_out" "$var" "$want"; then
    pass_case "$name"
  else
    fail_case "$name" "$var: want '$want', got '$(printf '%s\n' "$env_out" | grep "^$var=" || printf '<unset>')'"
  fi
}

# sl_run 自体の約束を確かめる (敵対的な環境の下で実行する)。
check_sl_run() {
  local out
  out=$(sl_env)
  expect_env "sl_run:default-git-fetch" "$out" CLAUDE_STATUSLINE_GIT_FETCH 0
  expect_env "sl_run:default-pr-status" "$out" CLAUDE_STATUSLINE_PR_STATUS 0
  expect_env "sl_run:default-config" "$out" CLAUDE_STATUSLINE_CONFIG "$NO_CONFIG"
  expect_env "sl_run:default-home" "$out" HOME /nonexistent-home
  expect_env "sl_run:default-claude-config-dir" "$out" CLAUDE_CONFIG_DIR /nonexistent-claude-config-dir
  expect_env "sl_run:drops-inherited-layout" "$out" CLAUDE_STATUSLINE_LAYOUT_LINE1 "<unset>"
  expect_env "sl_run:drops-inherited-history-dir" "$out" CLAUDE_STATUSLINE_HISTORY_DIR "<unset>"
  expect_env "sl_run:drops-inherited-colorfgbg" "$out" COLORFGBG "<unset>"
  expect_env "sl_run:drops-inherited-hyperlink" "$out" FORCE_HYPERLINK "<unset>"
  expect_env "sl_run:path-shims-first" "$out" PATH "$GIT_SHIM_DIR:$GH_SHIM_DIR:$PATH"

  out=$(sl_env --path /extra-a --path /extra-b)
  expect_env "sl_run:path-extra-before-shims" "$out" PATH "/extra-a:/extra-b:$GIT_SHIM_DIR:$GH_SHIM_DIR:$PATH"
  # --replace-path は shim も足さずに丸ごと差し替える (env を見つけるため外側の PATH は含める)。
  out=$(sl_env --replace-path "/only:$PATH")
  expect_env "sl_run:replace-path" "$out" PATH "/only:$PATH"

  local rc=0
  sl_run PATH=/x -- true 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ]; then
    pass_case "sl_run:rejects-path"
  else
    fail_case "sl_run:rejects-path" "PATH= was accepted (exit $rc)"
  fi

  out=$(sl_env CLAUDE_STATUSLINE_PR_STATUS=1 STATUSLINE_TEST_GH_SLEEP=20)
  expect_env "sl_run:override" "$out" CLAUDE_STATUSLINE_PR_STATUS 1
  out=$(sl_env)
  expect_env "sl_run:override-not-kept" "$out" STATUSLINE_TEST_GH_SLEEP "<unset>"

  # conf が指定するときは、呼び出し側の値より conf が勝つ (env を空にする)。
  local conf="$TMP_ROOT/opt-out.conf"
  printf 'GIT_FETCH=0\nPR_STATUS=0\n' > "$conf"
  out=$(sl_env CLAUDE_STATUSLINE_PR_STATUS=1 CLAUDE_STATUSLINE_GIT_FETCH=1 CLAUDE_STATUSLINE_CONFIG="$conf")
  expect_env "sl_run:conf-blanks-pr-status" "$out" CLAUDE_STATUSLINE_PR_STATUS ""
  expect_env "sl_run:conf-blanks-git-fetch" "$out" CLAUDE_STATUSLINE_GIT_FETCH ""
}

main() {
  printf 'test harness isolation tests\n\n'

  check_sl_run

  local harness out rc calls
  for harness in "${HARNESSES[@]}"; do
    out="$TMP_ROOT/${harness%.sh}.out"
    : > "$CALLS"
    rc=0
    bash "$TESTS_DIR/$harness" > "$out" 2>&1 || rc=$?
    sleep "$SETTLE_SEC"

    if [ "$rc" -eq 0 ]; then
      pass_case "pass:$harness"
    else
      fail_case "pass:$harness" "exit $rc under the hostile environment. last lines:
$(tail -n 20 "$out")"
    fi

    if [ ! -s "$CALLS" ]; then
      pass_case "no-real-git-gh:$harness"
    else
      calls=$(wc -l < "$CALLS" | tr -d ' ')
      fail_case "no-real-git-gh:$harness" "statusline reached the real git / gh ${calls} time(s) (started without sl_run?):
$(head -n 5 "$CALLS")"
    fi
  done

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
