#!/usr/bin/env bash
# rate 履歴ファイル (${HISTORY_DIR}/rate) の書き込みの挙動テスト。
#
# regression.sh が検証するのは「描画された文字列」だけで、最新の保存値はチャート右端の現在値で
# 隠れるため、追記したかどうかは出力に現れない。そこで本スクリプトは履歴ファイルの中身を直接見て、
# 次の不変条件を検証する:
#
#   init-fill                  : 空の履歴に 1 回描画すると、現在値が RATE_CHART_LEN_MAX (20) 行書かれる
#   throttle                   : 間隔内の 2 回目の描画では追記しない
#   append-after-interval      : mtime が間隔より古ければ 1 行追記する
#   storage-cap                : 20 行を超えるファイルに追記しても末尾 20 行に切り詰める
#   poll-max-follows-chart-len : POLL_INTERVAL_SEC の上限が 18000 / RATE_CHART_LEN に従う
#   poll-max-default           : 既定のチャート長では上限が 3000
#   poll-clamp-zero            : POLL_INTERVAL_SEC=0 は下限 60 に丸められる
#   poll-invalid-default       : POLL_INTERVAL_SEC=abc は既定 480 に戻る
#
# conf は一時ファイルに書いて CLAUDE_STATUSLINE_CONFIG で渡し、開発者の ~/.claude/statusline.conf は
# 読ませない。RATE_CHART_LEN と POLL_INTERVAL_SEC には env の口が無いので、開発者のシェルの環境変数で
# 結果が変わることもない。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"

MACOS_SCRIPT="$REPO_DIR/statusline-macos.sh"
DEBIAN_SCRIPT="$REPO_DIR/statusline-linux.sh"

# shellcheck source=lib/find-debian-bash.sh
source "$TESTS_DIR/lib/find-debian-bash.sh"
# shellcheck source=lib/config-file.sh
source "$TESTS_DIR/lib/config-file.sh"
# shellcheck source=lib/is-macos-host.sh
source "$TESTS_DIR/lib/is-macos-host.sh"
# shellcheck source=lib/age-file.sh
source "$TESTS_DIR/lib/age-file.sh"
DEBIAN_BASH="$(find_debian_bash)"
RUN_MACOS=0
is_macos_host && RUN_MACOS=1

# 履歴ファイルに残す件数 (本体の RATE_CHART_LEN_MAX)。
STORAGE_LEN=20
# 仕込む古い値と、描画で渡す現在の残量。追記されたかどうかを末尾の行で見分けるため、別の値にする。
OLD_VALUE=50
NEW_REMAINING=90

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }

failed=0
total=0

pass_case() {
  total=$((total + 1))
  printf '  %s %s\n' "$(green ok)" "$1"
}
fail_case() {
  total=$((total + 1))
  printf '  %s %s\n' "$(red FAIL)" "$1" >&2
  printf '    %s\n' "$2" >&2
  failed=$((failed + 1))
}

# ケースの作業ディレクトリを作り、case_dir / hist / rate_file / config を設定する。
#   $1: conf に書く中身 (空なら conf 無し)
# 後始末は呼び出し側の trap で cleanup_case を呼ぶ。
setup_case() {
  case_dir="$(mktemp -d -t claude-statusline-rate.XXXXXX)"
  hist="$case_dir/hist"
  mkdir "$hist"
  chmod 700 "$hist"
  rate_file="$hist/rate"
  config="$NO_CONFIG"
  if [ -n "$1" ]; then
    config="$case_dir/statusline.conf"
    printf '%s\n' "$1" > "$config"
  fi
}

cleanup_case() { rm -r "$case_dir" 2>/dev/null || true; }

# 古い値を $1 行書いた履歴ファイルを作り、mtime を $2 秒前にする。
seed_history() {
  local lines=$1 age=$2 i
  for ((i = 0; i < lines; i++)); do
    printf '%s\n' "$OLD_VALUE"
  done > "$rate_file"
  age_file "$rate_file" "$age"
}

# statusline を 1 回実行する。rate の使用率は 100 - NEW_REMAINING。描画内容は見ない。
#   $1 bash / $2 script
run_sl() {
  local bash_bin=$1 script=$2
  printf '{"rate_limits":{"five_hour":{"used_percentage":%d}}}' "$((100 - NEW_REMAINING))" \
    | CLAUDE_STATUSLINE_HISTORY_DIR="$hist" TZ=UTC \
      CLAUDE_STATUSLINE_CONFIG="$config" \
      "$bash_bin" "$script" >/dev/null 2>&1
}

line_count() { wc -l < "$rate_file" | tr -d ' '; }
last_line() { tail -n 1 "$rate_file"; }

# 追記されたか (末尾が現在値か) を確かめる。
#   $1 ケース名 / $2 期待 (appended / skipped) / $3 失敗時の説明
expect_append() {
  local name=$1 expected=$2 detail=$3 actual=skipped
  [ "$(last_line)" = "$NEW_REMAINING" ] && actual=appended
  if [ "$actual" = "$expected" ]; then
    pass_case "$name"
  else
    fail_case "$name" "${detail} (期待 ${expected}、実際 ${actual}、$(line_count) 行)"
  fi
}

# --- init-fill: 空の履歴への初回描画は現在値で 20 行埋める ---
case_init_fill() {
  local bash_bin=$1 script=$2 label=$3
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN

  run_sl "$bash_bin" "$script"
  local count distinct
  count=$(line_count)
  distinct=$(sort -u "$rate_file" | tr '\n' ' ')
  if [ "$count" = "$STORAGE_LEN" ] && [ "$distinct" = "$NEW_REMAINING " ]; then
    pass_case "init-fill [$label]"
  else
    fail_case "init-fill [$label]" \
      "初回は現在値 ${NEW_REMAINING} を ${STORAGE_LEN} 行書くはず (実際 ${count} 行、値: ${distinct})"
  fi
}

# --- throttle: 間隔 (既定 480 秒) 内の描画では追記しない ---
case_throttle() {
  local bash_bin=$1 script=$2 label=$3
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_history "$STORAGE_LEN" 10
  run_sl "$bash_bin" "$script"
  expect_append "throttle [$label]" skipped "10 秒前に更新した履歴に追記した"
}

# --- append-after-interval: 間隔より古ければ 1 行追記する ---
case_append_after_interval() {
  local bash_bin=$1 script=$2 label=$3
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_history 5 500
  run_sl "$bash_bin" "$script"
  if [ "$(line_count)" = "6" ]; then
    expect_append "append-after-interval [$label]" appended "500 秒前の履歴に追記しなかった"
  else
    fail_case "append-after-interval [$label]" "5 行の履歴が $(line_count) 行になった (期待 6 行)"
  fi
}

# --- storage-cap: 追記後は末尾 20 行に切り詰める (表示長ではなく保存件数で切る) ---
case_storage_cap() {
  local bash_bin=$1 script=$2 label=$3
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_history 25 500
  run_sl "$bash_bin" "$script"
  if [ "$(line_count)" = "$STORAGE_LEN" ]; then
    expect_append "storage-cap [$label]" appended "追記されていない"
  else
    fail_case "storage-cap [$label]" "25 行の履歴に追記した結果が $(line_count) 行 (期待 ${STORAGE_LEN} 行)"
  fi
}

# --- poll-max-follows-chart-len: RATE_CHART_LEN=20 なら上限は 18000 / 20 = 900 ---
# POLL_INTERVAL_SEC=3000 は 900 に丸められるので、1000 秒前の履歴には追記する。
case_poll_max_follows_chart_len() {
  local bash_bin=$1 script=$2 label=$3
  setup_case $'RATE_CHART_LEN=20\nPOLL_INTERVAL_SEC=3000'
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_history "$STORAGE_LEN" 1000
  run_sl "$bash_bin" "$script"
  expect_append "poll-max-follows-chart-len [$label]" appended \
    "上限が 900 に下がらず、1000 秒前の履歴に追記しなかった"
}

# --- poll-max-default: 既定のチャート長 (6) では上限 3000 ---
case_poll_max_default() {
  local bash_bin=$1 script=$2 label=$3
  setup_case 'POLL_INTERVAL_SEC=99999'
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_history "$STORAGE_LEN" 2000
  run_sl "$bash_bin" "$script"
  expect_append "poll-max-default:2000s [$label]" skipped "上限 3000 より短い 2000 秒で追記した"

  seed_history "$STORAGE_LEN" 3100
  run_sl "$bash_bin" "$script"
  expect_append "poll-max-default:3100s [$label]" appended "上限 3000 を過ぎた 3100 秒で追記しなかった"
}

# --- poll-clamp-zero: POLL_INTERVAL_SEC=0 は下限 60 に丸められ、30 秒前の履歴には追記しない ---
case_poll_clamp_zero() {
  local bash_bin=$1 script=$2 label=$3
  setup_case 'POLL_INTERVAL_SEC=0'
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_history "$STORAGE_LEN" 30
  run_sl "$bash_bin" "$script"
  expect_append "poll-clamp-zero [$label]" skipped "下限 60 に丸められず、30 秒前の履歴に追記した"
}

# --- poll-invalid-default: POLL_INTERVAL_SEC=abc は既定 480 に戻る ---
case_poll_invalid_default() {
  local bash_bin=$1 script=$2 label=$3
  setup_case 'POLL_INTERVAL_SEC=abc'
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_history "$STORAGE_LEN" 400
  run_sl "$bash_bin" "$script"
  expect_append "poll-invalid-default:400s [$label]" skipped "既定 480 より短い 400 秒で追記した"

  seed_history "$STORAGE_LEN" 500
  run_sl "$bash_bin" "$script"
  expect_append "poll-invalid-default:500s [$label]" appended "既定 480 を過ぎた 500 秒で追記しなかった"
}

run_all_cases() {
  local bash_bin=$1 script=$2 label=$3
  case_init_fill                  "$bash_bin" "$script" "$label"
  case_throttle                   "$bash_bin" "$script" "$label"
  case_append_after_interval      "$bash_bin" "$script" "$label"
  case_storage_cap                "$bash_bin" "$script" "$label"
  case_poll_max_follows_chart_len "$bash_bin" "$script" "$label"
  case_poll_max_default           "$bash_bin" "$script" "$label"
  case_poll_clamp_zero            "$bash_bin" "$script" "$label"
  case_poll_invalid_default       "$bash_bin" "$script" "$label"
}

require_command() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'rate-history-behavior.sh: required command not found: %s\n' "$cmd" >&2
    exit 2
  fi
}

main() {
  require_command jq
  require_debian_bash_if_requested "$(basename "$0")" "$DEBIAN_BASH"

  printf 'statusline rate history behavior tests\n'
  if [ "$RUN_MACOS" -eq 0 ]; then
    printf 'macOS host: %s (macOS script tests will be skipped)\n' \
      "$(red "not detected ($(uname -s))")"
  fi
  if [ -n "$DEBIAN_BASH" ]; then
    printf 'Linux bash: %s\n' "$DEBIAN_BASH"
  else
    printf 'Linux bash: %s (Linux script tests will be skipped)\n' \
      "$(red 'not found (need bash 4.1+ and flock)')"
  fi
  printf '\n'

  if [ "$RUN_MACOS" -eq 1 ]; then
    run_all_cases /bin/bash "$MACOS_SCRIPT" macOS
  fi
  if [ -n "$DEBIAN_BASH" ]; then
    run_all_cases "$DEBIAN_BASH" "$DEBIAN_SCRIPT" Linux
  fi

  printf '\n'
  if [ "$failed" -eq 0 ]; then
    printf '%s: %d/%d passed' "$(green PASS)" "$total" "$total"
    if [ "$RUN_MACOS" -eq 0 ]; then
      printf ' (macOS cases skipped: need macOS host)'
    fi
    if [ -z "$DEBIAN_BASH" ]; then
      printf ' (Linux cases skipped: need bash 4.1+ and flock)'
    fi
    printf '\n'
    exit 0
  else
    printf '%s: %d/%d failed\n' "$(red FAIL)" "$failed" "$total" >&2
    exit 1
  fi
}

main "$@"
