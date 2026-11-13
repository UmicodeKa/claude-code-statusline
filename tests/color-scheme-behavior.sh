#!/usr/bin/env bash
# COLOR_SCHEME=auto (Claude Code の theme に合わせた配色の自動切り替え) の挙動テスト。
#
# regression.sh は固定の入力に対する出力を見るが、auto は settings.json / テーマファイル /
# COLORFGBG とキャッシュの組み合わせで決まる。そこで本スクリプトは
# ケースごとに一時の設定ディレクトリと履歴ディレクトリを作り、次を検証する:
#
#   1. theme            : theme の値 (dark / light 系、キーなし、不正な JSON など) と配色の対応
#   2. custom           : custom:<slug> は themes/<slug>.json の base に従う
#   3. colorfgbg        : theme が auto のとき COLORFGBG の最後のフィールドで決まる
#   4. os-appearance    : COLORFGBG で決まらなければ、OS の外観を見ずに dark
#   5. priority         : env / conf の dark / light は theme より優先され、theme を読まない
#   6. cache            : 変化がなければ jq を起動せず、変化があれば取り直す
#
# 配色は、ctx 75% の warning の色 (dark 255;193;7 / light 150;108;30) で判定する。
# jq と defaults は PATH 先頭のスタブで呼び出しを記録する (jq は本物に委ねる。defaults は呼ばれないことを確かめる)。

set -euo pipefail

export CLAUDE_CONFIG_DIR="/nonexistent-claude-config-dir"
export COLORFGBG=""

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
GIT_SHIM_DIR="$TESTS_DIR/lib/git-shim"
FIXTURE="$TESTS_DIR/fixtures/08-ctx-warning.json"

MACOS_SCRIPT="$REPO_DIR/statusline-macos.sh"
DEBIAN_SCRIPT="$REPO_DIR/statusline-linux.sh"

# shellcheck source=lib/find-debian-bash.sh
source "$TESTS_DIR/lib/find-debian-bash.sh"
# shellcheck source=lib/config-file.sh
source "$TESTS_DIR/lib/config-file.sh"
# shellcheck source=lib/is-macos-host.sh
source "$TESTS_DIR/lib/is-macos-host.sh"
DEBIAN_BASH="$(find_debian_bash)"
require_debian_bash_if_requested "color-scheme-behavior.sh" "$DEBIAN_BASH"
RUN_MACOS=0
is_macos_host && RUN_MACOS=1

REAL_JQ="$(command -v jq || true)"
if [ -z "$REAL_JQ" ]; then
  printf 'color-scheme-behavior.sh: jq が必要です\n' >&2
  exit 2
fi

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }

failed=0
total=0

TMP_ROOT="$(mktemp -d -t claude-statusline-color.XXXXXX)"
trap 'rm -r "$TMP_ROOT" 2>/dev/null || true' EXIT

# 呼び出しを記録するスタブ。jq は記録して本物に渡す。defaults は STUB_DEFAULTS_RC で終了する。
STUBS="$TMP_ROOT/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/jq" <<'EOF'
#!/bin/bash
printf '%s\n' "jq $*" >> "$STUB_LOG"
exec "$REAL_JQ" "$@"
EOF
cat > "$STUBS/defaults" <<'EOF'
#!/bin/bash
printf '%s\n' "defaults $*" >> "$STUB_LOG"
exit "${STUB_DEFAULTS_RC:-0}"
EOF
chmod +x "$STUBS/jq" "$STUBS/defaults"

case_no=0

# ケースごとの作業ディレクトリと、render が読む R_* を初期化する。
new_case() {
  case_no=$((case_no + 1))
  CASE_DIR="$TMP_ROOT/case-$case_no"
  mkdir -p "$CASE_DIR/cfg/themes" "$CASE_DIR/hist" "$CASE_DIR/home"
  chmod 700 "$CASE_DIR/hist"
  LOG="$CASE_DIR/calls.log"
  : > "$LOG"
  R_CFG="$CASE_DIR/cfg"
  R_HIST="$CASE_DIR/hist"
  R_HOME="$CASE_DIR/home"
  R_FGBG=""
  R_SCHEME=""
  R_CONF="$NO_CONFIG"
  R_DEFAULTS_RC=0
}

# 現在のケースの設定ディレクトリに settings.json を書く。
write_settings() { printf '%s\n' "$1" > "$R_CFG/settings.json"; }
write_theme_file() { printf '%s\n' "$2" > "$R_CFG/themes/$1.json"; }

# 古い mtime にする (キャッシュより必ず古くする)。
age() { touch -t 202001010000 "$@"; }

# statusline を 1 回実行して出力を返す。
render() {
  local bash_bin=$1 script=$2
  CLAUDE_CONFIG_DIR="$R_CFG" COLORFGBG="$R_FGBG" \
  CLAUDE_STATUSLINE_COLOR_SCHEME="$R_SCHEME" CLAUDE_STATUSLINE_CONFIG="$R_CONF" \
  CLAUDE_STATUSLINE_HISTORY_DIR="$R_HIST" HOME="$R_HOME" TZ=UTC \
  STUB_LOG="$LOG" STUB_DEFAULTS_RC="$R_DEFAULTS_RC" REAL_JQ="$REAL_JQ" \
  PATH="$GIT_SHIM_DIR:$STUBS:$PATH" \
    "$bash_bin" "$script" < "$FIXTURE" 2>/dev/null
}

# 出力の配色 (dark / light / unknown)。
scheme_of() {
  case "$1" in
    *$'\033[38;2;255;193;7m'*) printf 'dark' ;;
    *$'\033[38;2;150;108;30m'*) printf 'light' ;;
    *) printf 'unknown' ;;
  esac
}

# 記録した呼び出しのうち、固定文字列を含む行の数。
calls() { grep -cF -- "$1" "$LOG" || true; }

expect() {
  local name=$1 want=$2 got=$3
  total=$((total + 1))
  if [ "$want" = "$got" ]; then
    printf '  %s %s\n' "$(green ok)" "$name"
  else
    failed=$((failed + 1))
    printf '  %s %s\n' "$(red FAIL)" "$name" >&2
    printf '    期待: %s / 実際: %s\n' "$want" "$got" >&2
  fi
}

# render して配色を返す。
scheme() { scheme_of "$(render "$@")"; }

# --- 1. theme と配色の対応 ---
run_theme() {
  local bash_bin=$1 script=$2 label=$3 pair theme want
  for pair in 'light:light' 'light-daltonized:light' 'light-ansi:light' \
              'dark:dark' 'dark-daltonized:dark' 'dark-ansi:dark' 'unknown-theme:dark' 'Light:dark'; do
    theme=${pair%%:*}; want=${pair##*:}
    new_case
    write_settings "{\"theme\":\"$theme\"}"
    expect "theme:$theme [$label]" "$want" "$(scheme "$bash_bin" "$script")"
  done

  new_case
  write_settings '{"other":1}'
  expect "theme:key-missing [$label]" dark "$(scheme "$bash_bin" "$script")"

  new_case
  expect "theme:file-missing [$label]" dark "$(scheme "$bash_bin" "$script")"

  new_case
  printf '{not json' > "$R_CFG/settings.json"
  expect "theme:invalid-json [$label]" dark "$(scheme "$bash_bin" "$script")"

  new_case
  write_settings '{"theme":{"a":1}}'
  expect "theme:non-string [$label]" dark "$(scheme "$bash_bin" "$script")"
}

# --- 2. custom:<slug> ---
run_custom() {
  local bash_bin=$1 script=$2 label=$3 pair base want
  for pair in 'light:light' 'light-daltonized:light' 'light-ansi:light' 'dark:dark' 'dark-ansi:dark' 'weird:dark'; do
    base=${pair%%:*}; want=${pair##*:}
    new_case
    write_settings '{"theme":"custom:my-theme"}'
    write_theme_file my-theme "{\"base\":\"$base\"}"
    expect "custom:base=$base [$label]" "$want" "$(scheme "$bash_bin" "$script")"
  done

  new_case
  write_settings '{"theme":"custom:my-theme"}'
  write_theme_file my-theme '{"name":"x"}'
  expect "custom:base-missing [$label]" dark "$(scheme "$bash_bin" "$script")"

  new_case
  write_settings '{"theme":"custom:my-theme"}'
  expect "custom:file-missing [$label]" dark "$(scheme "$bash_bin" "$script")"

  new_case
  write_settings '{"theme":"custom:my-theme"}'
  printf '{not json' > "$R_CFG/themes/my-theme.json"
  expect "custom:invalid-json [$label]" dark "$(scheme "$bash_bin" "$script")"

  # slug に / を含むときはファイルを読まない (読めば light になる位置にファイルを置く)。
  new_case
  mkdir -p "$R_CFG/themes/sub"
  write_settings '{"theme":"custom:sub/x"}'
  printf '{"base":"light"}\n' > "$R_CFG/themes/sub/x.json"
  expect "custom:slash-dark [$label]" dark "$(scheme "$bash_bin" "$script")"
  expect "custom:slash-not-read [$label]" 0 "$(calls '.base // empty')"
}

# --- 3. COLORFGBG ---
run_colorfgbg() {
  local bash_bin=$1 script=$2 label=$3 pair fgbg want
  for pair in '0;15:light' '15;0:dark' '15;default;0:dark' '0;default;15:light' '0;7:light' '0;9:light' '15;8:dark' '0;10:light'; do
    fgbg=${pair%%:*}; want=${pair##*:}
    new_case
    write_settings '{"theme":"auto"}'
    R_FGBG=$fgbg
    expect "colorfgbg:$fgbg [$label]" "$want" "$(scheme "$bash_bin" "$script")"
  done

  # 数字でない最後のフィールドは決まらない扱い。default を 0 と評価して dark にしない。
  new_case
  write_settings '{"theme":"auto"}'
  R_FGBG='0;default'
  R_DEFAULTS_RC=1
  expect "colorfgbg:non-numeric-falls-through [$label]" dark "$(scheme "$bash_bin" "$script")"

  # theme が auto でなければ COLORFGBG は見ない。
  new_case
  write_settings '{"theme":"dark"}'
  R_FGBG='0;15'
  expect "colorfgbg:ignored-for-explicit-theme [$label]" dark "$(scheme "$bash_bin" "$script")"

  # COLORFGBG はキャッシュしない。セッションごとの値で毎回変わる。
  new_case
  write_settings '{"theme":"auto"}'
  age "$R_CFG/settings.json"
  R_FGBG='0;15'
  expect "colorfgbg:first [$label]" light "$(scheme "$bash_bin" "$script")"
  R_FGBG='15;0'
  expect "colorfgbg:not-cached [$label]" dark "$(scheme "$bash_bin" "$script")"
}

# --- 4. OS の外観を見ない ---
# OS の外観は端末のテーマと一致するとは限らないので、COLORFGBG で決まらなければ OS がライトでも dark。
# defaults のスタブはライトモード (失敗) を返す。
run_os_appearance() {
  local bash_bin=$1 script=$2 label=$3

  new_case
  write_settings '{"theme":"auto"}'
  R_DEFAULTS_RC=1
  expect "os:light-os-still-dark [$label]" dark "$(scheme "$bash_bin" "$script")"
  expect "os:defaults-not-called [$label]" 0 "$(calls 'defaults')"

  # 前回が COLORFGBG で決まっていても、次に COLORFGBG がなければ dark。
  new_case
  write_settings '{"theme":"auto"}'
  age "$R_CFG/settings.json"
  R_DEFAULTS_RC=1
  R_FGBG='0;15'
  expect "os:colorfgbg-first [$label]" light "$(scheme "$bash_bin" "$script")"
  R_FGBG=''
  expect "os:no-colorfgbg-dark [$label]" dark "$(scheme "$bash_bin" "$script")"
  expect "os:no-colorfgbg-cached [$label]" 1 "$(calls '.theme // empty')"
  expect "os:no-colorfgbg-defaults-not-called [$label]" 0 "$(calls 'defaults')"
}

# --- 5. env / conf の優先 ---
run_priority() {
  local bash_bin=$1 script=$2 label=$3

  new_case
  write_settings '{"theme":"dark"}'
  R_SCHEME=light
  expect "priority:env-light-over-theme [$label]" light "$(scheme "$bash_bin" "$script")"
  expect "priority:env-light-theme-not-read [$label]" 0 "$(calls '.theme // empty')"

  new_case
  write_settings '{"theme":"light"}'
  R_SCHEME=dark
  expect "priority:env-dark-over-theme [$label]" dark "$(scheme "$bash_bin" "$script")"
  expect "priority:env-dark-theme-not-read [$label]" 0 "$(calls '.theme // empty')"

  new_case
  write_settings '{"theme":"light"}'
  printf 'COLOR_SCHEME=dark\n' > "$CASE_DIR/conf"
  R_CONF="$CASE_DIR/conf"
  expect "priority:conf-dark-over-theme [$label]" dark "$(scheme "$bash_bin" "$script")"

  new_case
  write_settings '{"theme":"dark"}'
  printf 'COLOR_SCHEME=light\n' > "$CASE_DIR/conf"
  R_CONF="$CASE_DIR/conf"
  expect "priority:conf-light-over-theme [$label]" light "$(scheme "$bash_bin" "$script")"

  new_case
  write_settings '{"theme":"dark"}'
  printf 'COLOR_SCHEME=light\n' > "$CASE_DIR/conf"
  R_CONF="$CASE_DIR/conf"
  R_SCHEME=dark
  expect "priority:env-over-conf [$label]" dark "$(scheme "$bash_bin" "$script")"

  new_case
  write_settings '{"theme":"light"}'
  printf 'COLOR_SCHEME=auto\n' > "$CASE_DIR/conf"
  R_CONF="$CASE_DIR/conf"
  expect "priority:conf-auto-follows-theme [$label]" light "$(scheme "$bash_bin" "$script")"

  # 未知の値は従来どおり dark。auto にはならない。
  new_case
  write_settings '{"theme":"light"}'
  R_SCHEME=solarized
  expect "priority:unknown-value-dark [$label]" dark "$(scheme "$bash_bin" "$script")"
  expect "priority:unknown-value-theme-not-read [$label]" 0 "$(calls '.theme // empty')"
}

# --- 6. キャッシュ ---
run_cache() {
  local bash_bin=$1 script=$2 label=$3 dir_a dir_b

  new_case
  write_settings '{"theme":"light"}'
  age "$R_CFG/settings.json"
  expect "cache:first [$label]" light "$(scheme "$bash_bin" "$script")"
  expect "cache:first-reads-theme [$label]" 1 "$(calls '.theme // empty')"
  expect "cache:second [$label]" light "$(scheme "$bash_bin" "$script")"
  expect "cache:second-no-jq [$label]" 1 "$(calls '.theme // empty')"
  expect "cache:third-no-jq [$label]" light "$(scheme "$bash_bin" "$script")"
  expect "cache:third-calls [$label]" 1 "$(calls '.theme // empty')"
  expect "cache:file-written [$label]" yes "$([ -f "$R_HIST/color-scheme" ] && printf yes || printf no)"

  # settings.json を書き換えたら次の描画で取り直す。キャッシュと同じ秒の書き換えでも取りこぼさない。
  write_settings '{"theme":"dark"}'
  expect "cache:settings-rewritten-same-second [$label]" dark "$(scheme "$bash_bin" "$script")"
  expect "cache:settings-rewritten-calls [$label]" 2 "$(calls '.theme // empty')"

  # custom テーマのファイルを書き換えたら取り直す。
  new_case
  write_settings '{"theme":"custom:my-theme"}'
  write_theme_file my-theme '{"base":"light"}'
  age "$R_CFG/settings.json" "$R_CFG/themes/my-theme.json"
  expect "cache:custom-first [$label]" light "$(scheme "$bash_bin" "$script")"
  expect "cache:custom-second [$label]" light "$(scheme "$bash_bin" "$script")"
  expect "cache:custom-no-reread [$label]" 1 "$(calls '.base // empty')"
  write_theme_file my-theme '{"base":"dark"}'
  expect "cache:custom-rewritten [$label]" dark "$(scheme "$bash_bin" "$script")"
  expect "cache:custom-rewritten-calls [$label]" 2 "$(calls '.base // empty')"

  # テーマファイルが消えたら取り直す (base を失って dark)。
  new_case
  write_settings '{"theme":"custom:my-theme"}'
  write_theme_file my-theme '{"base":"light"}'
  age "$R_CFG/settings.json" "$R_CFG/themes/my-theme.json"
  expect "cache:custom-before-delete [$label]" light "$(scheme "$bash_bin" "$script")"
  rm "$R_CFG/themes/my-theme.json"
  expect "cache:custom-file-deleted [$label]" dark "$(scheme "$bash_bin" "$script")"

  # settings.json が消えたら取り直す。
  new_case
  write_settings '{"theme":"light"}'
  age "$R_CFG/settings.json"
  expect "cache:before-settings-deleted [$label]" light "$(scheme "$bash_bin" "$script")"
  rm "$R_CFG/settings.json"
  expect "cache:settings-deleted [$label]" dark "$(scheme "$bash_bin" "$script")"

  # settings.json が後から現れたら取り直す。
  new_case
  expect "cache:before-settings-created [$label]" dark "$(scheme "$bash_bin" "$script")"
  write_settings '{"theme":"light"}'
  expect "cache:settings-created [$label]" light "$(scheme "$bash_bin" "$script")"

  # CLAUDE_CONFIG_DIR の異なるセッションが履歴ディレクトリを共有しても、判定結果を取り違えない。
  new_case
  dir_a="$CASE_DIR/cfg-a"; dir_b="$CASE_DIR/cfg-b"
  mkdir -p "$dir_a" "$dir_b"
  printf '{"theme":"light"}\n' > "$dir_a/settings.json"
  printf '{"theme":"dark"}\n' > "$dir_b/settings.json"
  age "$dir_a/settings.json" "$dir_b/settings.json"
  R_CFG="$dir_a"
  expect "cache:config-dir-a [$label]" light "$(scheme "$bash_bin" "$script")"
  R_CFG="$dir_b"
  expect "cache:config-dir-b [$label]" dark "$(scheme "$bash_bin" "$script")"
  R_CFG="$dir_a"
  expect "cache:config-dir-a-again [$label]" light "$(scheme "$bash_bin" "$script")"

  # キャッシュが壊れていても取り直して描画を続ける。
  new_case
  write_settings '{"theme":"light"}'
  age "$R_CFG/settings.json"
  printf 'garbage\n' > "$R_HIST/color-scheme"
  expect "cache:corrupted [$label]" light "$(scheme "$bash_bin" "$script")"

  # HISTORY_DIR が無効 (symlink) でもテーマに従って描画できる。キャッシュは作らない。
  new_case
  write_settings '{"theme":"light"}'
  ln -s "$R_HIST" "$CASE_DIR/hist.link"
  R_HIST="$CASE_DIR/hist.link"
  expect "cache:history-disabled [$label]" light "$(scheme "$bash_bin" "$script")"
  expect "cache:history-disabled-no-file [$label]" no "$([ -e "$CASE_DIR/hist/color-scheme" ] && printf yes || printf no)"
}

run_variant() {
  local bash_bin=$1 script=$2 label=$3
  printf '[%s]\n' "$label"
  run_theme "$bash_bin" "$script" "$label"
  run_custom "$bash_bin" "$script" "$label"
  run_colorfgbg "$bash_bin" "$script" "$label"
  run_os_appearance "$bash_bin" "$script" "$label"
  run_priority "$bash_bin" "$script" "$label"
  run_cache "$bash_bin" "$script" "$label"
}

main() {
  local skipped=""
  if [ "$RUN_MACOS" = 1 ]; then
    MACOS_BASH="$(command -v bash)"
    run_variant "$MACOS_BASH" "$MACOS_SCRIPT" macOS
  else
    skipped="$skipped macOS"
  fi
  if [ -n "$DEBIAN_BASH" ]; then
    run_variant "$DEBIAN_BASH" "$DEBIAN_SCRIPT" Linux
  else
    skipped="$skipped Linux"
  fi

  printf '\n'
  if [ "$failed" -eq 0 ]; then
    printf '%s: %d/%d passed%s\n' "$(green PASS)" "$total" "$total" "${skipped:+ (skipped:$skipped)}"
  else
    printf '%s: %d/%d failed\n' "$(red FAIL)" "$failed" "$total" >&2
    exit 1
  fi
}

main "$@"
