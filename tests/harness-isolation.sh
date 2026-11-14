#!/usr/bin/env bash
# テストハーネスの起動環境の隔離を確かめるテスト。
#
# 各ハーネスは statusline を lib/statusline-env.sh の sl_run 経由で起動し、継承した環境を捨てて
# 許可した変数だけを渡す (許可リスト方式)。本スクリプトは、敵対的な環境で次を確かめる:
#
#   sl_run:*         : sl_run 自体の約束 (既定値、継承した変数を捨てる、PATH の組み方、PATH= の拒否、
#                      --path と --replace-path の併用や空の --replace-path の拒否、上書きが次の起動に残らない、
#                      conf の GIT_FETCH / PR_STATUS が env に勝つ)
#   pass:*           : 各ハーネスが全件 pass する
#   no-real-git-gh:* : 各ハーネスの実行中、statusline が本物の git / gh に届かない
#   no-real-git-gh:late : 全ハーネスの終了後に遅れて届いた呼び出しも無い
#
# 敵対的な環境は次のように作る:
#
#   1. 呼ばれたら引数を記録して失敗する git / gh のスタブを、外側の PATH の先頭に置く。
#   2. 本体が読む環境変数 (CLAUDE_STATUSLINE_* / FORCE_HYPERLINK / COLORFGBG / CLAUDE_CONFIG_DIR / HOME / TZ) を
#      敵対的な値で export する (fetch と PR の取得を有効にし、レイアウトや配色を変え、実在する conf を指す)。
#   3. その環境で各ハーネスを実行し、全件 pass することと、スタブへの呼び出しが 0 件であることを確かめる。
#
# sl_run を経由した起動は fake git / fake gh (lib/git-shim, lib/gh-shim) がスタブより前に来るので、
# 記録は残らない。sl_run を経由しない直接起動は、入力が git の経路に入れば外側の PATH のスタブに当たり、
# 出力を比べるハーネスなら敵対的な環境変数で出力が変わって落ちる。
# どちらにも当たらない直接起動 (入力に cwd が無く、出力も見ない rate-history-behavior.sh のようなハーネス) は
# 検出できない。そうした起動は本物の git / gh にも届かず、結果も環境変数に左右されないので、実害は出ない。
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
# 各ハーネスの後は SETTLE_SEC、全ハーネスの後は LATE_SEC 待つ。記録は消さずに追記させ、
# ハーネスごとの増分で判定するので、待ちきれずに次のハーネスの間に届いた呼び出しも late か次の判定で拾う。
SETTLE_SEC=1
LATE_SEC=3

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
export TZ=Asia/Tokyo
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

# sl_run が引数 $2... を拒否する (終了コード 2 で、コマンドを起動しない) ことを確かめる。
expect_rejected() {
  local name=$1 rc=0
  shift
  sl_run "$@" -- true 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ]; then
    pass_case "$name"
  else
    fail_case "$name" "sl_run accepted: $* (exit $rc)"
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

  expect_rejected "sl_run:rejects-path" PATH=/x
  expect_rejected "sl_run:rejects-path-with-replace-path" --path /extra --replace-path "/only:$PATH"
  expect_rejected "sl_run:rejects-empty-replace-path" --replace-path ""

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

call_count() { wc -l < "$CALLS" | tr -d ' '; }

# 記録の $2 行目より後に、スタブへの呼び出しが増えていないことを確かめる。
check_new_calls() {
  local name=$1 seen=$2 now
  now=$(call_count)
  if [ "$now" -eq "$seen" ]; then
    pass_case "$name"
  else
    fail_case "$name" "statusline reached the real git / gh $((now - seen)) time(s) (started without sl_run?):
$(tail -n "+$((seen + 1))" "$CALLS" | head -n 5)"
  fi
}

main() {
  printf 'test harness isolation tests\n\n'

  check_sl_run

  local harness out rc seen=0
  for harness in "${HARNESSES[@]}"; do
    out="$TMP_ROOT/${harness%.sh}.out"
    rc=0
    bash "$TESTS_DIR/$harness" > "$out" 2>&1 || rc=$?
    sleep "$SETTLE_SEC"

    if [ "$rc" -eq 0 ]; then
      pass_case "pass:$harness"
    else
      fail_case "pass:$harness" "exit $rc under the hostile environment. last lines:
$(tail -n 20 "$out")"
    fi

    check_new_calls "no-real-git-gh:$harness" "$seen"
    seen=$(call_count)
  done

  sleep "$LATE_SEC"
  check_new_calls "no-real-git-gh:late" "$seen"

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
