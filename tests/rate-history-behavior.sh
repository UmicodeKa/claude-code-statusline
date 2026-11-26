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
#   poll-max-default           : 既定のチャート長 (12) では上限が 1500
#   poll-clamp-zero            : POLL_INTERVAL_SEC=0 は下限 60 に丸められる
#   poll-invalid-default       : POLL_INTERVAL_SEC=abc は既定 300 に戻る
#
# rate-now (全セッションで観測した最小の残量。1 行 `<残量> <resets_at>`) を使った採用値の決定:
#
#   stale-higher-ignored       : 同じ窓の残量の多い入力は、rate-now の少ない値で描き、rate-now を変えない
#   lower-updates-now          : 同じ窓の残量の少ない入力で rate-now を書き換える
#   jitter-same-window         : resets_at が 60 秒ずれても同じ窓として扱う
#   jitter-lower-keeps-reset   : 同じ窓で書き換えるときは resets_at を保存値のまま残す
#   new-window-accepts-higher  : resets_at が窓の長さぶん進んだら、残量の回復をすぐ表示する
#   older-window-input         : 保存値より古い窓の入力は表示にだけ使い、rate-now も履歴も書かない
#   future-reset-recovers      : rate-now の resets_at が窓の長さより先なら置き換える
#   missing-reset              : resets_at の欠落した入力は表示にだけ使い、rate-now も履歴も書かない
#   missing-reset-expired-now  : rate-now の窓が終わっていれば、resets_at の欠落した入力も履歴に書く
#   missing-reset-no-now       : rate-now が無ければ resets_at の欠落した入力も履歴に書く (rate-now は作らない)
#   corrupt-now                : 読めない rate-now (小数、CRLF、値の過不足、算術式で評価される値) でも
#                                描画を崩さず、入力で置き換える
#   history-records-adopted    : 履歴に追記するのは採用値
#   no-extra-commands          : rate-now を書き換えない描画では、外部コマンドの起動が増えない
#
# conf は一時ファイルに書いて CLAUDE_STATUSLINE_CONFIG で渡し、開発者の ~/.claude/statusline.conf は
# 読ませない。開発者のシェルの環境変数は sl_run (lib/statusline-env.sh) が捨てるので、結果は変わらない。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"

MACOS_SCRIPT="$REPO_DIR/statusline-macos.sh"
DEBIAN_SCRIPT="$REPO_DIR/statusline-linux.sh"

# shellcheck source=lib/find-debian-bash.sh
source "$TESTS_DIR/lib/find-debian-bash.sh"
# statusline は sl_run で起動する (許可リスト方式の起動環境。GIT_FETCH / PR_STATUS は 0)。
# shellcheck source=lib/statusline-env.sh
source "$TESTS_DIR/lib/statusline-env.sh"
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

# shellcheck disable=SC2329 # 各ケースの RETURN の trap の文字列から呼ぶ
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
    | sl_run \
      CLAUDE_STATUSLINE_HISTORY_DIR="$hist" \
      CLAUDE_STATUSLINE_CONFIG="$config" \
      -- "$bash_bin" "$script" >/dev/null 2>&1
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

# --- throttle: 間隔 (既定 300 秒) 内の描画では追記しない ---
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

# --- poll-max-default: 既定のチャート長 (12) では上限 18000 / 12 = 1500 ---
case_poll_max_default() {
  local bash_bin=$1 script=$2 label=$3
  setup_case 'POLL_INTERVAL_SEC=99999'
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_history "$STORAGE_LEN" 1400
  run_sl "$bash_bin" "$script"
  expect_append "poll-max-default:1400s [$label]" skipped "上限 1500 より短い 1400 秒で追記した"

  seed_history "$STORAGE_LEN" 1600
  run_sl "$bash_bin" "$script"
  expect_append "poll-max-default:1600s [$label]" appended "上限 1500 を過ぎた 1600 秒で追記しなかった"
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

# --- poll-invalid-default: POLL_INTERVAL_SEC=abc は既定 300 に戻る ---
case_poll_invalid_default() {
  local bash_bin=$1 script=$2 label=$3
  setup_case 'POLL_INTERVAL_SEC=abc'
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_history "$STORAGE_LEN" 250
  run_sl "$bash_bin" "$script"
  expect_append "poll-invalid-default:250s [$label]" skipped "既定 300 より短い 250 秒で追記した"

  seed_history "$STORAGE_LEN" 350
  run_sl "$bash_bin" "$script"
  expect_append "poll-invalid-default:350s [$label]" appended "既定 300 を過ぎた 350 秒で追記しなかった"
}

# ===== rate-now (全セッションで観測した最小の残量) =====
#
# 待機中のセッションが持つ古い (残量が多い) 値でチャートと NN% が戻らないことを、rate-now と履歴の
# 中身、描画の出力で確かめる。期待する出力は、採用値を入力にした描画を別の履歴ディレクトリで作って比べる
# (チャート、NN%、色、時刻をまとめて比べられる)。残量の多い値と少ない値は、色と NN% が付くかで
# 見分けられるよう、40% 超 (HIGH) と 40% 以下 (LOW) にする。
HIGH=77
LOW=30

# 描画する。出力は out に、標準エラーは err に入れる。
#   $1 bash / $2 script / $3 残量 / $4 resets_at (空なら JSON に含めない) / $5 履歴ディレクトリ (省略時は hist)
#   $6 PATH に足すディレクトリ (省略可)
render() {
  local bash_bin=$1 script=$2 remaining=$3 reset=$4 dir=${5:-$hist} extra=${6:-} json errfile
  # bash 3.2 の set -u は空の配列の展開をエラーにするので、要素があるときだけ展開する。
  local -a path_opt=()
  [ -n "$extra" ] && path_opt=(--path "$extra")
  if [ -n "$reset" ]; then
    json=$(printf '{"rate_limits":{"five_hour":{"used_percentage":%d,"resets_at":%s}}}' "$((100 - remaining))" "$reset")
  else
    json=$(printf '{"rate_limits":{"five_hour":{"used_percentage":%d}}}' "$((100 - remaining))")
  fi
  errfile="$case_dir/stderr"
  out=$(printf '%s' "$json" | sl_run ${path_opt[@]+"${path_opt[@]}"} \
    CLAUDE_STATUSLINE_HISTORY_DIR="$dir" \
    CLAUDE_STATUSLINE_CONFIG="$config" \
    -- "$bash_bin" "$script" 2>"$errfile") || true
  err=$(cat "$errfile")
}

# 採用値を入力にした描画を、別の履歴ディレクトリで作って ref に入れる。
#   $1 bash / $2 script / $3 残量 / $4 resets_at / $5 seed (none: 空の履歴 / old: 古い値 20 行を間隔内に置く)
render_ref() {
  local bash_bin=$1 script=$2 remaining=$3 reset=$4 seed=$5 ref_dir="$case_dir/ref" i
  mkdir "$ref_dir"
  chmod 700 "$ref_dir"
  if [ "$seed" = old ]; then
    for ((i = 0; i < STORAGE_LEN; i++)); do
      printf '%s\n' "$OLD_VALUE"
    done > "$ref_dir/rate"
  fi
  render "$bash_bin" "$script" "$remaining" "$reset" "$ref_dir"
  ref=$out
  rm -r "$ref_dir"
}

now_file() { printf '%s' "$hist/rate-now"; }
now_content() { if [ -e "$(now_file)" ]; then cat "$(now_file)"; else printf '(none)'; fi; }

# rate-now の中身、出力、標準エラーをまとめて確かめる。
#   $1 ケース名 / $2 期待する rate-now ((none) は無いこと) / $3 期待する出力 / $4 失敗時の説明
expect_now_and_output() {
  local name=$1 want_now=$2 want_out=$3 detail=$4 got_now
  got_now=$(now_content)
  if [ -n "$err" ]; then
    fail_case "$name" "${detail}: 標準エラーに出力があった: $err"
  elif [ "$got_now" != "$want_now" ]; then
    fail_case "$name" "${detail}: rate-now が '${got_now}' (期待 '${want_now}')"
  elif [ "$out" != "$want_out" ]; then
    fail_case "$name" "${detail}: 出力が '${out}' (期待 '${want_out}')"
  else
    pass_case "$name"
  fi
}

# 入力の resets_at に使う将来の epoch。
future_reset() { printf '%s' "$(( $(date +%s) + 3600 ))"; }

# --- stale-higher-ignored: 同じ窓の残量の多い入力は、rate-now の少ない値で描く ---
case_stale_higher_ignored() {
  local bash_bin=$1 script=$2 label=$3 r
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN
  r=$(future_reset)

  printf '%s %s\n' "$LOW" "$r" > "$(now_file)"
  render "$bash_bin" "$script" "$HIGH" "$r"
  local got=$out got_err=$err
  render_ref "$bash_bin" "$script" "$LOW" "$r" none
  out=$got err=$got_err
  expect_now_and_output "stale-higher-ignored [$label]" "$LOW $r" "$ref" "古い ${HIGH} で表示が戻った"
}

# --- lower-updates-now: 同じ窓の残量の少ない入力で rate-now を書き換える ---
case_lower_updates_now() {
  local bash_bin=$1 script=$2 label=$3 r
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN
  r=$(future_reset)

  printf '%s %s\n' "$HIGH" "$r" > "$(now_file)"
  render "$bash_bin" "$script" "$LOW" "$r"
  local got=$out got_err=$err
  render_ref "$bash_bin" "$script" "$LOW" "$r" none
  out=$got err=$got_err
  expect_now_and_output "lower-updates-now [$label]" "$LOW $r" "$ref" "減った ${LOW} を記録しなかった"
}

# --- jitter-same-window: resets_at が 60 秒ずれても同じ窓として扱う ---
case_jitter_same_window() {
  local bash_bin=$1 script=$2 label=$3 r
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN
  r=$(future_reset)

  printf '%s %s\n' "$LOW" "$r" > "$(now_file)"
  render "$bash_bin" "$script" "$HIGH" "$((r + 60))"
  local got=$out got_err=$err
  render_ref "$bash_bin" "$script" "$LOW" "$((r + 60))" none
  out=$got err=$got_err
  expect_now_and_output "jitter-same-window [$label]" "$LOW $r" "$ref" "60 秒ずれた入力を別の窓として扱った"
}

# --- jitter-lower-keeps-reset: 同じ窓で書き換えるときは resets_at を保存値のまま残す ---
case_jitter_lower_keeps_reset() {
  local bash_bin=$1 script=$2 label=$3 r
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN
  r=$(future_reset)

  printf '%s %s\n' "$HIGH" "$r" > "$(now_file)"
  render "$bash_bin" "$script" "$LOW" "$((r + 60))"
  local got=$out got_err=$err
  render_ref "$bash_bin" "$script" "$LOW" "$((r + 60))" none
  out=$got err=$got_err
  expect_now_and_output "jitter-lower-keeps-reset [$label]" "$LOW $r" "$ref" "resets_at の基点が動いた"
}

# --- new-window-accepts-higher: resets_at が窓の長さぶん進んだら、回復をすぐ表示する ---
case_new_window_accepts_higher() {
  local bash_bin=$1 script=$2 label=$3 r
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN
  r=$(future_reset)

  printf '10 %s\n' "$r" > "$(now_file)"
  render "$bash_bin" "$script" 95 "$((r + 18000))"
  local got=$out got_err=$err
  render_ref "$bash_bin" "$script" 95 "$((r + 18000))" none
  out=$got err=$got_err
  expect_now_and_output "new-window-accepts-higher [$label]" "95 $((r + 18000))" "$ref" "新しい窓の回復を表示しなかった"
}

# --- older-window-input: 保存値より古い窓の入力は自分の表示にだけ使い、rate-now も履歴も書かない ---
case_older_window_input() {
  local bash_bin=$1 script=$2 label=$3 r
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN
  r=$(future_reset)

  printf '%s %s\n' "$OLD_VALUE" "$r" > "$(now_file)"
  seed_history "$STORAGE_LEN" 500
  render "$bash_bin" "$script" "$NEW_REMAINING" "$((r - 18000))"
  local got=$out got_err=$err
  render_ref "$bash_bin" "$script" "$NEW_REMAINING" "$((r - 18000))" old
  out=$got err=$got_err
  if [ "$(line_count)" != "$STORAGE_LEN" ] || [ "$(last_line)" != "$OLD_VALUE" ]; then
    fail_case "older-window-input [$label]" "古い窓の入力を履歴に書いた ($(line_count) 行、末尾 $(last_line))"
  else
    expect_now_and_output "older-window-input [$label]" "$OLD_VALUE $r" "$ref" "古い窓の入力の扱いが違う"
  fi
}

# --- future-reset-recovers: rate-now の resets_at が窓の長さより先なら、壊れた値として置き換える ---
case_future_reset_recovers() {
  local bash_bin=$1 script=$2 label=$3 r
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN
  r=$(future_reset)

  printf '%s 9999999999\n' "$LOW" > "$(now_file)"
  render "$bash_bin" "$script" "$HIGH" "$r"
  local got=$out got_err=$err
  render_ref "$bash_bin" "$script" "$HIGH" "$r" none
  out=$got err=$got_err
  expect_now_and_output "future-reset-recovers [$label]" "$HIGH $r" "$ref" "先の窓を指す rate-now から戻らなかった"
}

# --- missing-reset: resets_at の欠落した入力は自分の表示にだけ使い、rate-now も履歴も書かない ---
case_missing_reset() {
  local bash_bin=$1 script=$2 label=$3 r
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN
  r=$(future_reset)

  printf '%s %s\n' "$LOW" "$r" > "$(now_file)"
  seed_history "$STORAGE_LEN" 500
  render "$bash_bin" "$script" "$HIGH" ""
  local got=$out got_err=$err
  render_ref "$bash_bin" "$script" "$HIGH" "" old
  out=$got err=$got_err
  if [ "$(line_count)" != "$STORAGE_LEN" ] || [ "$(last_line)" != "$OLD_VALUE" ]; then
    fail_case "missing-reset [$label]" "resets_at の欠落した入力を履歴に書いた ($(line_count) 行、末尾 $(last_line))"
  else
    expect_now_and_output "missing-reset [$label]" "$LOW $r" "$ref" "resets_at の欠落した入力の扱いが違う"
  fi
}

# --- missing-reset-expired-now: rate-now の窓が終わっていれば、resets_at の欠落した入力も履歴に書く ---
# 欠落した入力だけが続いたときに、終わった窓の rate-now が履歴の追記を止め続けないことを確かめる。
case_missing_reset_expired_now() {
  local bash_bin=$1 script=$2 label=$3 past
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN
  past=$(( $(date +%s) - 60 ))

  printf '%s %s\n' "$LOW" "$past" > "$(now_file)"
  seed_history "$STORAGE_LEN" 500
  render "$bash_bin" "$script" "$HIGH" ""
  if [ "$(line_count)" = "$STORAGE_LEN" ] && [ "$(last_line)" = "$HIGH" ] && [ "$(now_content)" = "$LOW $past" ] && [ -z "$err" ]; then
    pass_case "missing-reset-expired-now [$label]"
  else
    fail_case "missing-reset-expired-now [$label]" \
      "履歴の末尾が $(last_line) (期待 ${HIGH})、rate-now が '$(now_content)' (期待 '$LOW $past')、標準エラー '$err'"
  fi
}

# --- missing-reset-no-now: rate-now が無ければ、resets_at の欠落した入力も履歴に書く (rate-now は作らない) ---
case_missing_reset_no_now() {
  local bash_bin=$1 script=$2 label=$3
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN

  render "$bash_bin" "$script" "$HIGH" ""
  local got=$out got_err=$err
  render_ref "$bash_bin" "$script" "$HIGH" "" none
  out=$got err=$got_err
  if [ "$(line_count)" != "$STORAGE_LEN" ] || [ "$(sort -u "$rate_file")" != "$HIGH" ]; then
    fail_case "missing-reset-no-now [$label]" "履歴に ${HIGH} を ${STORAGE_LEN} 行書かなかった ($(line_count) 行)"
  else
    expect_now_and_output "missing-reset-no-now [$label]" "(none)" "$ref" "rate-now の扱いが違う"
  fi
}

# --- corrupt-now: 読めない rate-now でも描画を崩さず、入力で置き換える ---
# 算術式に渡すと評価される値 (配列の添字のコマンド置換) も含め、検査の前に評価しないことを確かめる。
case_corrupt_now() {
  local bash_bin=$1 script=$2 label=$3 r content name
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN
  r=$(future_reset)
  local pwned="$case_dir/pwned"
  local -a contents=(
    "$LOW 17000.5"
    "a b"
    "$LOW $r"$'\r'
    "$LOW"
    "$LOW $r extra"
    "x[\$(touch $pwned)] $r"
    "$LOW x[\$(touch $pwned)]"
    ""
  )
  render_ref "$bash_bin" "$script" "$HIGH" "$r" none
  local i=0
  for content in "${contents[@]}"; do
    i=$((i + 1))
    name="corrupt-now:$i [$label]"
    rm -- "$rate_file" "$(now_file)" 2>/dev/null || true
    printf '%s\n' "$content" > "$(now_file)"
    render "$bash_bin" "$script" "$HIGH" "$r"
    if [ -e "$pwned" ]; then
      fail_case "$name" "rate-now の値 '$content' を算術式で評価した"
      rm -- "$pwned"
    else
      expect_now_and_output "$name" "$HIGH $r" "$ref" "rate-now '$content' を読めないものとして扱わなかった"
    fi
  done
}

# --- history-records-adopted: 履歴に追記するのは採用値 (入力ではない) ---
case_history_records_adopted() {
  local bash_bin=$1 script=$2 label=$3 r
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN
  r=$(future_reset)

  printf '%s %s\n' "$LOW" "$r" > "$(now_file)"
  seed_history "$STORAGE_LEN" 500
  render "$bash_bin" "$script" "$HIGH" "$r"
  if [ "$(line_count)" = "$STORAGE_LEN" ] && [ "$(last_line)" = "$LOW" ] && [ "$(now_content)" = "$LOW $r" ]; then
    pass_case "history-records-adopted [$label]"
  else
    fail_case "history-records-adopted [$label]" \
      "履歴の末尾が $(last_line) (期待 ${LOW})、rate-now が '$(now_content)'"
  fi
}

# --- no-extra-commands: rate-now を書き換えない描画では、外部コマンドの起動が増えない ---
# 主な外部コマンドを、呼ばれた名前を記録してから本物を exec するラッパーで隠して数える。基準は、
# 残量が整数でない (使用率が 100 を超えた) ために rate-now を読まずに追記の判定へ進む描画。
# ロックを取るコマンド (macOS 版は mkdir、Linux 版は flock) も数えるので、ロックを 2 回取ると増える。
case_no_extra_commands() {
  local bash_bin=$1 script=$2 label=$3 r cmd real
  setup_case ""
  trap 'cleanup_case; trap - RETURN' RETURN
  r=$(future_reset)
  local bin="$case_dir/count-bin" log="$case_dir/commands.log"
  mkdir "$bin"
  for cmd in date stat mkdir rmdir mv mktemp rm cat touch sleep id uname awk tail chmod jq flock; do
    real=$(command -v "$cmd" 2>/dev/null) || continue
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexec "%s" "$@"\n' "$cmd" "$log" "$real" > "$bin/$cmd"
    chmod +x "$bin/$cmd"
  done
  # $1 残量 → 描画した外部コマンドの起動回数を count に入れる
  count_render() {
    : > "$log"
    render "$bash_bin" "$script" "$1" "$r" "$hist" "$bin"
    count=$(wc -l < "$log" | tr -d ' ')
  }

  seed_history "$STORAGE_LEN" 10
  local count base same lower_kept
  # 初回の描画はカラースキームの判定のキャッシュを書く (jq と mv が増える) ので、数えずに済ませる。
  count_render -1
  count_render -1
  base=$count
  printf '%s %s\n' "$LOW" "$r" > "$(now_file)"
  count_render "$HIGH"
  same=$count
  count_render "$LOW"
  lower_kept=$count
  if [ "$(now_content)" != "$LOW $r" ]; then
    fail_case "no-extra-commands [$label]" "前提が崩れている: rate-now が '$(now_content)'"
  elif [ "$same" = "$base" ] && [ "$lower_kept" = "$base" ]; then
    pass_case "no-extra-commands [$label] (${base} commands)"
  else
    fail_case "no-extra-commands [$label]" \
      "外部コマンドの起動が増えた: 基準 ${base} 回、残量の多い入力 ${same} 回、同じ残量の入力 ${lower_kept} 回"
  fi
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
  case_stale_higher_ignored       "$bash_bin" "$script" "$label"
  case_lower_updates_now          "$bash_bin" "$script" "$label"
  case_jitter_same_window         "$bash_bin" "$script" "$label"
  case_jitter_lower_keeps_reset   "$bash_bin" "$script" "$label"
  case_new_window_accepts_higher  "$bash_bin" "$script" "$label"
  case_older_window_input         "$bash_bin" "$script" "$label"
  case_future_reset_recovers      "$bash_bin" "$script" "$label"
  case_missing_reset              "$bash_bin" "$script" "$label"
  case_missing_reset_expired_now  "$bash_bin" "$script" "$label"
  case_missing_reset_no_now       "$bash_bin" "$script" "$label"
  case_corrupt_now                "$bash_bin" "$script" "$label"
  case_history_records_adopted    "$bash_bin" "$script" "$label"
  case_no_extra_commands          "$bash_bin" "$script" "$label"
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
