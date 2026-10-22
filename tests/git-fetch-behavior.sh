#!/usr/bin/env bash
# maybe_git_fetch (バックグラウンド git fetch) の挙動テスト。
#
# regression.sh が検証するのは「描画された文字列」だけで、fetch は投げっぱなしの
# 非同期処理なので出力に現れない。そこで本スクリプトは fake git に仕込んだフック
# (STATUSLINE_TEST_FETCH_SLEEP / STATUSLINE_TEST_FETCH_SENTINEL) を使い、
# 出力では観測できない次の不変条件を検証する:
#
#   1. fetch-invoked : fetch が実際に exec される (リダイレクトが fetch 自体を壊していない)
#   2. non-blocking  : 遅い fetch でも描画は待たない (fd 付け替え (stdin/stdout/stderr) 3 点セットの回帰ガード)
#   3. throttle      : GIT_FETCH_INTERVAL_SEC 未満の連続呼び出しでは fetch を投げない
#   4. lock-released : fetch 完走までロックが保持されない (marker -> unlock -> spawn の順序)
#   5. marker-unwritable : マーカーを書けないときは fetch を投げない (間引き無効化の防止)
#   6. clamp-zero-interval : GIT_FETCH_INTERVAL_SEC=0 でも clamp が下限 60 へ丸めて間引きが効く
#
# 実ネットワークには一切出ない (PATH 先頭の fake git が fetch を受ける)。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
GIT_SHIM_DIR="$TESTS_DIR/lib/git-shim"

# upstream あり (ab=2,0) の fixture。maybe_git_fetch が fetch を投げる正常系。
FIXTURE="$TESTS_DIR/fixtures/67-git-fetch-ahead.json"

MACOS_SCRIPT="$REPO_DIR/statusline-macos.sh"
DEBIAN_SCRIPT="$REPO_DIR/statusline-linux.sh"

# shellcheck source=lib/find-debian-bash.sh
source "$TESTS_DIR/lib/find-debian-bash.sh"
# shellcheck source=lib/config-file.sh
source "$TESTS_DIR/lib/config-file.sh"
# shellcheck source=lib/is-macos-host.sh
source "$TESTS_DIR/lib/is-macos-host.sh"
DEBIAN_BASH="$(find_debian_bash)"
# macOS 版は BSD 系コマンド前提。macOS ホストでなければ macOS 分のケースを skip する。
RUN_MACOS=0
is_macos_host && RUN_MACOS=1

# 遅い fetch の待ち時間 (秒)。非ブロッキング検証で「描画がこれを待たない」ことを見る。
SLOW_FETCH_SEC=5
# 描画の所要時間の上限 (秒)。statusline 自体は 1 秒程度で返るので、遅い fetch を
# 待ってしまえば必ず超える。CI の遅さを吸収しつつ SLOW_FETCH_SEC とは十分離す。
MAX_RENDER_SEC=3

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }

failed=0
total=0

pass_case() { printf '  %s %s\n' "$(green ok)" "$1"; }
fail_case() {
  printf '  %s %s\n' "$(red FAIL)" "$1" >&2
  printf '    %s\n' "$2" >&2
  failed=$((failed + 1))
}

# statusline を 1 回実行する。stdout は捨てる (本テストは描画内容を見ない)。
# 引数: $1 bash 実行ファイル / $2 スクリプト / $3 履歴 dir / $4 sentinel / $5 fetch の sleep 秒
#       $6 設定ファイル (省略時は存在しないパス = conf 無し)
run_statusline() {
  local bash_bin=$1 script=$2 hist=$3 sentinel=$4 sleep_sec=$5 config=${6:-$NO_CONFIG}
  CLAUDE_STATUSLINE_HISTORY_DIR="$hist" TZ=UTC \
  CLAUDE_STATUSLINE_CONFIG="$config" \
  CLAUDE_STATUSLINE_GIT_FETCH=1 \
  STATUSLINE_TEST_FETCH_SLEEP="$sleep_sec" \
  STATUSLINE_TEST_FETCH_SENTINEL="$sentinel" \
  PATH="$GIT_SHIM_DIR:$PATH" \
    "$bash_bin" "$script" < "$FIXTURE" >/dev/null 2>&1
}

# sentinel に最低 1 行書かれるまで最大 $2 秒待つ。書かれたら 0、時間切れなら 1。
wait_for_sentinel() {
  local sentinel=$1 timeout_sec=$2
  local attempts=$((timeout_sec * 10))
  local i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -s "$sentinel" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# fetch のロックファイル / ロック dir を glob で 1 件取り出す (無ければ空)。
find_lock() {
  local hist=$1 suffix=$2
  local path
  for path in "$hist"/fetch-*"$suffix"; do
    [ -e "$path" ] && { printf '%s' "$path"; return; }
  done
  printf ''
}

# --- 1. fetch が実際に exec される ---
# 投げっぱなし子プロセスの stdout/stderr/stdin 付け替えが fetch 自体を殺していないこと。
case_fetch_invoked() {
  local bash_bin=$1 script=$2 label=$3
  local hist sentinel
  hist="$(mktemp -d -t claude-statusline-fetch.XXXXXX)"
  sentinel="${hist}.sentinel"
  : > "$sentinel"
  # shellcheck disable=SC2064
  trap "rm -r '$hist' 2>/dev/null || true; rm '$sentinel' 2>/dev/null || true" RETURN

  run_statusline "$bash_bin" "$script" "$hist" "$sentinel" 0

  if wait_for_sentinel "$sentinel" 3; then
    pass_case "fetch-invoked [$label]"
  else
    fail_case "fetch-invoked [$label]" \
      "fetch が exec されなかった (sentinel が空のまま)。リダイレクトか spawn が壊れている"
  fi
}

# --- 2. 非ブロッキング (fd 付け替え (stdin/stdout/stderr) 3 点セットの回帰ガード) ---
# fetch が SLOW_FETCH_SEC 秒かかっても、描画はそれを待たずに返ること。
# `>/dev/null 2>&1 </dev/null` を外すと親が子の EOF を待ってブロックし、ここで落ちる。
case_non_blocking() {
  local bash_bin=$1 script=$2 label=$3
  local hist sentinel start end elapsed
  hist="$(mktemp -d -t claude-statusline-fetch.XXXXXX)"
  sentinel="${hist}.sentinel"
  : > "$sentinel"
  # shellcheck disable=SC2064
  trap "rm -r '$hist' 2>/dev/null || true; rm '$sentinel' 2>/dev/null || true" RETURN

  # 本番と同じく command substitution で出力を捕捉する (Claude Code の読み方)。
  # 子が fd を握ったままだとここで EOF 待ちに入る。
  start=$(date +%s)
  local output
  output=$(
    CLAUDE_STATUSLINE_HISTORY_DIR="$hist" TZ=UTC \
    CLAUDE_STATUSLINE_CONFIG="$NO_CONFIG" \
    CLAUDE_STATUSLINE_GIT_FETCH=1 \
    STATUSLINE_TEST_FETCH_SLEEP="$SLOW_FETCH_SEC" \
    STATUSLINE_TEST_FETCH_SENTINEL="$sentinel" \
    PATH="$GIT_SHIM_DIR:$PATH" \
      "$bash_bin" "$script" < "$FIXTURE" 2>/dev/null
  )
  end=$(date +%s)
  elapsed=$((end - start))

  if [ -z "$output" ]; then
    fail_case "non-blocking [$label]" "描画出力が空 (statusline が失敗している)"
    return
  fi
  if [ "$elapsed" -lt "$MAX_RENDER_SEC" ]; then
    pass_case "non-blocking [$label] (${elapsed}s < ${MAX_RENDER_SEC}s, fetch=${SLOW_FETCH_SEC}s)"
  else
    fail_case "non-blocking [$label]" \
      "描画に ${elapsed}s かかった (上限 ${MAX_RENDER_SEC}s)。fetch の完了を待ってしまっている"
  fi
}

# --- 3. 間引き ---
# GIT_FETCH_INTERVAL_SEC (900) 未満の連続呼び出しでは 2 回目の fetch を投げないこと。
case_throttle() {
  local bash_bin=$1 script=$2 label=$3
  local hist sentinel count
  hist="$(mktemp -d -t claude-statusline-fetch.XXXXXX)"
  sentinel="${hist}.sentinel"
  : > "$sentinel"
  # shellcheck disable=SC2064
  trap "rm -r '$hist' 2>/dev/null || true; rm '$sentinel' 2>/dev/null || true" RETURN

  run_statusline "$bash_bin" "$script" "$hist" "$sentinel" 0
  if ! wait_for_sentinel "$sentinel" 3; then
    fail_case "throttle [$label]" "1 回目の fetch が飛んでいない (前提が崩れている)"
    return
  fi

  # 2 回目。間引きに掛かって fetch を投げないはず。投げていれば sentinel が 2 行になる。
  run_statusline "$bash_bin" "$script" "$hist" "$sentinel" 0
  sleep 0.5

  count=$(wc -l < "$sentinel" | tr -d ' ')
  if [ "$count" = "1" ]; then
    pass_case "throttle [$label]"
  else
    fail_case "throttle [$label]" \
      "fetch が ${count} 回飛んだ (期待 1 回)。間引きマーカーが効いていない"
  fi
}

# --- 4. ロックが fetch 完走まで保持されない ---
# 遅い fetch を走らせたまま、直後にロックが空いていることを確認する。
#   Linux (flock): marker 更新 -> unlock -> fetch 起動 の順序の回帰ガード。順序を戻すと
#     named fd が ( ... & ) の子に継承され、fetch が終わるまで flock が居座る。
#     この不変条件を実際に検証できるのはこちらだけ (macOS 版は fd を使わない)。
#   macOS (mkdir): lockdir が残っていないこと = release_lock の呼び忘れ検出。
#     消し忘れると他の statusline が最大 LOCK_TIMEOUT_SEC×5 秒ロック待ちする。
case_lock_released() {
  local bash_bin=$1 script=$2 label=$3 lock_kind=$4
  local hist sentinel
  hist="$(mktemp -d -t claude-statusline-fetch.XXXXXX)"
  sentinel="${hist}.sentinel"
  : > "$sentinel"
  # shellcheck disable=SC2064
  trap "rm -r '$hist' 2>/dev/null || true; rm '$sentinel' 2>/dev/null || true" RETURN

  run_statusline "$bash_bin" "$script" "$hist" "$sentinel" "$SLOW_FETCH_SEC"

  if [ "$lock_kind" = "flock" ]; then
    # Linux 版: lockfile は残るが flock は解放済みのはず。
    # 子が fd を握ったままなら -n (非ブロッキング) の取得が失敗する。
    local lockfile
    lockfile="$(find_lock "$hist" ".lock")"
    if [ -z "$lockfile" ]; then
      fail_case "lock-released [$label]" "lockfile が見つからない (前提が崩れている)"
      return
    fi
    if flock -n -x "$lockfile" true 2>/dev/null; then
      pass_case "lock-released [$label]"
    else
      fail_case "lock-released [$label]" \
        "fetch 実行中に flock が保持されている。fd が子プロセスに継承されている"
    fi
  else
    # macOS 版: mkdir ロック。release_lock 済みなら lockdir は消えている。
    local lockdir
    lockdir="$(find_lock "$hist" ".lockd")"
    if [ -z "$lockdir" ]; then
      pass_case "lock-released [$label]"
    else
      fail_case "lock-released [$label]" \
        "fetch 実行中に lockdir ($lockdir) が残っている。spawn 前に解放していない"
    fi
  fi
}

# --- 5. マーカーが書けないときは fetch を投げない ---
# マーカーを書けないまま spawn すると、間引きの基点が残らないので次の描画も同じ経路に入り、
# 描画のたびに fetch が多重起動する (statusline は数秒ごとに呼ばれるため実質の連続 fetch)。
# 「書けなければ諦める」ことの回帰ガード。
#
# 書けない状態は「マーカーと同名のディレクトリ」で作る。パーミッション (chmod 400) だと
# root で走る CI では書けてしまい前提が崩れるが、ディレクトリへの `>` は uid によらず必ず失敗する。
case_marker_unwritable() {
  local bash_bin=$1 script=$2 label=$3
  local hist sentinel key marker count
  hist="$(mktemp -d -t claude-statusline-fetch.XXXXXX)"
  sentinel="${hist}.sentinel"
  : > "$sentinel"
  # shellcheck disable=SC2064
  trap "rm -r '$hist' 2>/dev/null || true; rm '$sentinel' 2>/dev/null || true" RETURN

  # 本体と同じ規則 (cwd = .workspace.current_dir の cksum) でマーカー名を先回りして作る。
  key=$(jq -r '.workspace.current_dir // ""' < "$FIXTURE" | tr -d '\n' | cksum)
  key=${key%% *}
  marker="${hist}/fetch-${key}"
  mkdir "$marker"

  # 2 回描画する。マーカーが書けない以上、どちらも fetch を投げてはいけない。
  run_statusline "$bash_bin" "$script" "$hist" "$sentinel" 0
  run_statusline "$bash_bin" "$script" "$hist" "$sentinel" 0
  sleep 0.5

  count=$(wc -l < "$sentinel" | tr -d ' ')
  if [ "$count" = "0" ]; then
    pass_case "marker-unwritable [$label]"
  else
    fail_case "marker-unwritable [$label]" \
      "マーカーを書けないのに fetch が ${count} 回飛んだ (期待 0 回)。間引きが効かず描画ごとに多重起動する"
  fi
}

# --- 6. 不正な間引き間隔の clamp ---
# GIT_FETCH_INTERVAL_SEC は env 上書き口を持たず conf (~/.claude/statusline.conf) で変える
# 運用なので、0 や負値を書かれても壊れないことを保証する必要がある。秒数比較は算術式なので、
# clamp が無ければ 0 は「常に間引かない」を意味し、描画のたびに fetch が多重起動する。
# clamp が下限 60 へ丸めていれば、連続 2 回の描画で fetch は 1 回しか飛ばない。
#
# ユーザーと同じ経路で再現するため、一時 conf に GIT_FETCH_INTERVAL_SEC=0 を書いて読み込ませる。
case_clamp_zero_interval() {
  local bash_bin=$1 script=$2 label=$3
  local hist sentinel config count
  hist="$(mktemp -d -t claude-statusline-fetch.XXXXXX)"
  sentinel="${hist}.sentinel"
  config="${hist}.conf"
  : > "$sentinel"
  printf 'GIT_FETCH_INTERVAL_SEC=0\n' > "$config"
  # shellcheck disable=SC2064
  trap "rm -r '$hist' 2>/dev/null || true; rm '$sentinel' '$config' 2>/dev/null || true" RETURN

  run_statusline "$bash_bin" "$script" "$hist" "$sentinel" 0 "$config"
  if ! wait_for_sentinel "$sentinel" 3; then
    fail_case "clamp-zero-interval [$label]" "1 回目の fetch が飛んでいない (前提が崩れている)"
    return
  fi

  # 2 回目。clamp が効いていれば下限 60 秒の間引きに掛かり fetch を投げない。
  run_statusline "$bash_bin" "$script" "$hist" "$sentinel" 0 "$config"
  sleep 0.5

  count=$(wc -l < "$sentinel" | tr -d ' ')
  if [ "$count" = "1" ]; then
    pass_case "clamp-zero-interval [$label]"
  else
    fail_case "clamp-zero-interval [$label]" \
      "GIT_FETCH_INTERVAL_SEC=0 で fetch が ${count} 回飛んだ (期待 1 回)。clamp が下限へ丸めていない"
  fi
}

run_all_cases() {
  local bash_bin=$1 script=$2 label=$3 lock_kind=$4
  total=$((total + 6))
  case_fetch_invoked       "$bash_bin" "$script" "$label"
  case_non_blocking        "$bash_bin" "$script" "$label"
  case_throttle            "$bash_bin" "$script" "$label"
  case_lock_released       "$bash_bin" "$script" "$label" "$lock_kind"
  case_marker_unwritable   "$bash_bin" "$script" "$label"
  case_clamp_zero_interval "$bash_bin" "$script" "$label"
}

# 環境チェック (両版共通の必須コマンドが揃っているか)。
# jq は macOS 版・Linux 版のどちらも冒頭で要求するので、ここで揃っていなければテスト自体が無意味。
require_command() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'git-fetch-behavior.sh: required command not found: %s\n' "$cmd" >&2
    exit 2
  fi
}

main() {
  require_command jq
  require_debian_bash_if_requested "$(basename "$0")" "$DEBIAN_BASH"

  printf 'statusline background git fetch behavior tests\n'
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
    run_all_cases /bin/bash "$MACOS_SCRIPT" macOS mkdir
  fi

  if [ -n "$DEBIAN_BASH" ]; then
    run_all_cases "$DEBIAN_BASH" "$DEBIAN_SCRIPT" Linux flock
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
