#!/usr/bin/env bash
# PR の状態表示 のバックグラウンド取得の挙動テスト。
#
# regression.sh はキャッシュを仕込んで「描画された文字列」だけを検証する。取得は投げっぱなしの
# 非同期処理なので出力に現れないため、本スクリプトは fake gh (lib/gh-shim/gh) のフック
# (STATUSLINE_TEST_GH_*) を使い、出力では観測できない不変条件と、--jq による変換を検証する。
#
# 各ケースは一時ディレクトリの中に、fake git の規約 (#branch=...;push=...;owner=...) を名前に
# 埋めた実在のディレクトリを作り、それを cwd として渡す。子プロセスは cwd に cd してから gh を
# 呼ぶため、cwd が実在しないと取得まで進まない。
#
# 実ネットワークには一切出ない (PATH 先頭の fake git / fake gh が受ける)。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
GIT_SHIM_DIR="$TESTS_DIR/lib/git-shim"
GH_SHIM_DIR="$TESTS_DIR/lib/gh-shim"
RESPONSES_DIR="$TESTS_DIR/pr-responses"

MACOS_SCRIPT="$REPO_DIR/statusline-macos.sh"
DEBIAN_SCRIPT="$REPO_DIR/statusline-linux.sh"

# shellcheck source=lib/find-debian-bash.sh
source "$TESTS_DIR/lib/find-debian-bash.sh"
# shellcheck source=lib/config-file.sh
source "$TESTS_DIR/lib/config-file.sh"
# shellcheck source=lib/is-macos-host.sh
source "$TESTS_DIR/lib/is-macos-host.sh"
# shellcheck source=lib/escape-ansi.sh
source "$TESTS_DIR/lib/escape-ansi.sh"
# shellcheck source=lib/pr-cache.sh
source "$TESTS_DIR/lib/pr-cache.sh"
# shellcheck source=lib/age-file.sh
source "$TESTS_DIR/lib/age-file.sh"
DEBIAN_BASH="$(find_debian_bash)"
RUN_MACOS=0
is_macos_host && RUN_MACOS=1

# fake git の既定のローカル HEAD (lib/git-shim/git の head 規約の既定値)。
LOCAL_HEAD_DEFAULT=0123456789abcdef0123456789abcdef01234567

# 遅い gh の待ち時間 (秒) と描画の所要時間の上限 (秒)。git-fetch-behavior.sh と同じ考え方。
SLOW_GH_SEC=5
MAX_RENDER_SEC=3

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

# ケースの作業ディレクトリを作り、case_dir / hist / repo / input / sentinel を設定する。
#   $1: repo ディレクトリ名の fake git 規約 (# 以降)
# 後始末は呼び出し側の trap で cleanup_case を呼ぶ。
setup_case() {
  local spec=$1
  case_dir="$(mktemp -d -t claude-statusline-pr.XXXXXX)"
  hist="$case_dir/hist"
  mkdir "$hist"
  chmod 700 "$hist"
  repo="$case_dir/my-project#$spec"
  mkdir "$repo"
  input="$case_dir/input.json"
  jq -n --arg cwd "$repo" \
    '{model: {display_name: "Sonnet 4.6"}, workspace: {current_dir: $cwd}}' > "$input"
  sentinel="$case_dir/sentinel"
  : > "$sentinel"
}

# 子プロセスが残っていれば終わるのを待ってから消す (.inflight が消えるまで最大 5 秒)。
cleanup_case() {
  local i=0
  while [ "$i" -lt 50 ] && compgen -G "$hist/pr-*.inflight" >/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  rm -r "$case_dir" 2>/dev/null || true
}

# statusline を 1 回実行し、ANSI を可読化した出力を stdout に返す。
#   $1 bash / $2 script / 以降は env に渡す追加の VAR=value
# 既定では PR_STATUS=1 で LAYOUT_LINE1=branch、応答は open-approved。
run_sl() {
  local bash_bin=$1 script=$2
  shift 2
  env CLAUDE_STATUSLINE_HISTORY_DIR="$hist" TZ=UTC \
    CLAUDE_STATUSLINE_CONFIG="$NO_CONFIG" \
    CLAUDE_STATUSLINE_COLOR_SCHEME="" CLAUDE_STATUSLINE_GIT_FETCH="" \
    CLAUDE_STATUSLINE_PR_STATUS=1 CLAUDE_STATUSLINE_LAYOUT_LINE1="branch" CLAUDE_STATUSLINE_LAYOUT_LINE2="" \
    CLAUDE_STATUSLINE_HIGHLIGHT="" FORCE_HYPERLINK=0 \
    STATUSLINE_TEST_GH_SENTINEL="$sentinel" \
    STATUSLINE_TEST_GH_RESPONSE="$RESPONSES_DIR/open-approved.json" \
    PATH="$GIT_SHIM_DIR:$GH_SHIM_DIR:$PATH" \
    "$@" \
    "$bash_bin" "$script" < "$input" 2>&1 | escape_ansi
}

# 条件 ($@ を eval) が真になるまで最大 $1 秒待つ。真になれば 0、時間切れなら 1。
wait_until() {
  local timeout_sec=$1
  shift
  local attempts=$((timeout_sec * 10)) i=0
  while [ "$i" -lt "$attempts" ]; do
    eval "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

sentinel_count() { wc -l < "$sentinel" | tr -d ' '; }

# main ブランチの取得が終わる (キャッシュがあり、.inflight が消える) まで最大 5 秒待つ。
wait_fetch_done() {
  wait_until 5 '[ -s "$(cache_path main)" ] && ! compgen -G "$hist/pr-*.inflight" >/dev/null'
}

# repo とブランチ名からキャッシュのパスを出す。
cache_path() { printf '%s/pr-%s' "$hist" "$(pr_cache_key "$repo" "$1")"; }

# キャッシュの fetched_at 以降 (タブを | にしたもの) を出す。無ければ空。
cache_body() {
  local file=$1 line=""
  [ -f "$file" ] || return 0
  IFS= read -r line < "$file" || true
  line=${line#*$'\t'}
  printf '%s' "${line//$'\t'/|}"
}

# --- invoked: PR_STATUS=1 のときに gh が起動され、結果が次回の描画に出る ---
case_invoked() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  run_sl "$bash_bin" "$script" >/dev/null
  if ! wait_until 5 '[ -s "$(cache_path main)" ]'; then
    fail_case "invoked [$label]" "キャッシュが書かれなかった (gh 呼び出し $(sentinel_count) 回)"
    return
  fi
  local out
  out=$(run_sl "$bash_bin" "$script")
  case "$out" in
    *'\e[38;2;255;255;255mmain\e[0m \e[4m\e[38;2;78;186;101m#12\e[0m\e[38;2;78;186;101m✓\e[0m 2'*)
      pass_case "invoked [$label]" ;;
    *) fail_case "invoked [$label]" "2 回目の描画に PR が出ない: $out" ;;
  esac
}

# --- not-invoked-when-disabled: PR_STATUS=0 のときと、
# PR_STATUS=1 でも branch 列を描画しないときは gh を起動せず、ファイルも作らない ---
case_not_invoked_when_disabled() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  run_sl "$bash_bin" "$script" CLAUDE_STATUSLINE_PR_STATUS=0 >/dev/null
  run_sl "$bash_bin" "$script" CLAUDE_STATUSLINE_LAYOUT_LINE1="directory|session" >/dev/null
  sleep 0.5
  if [ "$(sentinel_count)" = "0" ] && ! compgen -G "$hist/pr-*" >/dev/null; then
    pass_case "not-invoked-when-disabled [$label]"
  else
    fail_case "not-invoked-when-disabled [$label]" \
      "無効なのに gh が $(sentinel_count) 回呼ばれた、または pr-* が作られた"
  fi
}

# --- non-blocking: gh が遅くても描画は待たない (fd 付け替えの回帰ガード) ---
case_non_blocking() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  local start end elapsed out
  start=$(date +%s)
  out=$(run_sl "$bash_bin" "$script" STATUSLINE_TEST_GH_SLEEP="$SLOW_GH_SEC")
  end=$(date +%s)
  elapsed=$((end - start))
  if [ -z "$out" ]; then
    fail_case "non-blocking [$label]" "描画出力が空 (statusline が失敗している)"
  elif [ "$elapsed" -lt "$MAX_RENDER_SEC" ]; then
    pass_case "non-blocking [$label] (${elapsed}s < ${MAX_RENDER_SEC}s, gh=${SLOW_GH_SEC}s)"
  else
    fail_case "non-blocking [$label]" \
      "描画に ${elapsed}s かかった (上限 ${MAX_RENDER_SEC}s)。gh の完了を待ってしまっている"
  fi
}

# --- throttle: 間隔内の 2 回目の描画では gh を起動しない ---
case_throttle() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  run_sl "$bash_bin" "$script" >/dev/null
  if ! wait_fetch_done; then
    fail_case "throttle [$label]" "1 回目の取得が終わらない (前提が崩れている)"
    return
  fi
  run_sl "$bash_bin" "$script" >/dev/null
  sleep 0.5
  if [ "$(sentinel_count)" = "1" ]; then
    pass_case "throttle [$label]"
  else
    fail_case "throttle [$label]" "gh が $(sentinel_count) 回呼ばれた (期待 1 回)。マーカーの間引きが効いていない"
  fi
}

# --- single-flight: .inflight があれば、間隔を過ぎていても次の gh を起動しない ---
case_single_flight() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  # マーカーなし (= すぐ取得すべき状態) で、実行中の印だけを先に置く。
  local inflight
  inflight="$(cache_path main).inflight"
  mkdir "$inflight"
  run_sl "$bash_bin" "$script" >/dev/null
  run_sl "$bash_bin" "$script" >/dev/null
  sleep 0.5
  rmdir "$inflight"
  if [ "$(sentinel_count)" = "0" ]; then
    pass_case "single-flight [$label]"
  else
    fail_case "single-flight [$label]" "取得の実行中なのに gh が $(sentinel_count) 回呼ばれた (期待 0 回)"
  fi
}

# --- stale-inflight: 90 秒より古い .inflight は消され、取得が再開される ---
case_stale_inflight() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  local inflight
  inflight="$(cache_path main).inflight"
  mkdir "$inflight"
  age_file "$inflight" 120
  run_sl "$bash_bin" "$script" >/dev/null
  if wait_until 5 '[ -s "$(cache_path main)" ] && [ ! -d "$inflight" ]'; then
    pass_case "stale-inflight [$label]"
  else
    fail_case "stale-inflight [$label]" \
      "古い .inflight が残ったまま取得が再開されない (gh 呼び出し $(sentinel_count) 回)"
  fi
}

# --- timeout: gh が終わらなくても打ち切られ、.inflight が消える ---
case_timeout() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  local inflight
  inflight="$(cache_path main).inflight"
  run_sl "$bash_bin" "$script" CLAUDE_STATUSLINE_TEST_PR_TIMEOUT_SEC=1 \
    STATUSLINE_TEST_GH_SLEEP=20 >/dev/null
  if ! wait_until 3 '[ "$(sentinel_count)" = "1" ]'; then
    fail_case "timeout [$label]" "gh が起動されなかった (前提が崩れている)"
    return
  fi
  if wait_until 5 '[ ! -d "$inflight" ]' && [ ! -e "$(cache_path main)" ]; then
    pass_case "timeout [$label]"
  else
    fail_case "timeout [$label]" "打ち切り (1 秒) の後も .inflight が残っている、またはキャッシュが書かれた"
  fi
}

# --- no-overwrite-by-older: 自分の開始時刻より新しい fetched_at があれば上書きしない ---
case_no_overwrite_by_older() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  local cache newer
  cache="$(cache_path main)"
  run_sl "$bash_bin" "$script" STATUSLINE_TEST_GH_SLEEP=3 >/dev/null
  wait_until 3 '[ "$(sentinel_count)" = "1" ]' || true
  # gh の実行中に、後から始まった取得の結果が書かれた状態を作る。fetched_at は取得の開始より後で、
  # 取得の終了 (gh の 3 秒後) より前にする (現在より未来の fetched_at は上書きされる)。
  newer="$(( $(date +%s) + 1 ))"
  printf '%s\t34\tmerged\t\t\t0\t1\thttps://github.com/my-org/my-project/pull/34\n' "$newer" > "$cache"
  if ! wait_until 5 '! compgen -G "$hist/pr-*.inflight" >/dev/null'; then
    fail_case "no-overwrite-by-older [$label]" "取得が終わらない (前提が崩れている)"
    return
  fi
  if [ "$(cache_body "$cache")" = "34|merged|||0|1|https://github.com/my-org/my-project/pull/34" ]; then
    pass_case "no-overwrite-by-older [$label]"
  else
    fail_case "no-overwrite-by-older [$label]" "新しいキャッシュが古い結果で上書きされた: $(cache_body "$cache")"
  fi
}

# --- branch-switch: ブランチを変えると別のキーになり、前のブランチの PR を表示しない ---
case_branch_switch() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  run_sl "$bash_bin" "$script" >/dev/null
  if ! wait_fetch_done; then
    fail_case "branch-switch [$label]" "main の取得が終わらない (前提が崩れている)"
    return
  fi
  # 同じ cwd のままブランチだけを切り替える。新しいブランチには PR がない。
  local out
  out=$(run_sl "$bash_bin" "$script" STATUSLINE_TEST_BRANCH=feature/other \
    STATUSLINE_TEST_GH_RESPONSE="$RESPONSES_DIR/merged-head-mismatch.json")
  case "${out%%$'\n'*}" in
    'feature/\e[38;2;255;255;255mother\e[0m') ;;
    *)
      fail_case "branch-switch [$label]" "切り替え直後に前のブランチの PR が出た: ${out%%$'\n'*}"
      return
      ;;
  esac
  if wait_until 5 '[ -s "$(cache_path feature/other)" ]' \
     && [ "$(sentinel_count)" = "2" ] && [ "$(tail -n 1 "$sentinel" | cut -d' ' -f1)" = "head=feature/other" ]; then
    pass_case "branch-switch [$label]"
  else
    fail_case "branch-switch [$label]" "新しいブランチの取得が起動されない: $(tail -n 1 "$sentinel")"
  fi
}

# --- push-branch-name: ローカル名と push 先の名前が違うとき、push 先の名前とオーナーで問い合わせる ---
# リモート URL の 3 形式 (https / scp / ssh) からオーナーを取り出せることも確かめる。
case_push_branch_name() {
  local bash_bin=$1 script=$2 label=$3 form
  for form in https scp ssh; do
    setup_case "branch=fix;ab=0,0;push=origin~feature~fix;owner=Me;urlform=$form"
    run_sl "$bash_bin" "$script" >/dev/null
    if ! wait_until 5 '[ "$(sentinel_count)" = "1" ]'; then
      cleanup_case
      fail_case "push-branch-name [$label]" "gh が起動されなかった (urlform=$form)"
      return
    fi
    local got
    got=$(cut -d' ' -f1,2 < "$sentinel")
    cleanup_case
    if [ "$got" != "head=feature/fix head_owner=Me" ]; then
      fail_case "push-branch-name [$label]" "urlform=$form で ${got} を渡した (期待 head=feature/fix head_owner=Me)"
      return
    fi
  done
  pass_case "push-branch-name [$label]"
}

# --- marker-unwritable: マーカーを書けないときは gh を起動しない ---
# 書けない状態は「マーカーと同名のディレクトリ」で作る (root の CI でも必ず失敗する)。
case_marker_unwritable() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  mkdir "$(cache_path main).marker"
  run_sl "$bash_bin" "$script" >/dev/null
  run_sl "$bash_bin" "$script" >/dev/null
  sleep 0.5
  if [ "$(sentinel_count)" = "0" ]; then
    pass_case "marker-unwritable [$label]"
  else
    fail_case "marker-unwritable [$label]" "マーカーを書けないのに gh が $(sentinel_count) 回呼ばれた (期待 0 回)"
  fi
}

# --- gh-failure-keeps-cache: gh が非ゼロで終了したとき、キャッシュを書き換えない ---
case_gh_failure_keeps_cache() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  local cache before
  cache="$(cache_path main)"
  # マーカーなし (= すぐ取得する) で、期限内の古いキャッシュを置く。
  printf '%s\t34\topen\tapproved\tpass\t0\t1\thttps://github.com/my-org/my-project/pull/34\n' \
    "$(( $(date +%s) - 100 ))" > "$cache"
  before=$(cat "$cache")
  run_sl "$bash_bin" "$script" STATUSLINE_TEST_GH_EXIT=1 >/dev/null
  if ! wait_until 5 '[ "$(sentinel_count)" = "1" ] && ! compgen -G "$hist/pr-*.inflight" >/dev/null'; then
    fail_case "gh-failure-keeps-cache [$label]" "取得が起動されない、または終わらない (前提が崩れている)"
    return
  fi
  local out
  out=$(run_sl "$bash_bin" "$script" STATUSLINE_TEST_GH_EXIT=1)
  if [ "$(cat "$cache")" = "$before" ] && [[ "$out" == *'#34'* ]]; then
    pass_case "gh-failure-keeps-cache [$label]"
  else
    fail_case "gh-failure-keeps-cache [$label]" "失敗した取得でキャッシュが変わった、または前回の表示が消えた: $out"
  fi
}

# --- env-sanitized: GH_REPO / GH_FORCE_TTY / CLICOLOR_FORCE を外し、gh 用の 3 変数を設定する ---
# 認証方法 (GH_TOKEN) はユーザーの選択なので残す。
case_env_sanitized() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  run_sl "$bash_bin" "$script" GH_REPO=someone/else GH_FORCE_TTY=1 CLICOLOR_FORCE=1 \
    GH_TOKEN=test-token >/dev/null
  if ! wait_until 5 '[ "$(sentinel_count)" = "1" ]'; then
    fail_case "env-sanitized [$label]" "gh が起動されなかった (前提が崩れている)"
    return
  fi
  local line expected
  line=$(cut -d' ' -f4- < "$sentinel")
  expected='GH_REPO=<unset> GH_FORCE_TTY=<unset> CLICOLOR_FORCE=<unset> GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_NO_EXTENSION_UPDATE_NOTIFIER=1 GH_TOKEN=test-token GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true SSH_ASKPASS=/bin/true SSH_ASKPASS_REQUIRE=force'
  if [ "$line" = "$expected" ]; then
    pass_case "env-sanitized [$label]"
  else
    fail_case "env-sanitized [$label]" "gh に渡った環境変数が違う: $line"
  fi
}

# --- no-gh: gh が PATH にないときは何も起動せず、列を省略する ---
# 本物の gh は jq などと同じディレクトリ (/usr/bin や /opt/homebrew/bin) にあることが多く、
# PATH からディレクトリごと外せない。本体と fake git (shebang の env bash) が使うコマンドだけを
# symlink した bin を作って PATH にする。
case_no_gh() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  local bin="$case_dir/bin" cmd path
  mkdir "$bin"
  for cmd in bash jq id uname mkdir chmod stat date awk tail mktemp mv rm rmdir cat cksum sleep flock; do
    path=$(command -v "$cmd" 2>/dev/null) || continue
    ln -s "$path" "$bin/$cmd"
  done
  # 前回の取得結果が残っていても、gh がなければ表示しない。
  printf '%s\t12\topen\tapproved\tpass\t0\t1\thttps://github.com/my-org/my-project/pull/12\n' \
    "$(date +%s)" > "$(cache_path main)"
  # env は後に書いた PATH が勝つので、run_sl の PATH を差し替えられる。
  local out
  out=$(run_sl "$bash_bin" "$script" PATH="$GIT_SHIM_DIR:$bin")
  if [ "${out%%$'\n'*}" = '\e[38;2;255;255;255mmain\e[0m' ] && [ ! -e "$(cache_path main).marker" ]; then
    pass_case "no-gh [$label]"
  else
    fail_case "no-gh [$label]" "gh がないのに PR が出た、またはマーカーが作られた: ${out%%$'\n'*}"
  fi
}

# --- refresh-interval: キャッシュの状態から決まる間隔 (FAST 30 / SLOW 300 / DONE 900 秒) で起動する ---
# マーカーの mtime を過去にずらし、間隔を過ぎていれば gh を起動し、過ぎていなければ起動しない。
#   <キャッシュの fetched_at 以降 (タブは \t)>;<マーカーの経過秒>;<起動の回数>
# fetched_at はマーカーより新しくする (古いと「前回の試行が失敗した」扱いで SLOW になる)。
# 最後の 1 件は fetched_at がマーカーより古いので、merged でも DONE ではなく SLOW になる。
case_refresh_interval() {
  local bash_bin=$1 script=$2 label=$3 spec body marker_age want url=https://github.com/my-org/my-project/pull/12
  for spec in \
    "12\topen\tapproved\tpending\t0\t1\t$url;60;1" \
    "12\topen\tapproved\tpass\t0\t0\t$url;60;1" \
    "12\topen\tapproved\tpass\t0\t1\t$url;60;0" \
    "12\topen\tapproved\tpass\t0\t1\t$url;400;1" \
    "12\tmerged\t\tpass\t0\t1\t$url;400;0" \
    "12\tmerged\t\tpass\t0\t1\t$url;1000;1" \
    "old:12\tmerged\t\tpass\t0\t1\t$url;400;1"; do
    body=${spec%%;*}
    marker_age=${spec#*;}; marker_age=${marker_age%%;*}
    want=${spec##*;}
    setup_case "branch=main;ab=0,0"
    local cache fetched
    cache="$(cache_path main)"
    : > "$cache.marker"
    age_file "$cache.marker" "$marker_age"
    fetched=$(( $(date +%s) - marker_age + 10 ))
    case "$body" in old:*) body=${body#old:}; fetched=$(( fetched - 20 )) ;; esac
    printf '%s\t%b\n' "$fetched" "$body" > "$cache"
    run_sl "$bash_bin" "$script" >/dev/null
    sleep 0.5
    local got
    got=$(sentinel_count)
    cleanup_case
    if [ "$got" != "$want" ]; then
      fail_case "refresh-interval [$label]" "マーカーが ${marker_age} 秒前で gh が ${got} 回呼ばれた (期待 ${want} 回): ${spec%%;*}"
      return
    fi
  done
  pass_case "refresh-interval [$label]"
}

# --- not-invoked-without-prerequisites: detached HEAD と、symlink の履歴ディレクトリ (無効になる) では起動しない ---
case_not_invoked_without_prerequisites() {
  local bash_bin=$1 script=$2 label=$3 kind
  for kind in detached history-symlink; do
    case "$kind" in
      detached) setup_case "detached" ;;
      history-symlink) setup_case "branch=main;ab=0,0"; mv "$hist" "$case_dir/real"; ln -s real "$hist" ;;
    esac
    run_sl "$bash_bin" "$script" >/dev/null
    sleep 0.5
    local count files=0
    count=$(sentinel_count)
    compgen -G "$hist/pr-*" >/dev/null && files=1
    cleanup_case
    if [ "$count" != "0" ] || [ "$files" != "0" ]; then
      fail_case "not-invoked-without-prerequisites [$label]" \
        "$kind で gh が ${count} 回呼ばれた、または pr-* が作られた"
      return
    fi
  done
  pass_case "not-invoked-without-prerequisites [$label]"
}

# --- future-fetched-at: fetched_at が現在より未来のキャッシュは表示せず、取得の結果で置き換える ---
# 時計が戻った後に、その差の時間だけ古い表示が残り、更新もされなくなるのを防ぐ。
case_future_fetched_at() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  local cache out
  cache="$(cache_path main)"
  printf '%s\t34\topen\tapproved\tpass\t0\t1\thttps://github.com/my-org/my-project/pull/34\n' \
    "$(( $(date +%s) + 1000 ))" > "$cache"
  out=$(run_sl "$bash_bin" "$script")
  if [[ "$out" == *'#34'* ]]; then
    fail_case "future-fetched-at [$label]" "未来の fetched_at のキャッシュを表示した: $out"
    return
  fi
  if wait_until 5 '[ "$(cache_body "$cache")" = "12|open|approved|pass|2|1|https://github.com/my-org/my-project/pull/12" ]'; then
    pass_case "future-fetched-at [$label]"
  else
    fail_case "future-fetched-at [$label]" "取得の結果で置き換わらない: $(cache_body "$cache")"
  fi
}

# --- comment-count: キャッシュのコメントの件数は、先頭が 0 でない 9 桁以内の正の整数のときだけ出す ---
#   各要素は「キャッシュに書く件数;1 行目の CI 記号の後に続く期待値」
case_comment_count() {
  local bash_bin=$1 script=$2 label=$3
  local spec comments want cache line
  for spec in '3; 3' '123456789; 123456789' '0;' '012;' '1234567890;' '-1;'; do
    comments=${spec%%;*}
    want=${spec#*;}
    setup_case "branch=main;ab=0,0"
    cache="$(cache_path main)"
    printf '%s\t12\topen\tapproved\tpass\t%s\t1\thttps://github.com/my-org/my-project/pull/12\n' \
      "$(date +%s)" "$comments" > "$cache"
    # 間隔内のマーカーを置き、取得を起動させずに仕込んだキャッシュをそのまま読ませる。
    : > "$cache.marker"
    line=$(run_sl "$bash_bin" "$script")
    line=${line%%$'\n'*}
    cleanup_case
    if [ "$line" != '\e[38;2;255;255;255mmain\e[0m \e[4m\e[38;2;78;186;101m#12\e[0m\e[38;2;78;186;101m✓\e[0m'"$want" ]; then
      fail_case "comment-count [$label]" "件数 '${comments}' の表示が違う: $line"
      return
    fi
  done
  pass_case "comment-count [$label]"
}

# --- early-*: stdin の pr の署名の変化による取得の前倒し ---
# 署名は pr.url と pr.review_state を : でつないだもの。.seen は「前回の前倒しの時刻 + 改行 + 署名」。
# 各ケースは、間隔による取得が起動しない状態 (seed_fresh) から始め、前倒しだけを観測する。
PR_A='{"number":12,"url":"https://github.com/my-org/my-project/pull/12","review_state":"pending"}'
PR_A_APPROVED='{"number":12,"url":"https://github.com/my-org/my-project/pull/12","review_state":"approved"}'
PR_B='{"number":34,"url":"https://github.com/my-org/my-project/pull/34","review_state":"pending"}'
SIG_A='https://github.com/my-org/my-project/pull/12:pending'
SIG_A_APPROVED='https://github.com/my-org/my-project/pull/12:approved'
SIG_B='https://github.com/my-org/my-project/pull/34:pending'

# input.json を session_id と pr を含む形に書き直す。
#   $1 session_id の JSON の値 / $2 pr の JSON の値 (どちらも null ならそのフィールドを書かない)
set_stdin() {
  jq -n --arg cwd "$repo" --argjson sid "$1" --argjson pr "$2" \
    '{model: {display_name: "Sonnet 4.6"}, workspace: {current_dir: $cwd}}
     + (if $sid == null then {} else {session_id: $sid} end)
     + (if $pr == null then {} else {pr: $pr} end)' > "$input"
}

# ブランチ $1 (省略時は main) に、今取得したばかりの PR なしのキャッシュとマーカーを置く。
# 間隔 (300 秒) が過ぎていないので、間隔による取得は起動しない。
seed_fresh() {
  local cache
  cache="$(cache_path "${1:-main}")"
  date +%s > "$cache"
  : > "$cache.marker"
}

seen_path() { printf '%s/pr-%s.seen' "$hist" "${1:-my-session}"; }

# .seen を書く。$1 session_id / $2 時刻 / $3 署名
write_seen() { printf '%s\n%s\n' "$2" "$3" > "$(seen_path "$1")"; }

# .seen の 2 行目 (署名) を出す。ファイルがなければ空。
seen_sig() {
  local file at="" sig=""
  file="$(seen_path "${1:-my-session}")"
  [ -f "$file" ] || return 0
  { IFS= read -r at; IFS= read -r sig; } < "$file" || true
  printf '%s' "$sig"
}

# gh の呼び出しが $1 回になり、実行中の取得がなくなるまで最大 5 秒待つ。
wait_calls() {
  wait_until 5 "[ \"\$(sentinel_count)\" = \"$1\" ] && ! compgen -G \"\$hist/pr-*.inflight\" >/dev/null"
}

# 前倒しが起動しないことを確かめる前の待ち時間。起動していれば子プロセスが gh を呼ぶ時間を取る。
settle() { sleep 0.5; }

# --- early-on-change: 署名が前回と変わった描画で、間隔を待たずに取得が 1 回だけ起動する ---
# review_state だけの変化 (pending → approved) も変化として扱う。
case_early_on_change() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_fresh
  write_seen my-session "$(( $(date +%s) - 100 ))" "$SIG_A"
  set_stdin '"my-session"' "$PR_A"
  run_sl "$bash_bin" "$script" >/dev/null
  settle
  if [ "$(sentinel_count)" != "0" ]; then
    fail_case "early-on-change [$label]" "署名が同じなのに gh が $(sentinel_count) 回呼ばれた (期待 0 回)"
    return
  fi
  set_stdin '"my-session"' "$PR_A_APPROVED"
  run_sl "$bash_bin" "$script" >/dev/null
  if ! wait_calls 1; then
    fail_case "early-on-change [$label]" "署名が変わったのに取得が起動しない (gh 呼び出し $(sentinel_count) 回)"
    return
  fi
  run_sl "$bash_bin" "$script" >/dev/null
  run_sl "$bash_bin" "$script" >/dev/null
  settle
  if [ "$(sentinel_count)" = "1" ] && [ "$(seen_sig)" = "$SIG_A_APPROVED" ]; then
    pass_case "early-on-change [$label]"
  else
    fail_case "early-on-change [$label]" \
      "gh が $(sentinel_count) 回呼ばれた (期待 1 回)、または .seen の署名が違う: $(seen_sig)"
  fi
}

# --- early-seen-missing: .seen がなければ none とみなす。pr があれば 1 回起動し、なければ起動せず作らない ---
case_early_seen_missing() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_fresh
  set_stdin '"my-session"' null
  run_sl "$bash_bin" "$script" >/dev/null
  run_sl "$bash_bin" "$script" >/dev/null
  settle
  if [ "$(sentinel_count)" != "0" ] || [ -e "$(seen_path)" ]; then
    fail_case "early-seen-missing [$label]" \
      "pr がないのに gh が $(sentinel_count) 回呼ばれた、または .seen が作られた"
    return
  fi
  set_stdin '"my-session"' "$PR_A"
  run_sl "$bash_bin" "$script" >/dev/null
  if wait_calls 1 && [ "$(seen_sig)" = "$SIG_A" ]; then
    pass_case "early-seen-missing [$label]"
  else
    fail_case "early-seen-missing [$label]" \
      "pr があるのに取得が 1 回起動しない (gh 呼び出し $(sentinel_count) 回)、または .seen の署名が違う: $(seen_sig)"
  fi
}

# --- early-mismatch-persists: stdin の pr とキャッシュが食い違ったままでも、起動し続けない ---
# 取得の結果は PR なしなので、キャッシュは stdin の pr と食い違ったまま残る。最低間隔が過ぎても起動しない。
case_early_mismatch_persists() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  local none_response="STATUSLINE_TEST_GH_RESPONSE=$RESPONSES_DIR/merged-head-mismatch.json"
  seed_fresh
  set_stdin '"my-session"' "$PR_A"
  run_sl "$bash_bin" "$script" "$none_response" >/dev/null
  if ! wait_calls 1; then
    fail_case "early-mismatch-persists [$label]" "最初の前倒しが起動しない (前提が崩れている)"
    return
  fi
  run_sl "$bash_bin" "$script" "$none_response" >/dev/null
  run_sl "$bash_bin" "$script" "$none_response" >/dev/null
  write_seen my-session "$(( $(date +%s) - 100 ))" "$SIG_A"
  run_sl "$bash_bin" "$script" "$none_response" >/dev/null
  settle
  if [ "$(sentinel_count)" = "1" ]; then
    pass_case "early-mismatch-persists [$label]"
  else
    fail_case "early-mismatch-persists [$label]" \
      "キャッシュと食い違ったまま gh が $(sentinel_count) 回呼ばれた (期待 1 回)"
  fi
}

# --- early-branch-switch: ブランチを切り替えても、署名が同じなら前倒ししない ---
# 切り替え直後は stdin に前のブランチの pr が残る。最後に署名を変え、切り替え先のキーで起動することも見る。
case_early_branch_switch() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_fresh main
  seed_fresh feature/other
  write_seen my-session "$(( $(date +%s) - 100 ))" "$SIG_A"
  set_stdin '"my-session"' "$PR_A"
  run_sl "$bash_bin" "$script" >/dev/null
  run_sl "$bash_bin" "$script" STATUSLINE_TEST_BRANCH=feature/other >/dev/null
  run_sl "$bash_bin" "$script" STATUSLINE_TEST_BRANCH=feature/other >/dev/null
  settle
  if [ "$(sentinel_count)" != "0" ]; then
    fail_case "early-branch-switch [$label]" "署名が同じなのに gh が $(sentinel_count) 回呼ばれた (期待 0 回)"
    return
  fi
  set_stdin '"my-session"' "$PR_B"
  run_sl "$bash_bin" "$script" STATUSLINE_TEST_BRANCH=feature/other >/dev/null
  if wait_calls 1 && [ "$(cut -d' ' -f1 < "$sentinel")" = "head=feature/other" ]; then
    pass_case "early-branch-switch [$label]"
  else
    fail_case "early-branch-switch [$label]" \
      "署名を変えても切り替え先で起動しない (gh 呼び出し $(sentinel_count) 回): $(cat "$sentinel")"
  fi
}

# --- early-save-failure: .seen かマーカーを書けなければ前倒ししない ---
# .seen を書けない間はマーカーも書き換えず、間隔が過ぎれば通常の取得が起動する (マーカーを先に書くと、
# 前倒しを試すたびに間隔が先送りされ、通常の取得まで止まる)。書けない状態は同名のディレクトリで作る。
case_early_save_failure() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  local cache
  cache="$(cache_path main)"
  seed_fresh
  # 間隔 (300 秒) の手前。マーカーが書き換われば、経過時間が 1 分未満に戻る。
  age_file "$cache.marker" 200
  mkdir "$(seen_path)"
  set_stdin '"my-session"' "$PR_A"
  run_sl "$bash_bin" "$script" >/dev/null
  run_sl "$bash_bin" "$script" >/dev/null
  settle
  if [ "$(sentinel_count)" != "0" ]; then
    fail_case "early-save-failure [$label]" ".seen を書けないのに gh が $(sentinel_count) 回呼ばれた (期待 0 回)"
    return
  fi
  if [ -z "$(find "$cache.marker" -mmin +1)" ]; then
    fail_case "early-save-failure [$label]" ".seen を書けないのにマーカーが書き換わった (通常の取得が先送りされる)"
    return
  fi
  age_file "$cache.marker" 400
  run_sl "$bash_bin" "$script" >/dev/null
  if ! wait_calls 1; then
    fail_case "early-save-failure [$label]" \
      ".seen を書けないときに、間隔が過ぎても通常の取得が起動しない (gh 呼び出し $(sentinel_count) 回)"
    return
  fi
  cleanup_case
  trap - RETURN

  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN
  cache="$(cache_path main)"
  date +%s > "$cache"
  mkdir "$cache.marker"
  set_stdin '"my-session"' "$PR_A"
  run_sl "$bash_bin" "$script" >/dev/null
  run_sl "$bash_bin" "$script" >/dev/null
  settle
  if [ "$(sentinel_count)" = "0" ]; then
    pass_case "early-save-failure [$label]"
  else
    fail_case "early-save-failure [$label]" "マーカーを書けないのに gh が $(sentinel_count) 回呼ばれた (期待 0 回)"
  fi
}

# --- early-waits-inflight: 取得の実行中は前倒しせず .seen も書かない。終わった後の描画で起動する ---
case_early_waits_inflight() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  local inflight
  inflight="$(cache_path main).inflight"
  seed_fresh
  mkdir "$inflight"
  set_stdin '"my-session"' "$PR_A"
  run_sl "$bash_bin" "$script" >/dev/null
  run_sl "$bash_bin" "$script" >/dev/null
  settle
  if [ "$(sentinel_count)" != "0" ] || [ -e "$(seen_path)" ]; then
    rmdir "$inflight"
    fail_case "early-waits-inflight [$label]" \
      "実行中なのに gh が $(sentinel_count) 回呼ばれた、または .seen が書かれた"
    return
  fi
  rmdir "$inflight"
  run_sl "$bash_bin" "$script" >/dev/null
  if wait_calls 1 && [ "$(seen_sig)" = "$SIG_A" ]; then
    pass_case "early-waits-inflight [$label]"
  else
    fail_case "early-waits-inflight [$label]" \
      "取得が終わった後の描画で前倒しが起動しない (gh 呼び出し $(sentinel_count) 回)"
  fi
}

# --- early-inflight-during-lock: ロックを待つ間に取得が実行中になったら、前倒しせず .seen も書かない ---
# ロックを外から握った状態で描画を走らせ、描画がロックを待つ間に .inflight を作ってから解放する。
# 前倒しすると自分の子プロセスは .inflight を作れずに終わり、.seen だけが新しくなってきっかけが消える。
# ロックは macOS 版がディレクトリ (<marker>.lockd)、Linux 版が flock (<marker>.lock)。
case_early_inflight_during_lock() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  local cache holder="" render
  cache="$(cache_path main)"
  seed_fresh
  set_stdin '"my-session"' "$PR_A"
  if [ "$label" = macOS ]; then
    mkdir "$cache.marker.lockd"
  else
    flock "$cache.marker.lock" sleep 1.5 &
    holder=$!
    wait_until 2 '[ -e "$cache.marker.lock" ]' || true
  fi
  run_sl "$bash_bin" "$script" >/dev/null &
  render=$!
  # 描画がロックを取る前の .inflight の確認を通り、ロックを待つところまで進む時間を取る。
  sleep 1
  mkdir "$cache.inflight"
  if [ "$label" = macOS ]; then
    rmdir "$cache.marker.lockd"
  else
    wait "$holder" || true
  fi
  wait "$render" || true
  settle
  if [ "$(sentinel_count)" != "0" ] || [ -e "$(seen_path)" ]; then
    rmdir "$cache.inflight"
    fail_case "early-inflight-during-lock [$label]" \
      "ロックを待つ間に取得が実行中になったのに、gh が $(sentinel_count) 回呼ばれた、または .seen が書かれた"
    return
  fi
  rmdir "$cache.inflight"
  run_sl "$bash_bin" "$script" >/dev/null
  if wait_calls 1 && [ "$(seen_sig)" = "$SIG_A" ]; then
    pass_case "early-inflight-during-lock [$label]"
  else
    fail_case "early-inflight-during-lock [$label]" \
      "取得が終わった後の描画で前倒しが起動しない (gh 呼び出し $(sentinel_count) 回)。きっかけが消費された"
  fi
}

# --- early-min-interval: 前回の前倒しから 30 秒以内は前倒しせず .seen も書かない。過ぎた後に起動する ---
# 基点は通常の取得の時刻ではないので、通常の取得の直後でも前倒しする。
case_early_min_interval() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  local recent before
  recent="$(( $(date +%s) - 10 ))"
  seed_fresh
  write_seen my-session "$recent" "$SIG_A"
  before=$(cat "$(seen_path)")
  set_stdin '"my-session"' "$PR_B"
  run_sl "$bash_bin" "$script" >/dev/null
  settle
  if [ "$(sentinel_count)" != "0" ] || [ "$(cat "$(seen_path)")" != "$before" ]; then
    fail_case "early-min-interval [$label]" \
      "前回の前倒しから 10 秒で gh が $(sentinel_count) 回呼ばれた、または .seen が書き換わった"
    return
  fi
  write_seen my-session "$(( $(date +%s) - 40 ))" "$SIG_A"
  run_sl "$bash_bin" "$script" >/dev/null
  if ! wait_calls 1; then
    fail_case "early-min-interval [$label]" \
      "前回の前倒しから 40 秒経っても起動しない (gh 呼び出し $(sentinel_count) 回)"
    return
  fi
  cleanup_case
  trap - RETURN

  # マーカーなし (= 通常の取得がすぐ起動する) で始め、通常の取得の直後に署名を変える。
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN
  set_stdin '"my-session"' null
  run_sl "$bash_bin" "$script" >/dev/null
  if ! wait_calls 1; then
    fail_case "early-min-interval [$label]" "通常の取得が起動しない (前提が崩れている)"
    return
  fi
  set_stdin '"my-session"' "$PR_A"
  run_sl "$bash_bin" "$script" >/dev/null
  if wait_calls 2; then
    pass_case "early-min-interval [$label]"
  else
    fail_case "early-min-interval [$label]" \
      "通常の取得の直後に前倒しが起動しない (gh 呼び出し $(sentinel_count) 回)"
  fi
}

# --- early-seen-bad-time: .seen の時刻が数字でない、または未来なら、最低間隔は過ぎたものとみなす ---
case_early_seen_bad_time() {
  local bash_bin=$1 script=$2 label=$3 at
  for at in abc "" 0123 "$(( $(date +%s) + 1000 ))"; do
    setup_case "branch=main;ab=0,0"
    seed_fresh
    write_seen my-session "$at" "$SIG_A"
    set_stdin '"my-session"' "$PR_B"
    run_sl "$bash_bin" "$script" >/dev/null
    local ok=0
    wait_calls 1 && [ "$(seen_sig)" = "$SIG_B" ] && ok=1
    local got
    got=$(sentinel_count)
    cleanup_case
    if [ "$ok" != "1" ]; then
      fail_case "early-seen-bad-time [$label]" ".seen の時刻 '$at' で前倒しが起動しない (gh 呼び出し $got 回)"
      return
    fi
  done
  pass_case "early-seen-bad-time [$label]"
}

# --- early-alternating: 同じ session_id で署名が交互に変わっても、30 秒に 1 回を超えて起動しない ---
# 同じセッションを 2 つの端末で開き、両者の pr が食い違う場合を模す。
case_early_alternating() {
  local bash_bin=$1 script=$2 label=$3 pr
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_fresh
  set_stdin '"my-session"' "$PR_A"
  run_sl "$bash_bin" "$script" >/dev/null
  if ! wait_calls 1; then
    fail_case "early-alternating [$label]" "最初の前倒しが起動しない (前提が崩れている)"
    return
  fi
  for pr in "$PR_B" "$PR_A" "$PR_B" "$PR_A" "$PR_B"; do
    set_stdin '"my-session"' "$pr"
    run_sl "$bash_bin" "$script" >/dev/null
  done
  settle
  if [ "$(sentinel_count)" = "1" ]; then
    pass_case "early-alternating [$label]"
  else
    fail_case "early-alternating [$label]" \
      "署名が交互に変わる間に gh が $(sentinel_count) 回呼ばれた (期待 1 回)"
  fi
}

# --- early-two-sessions: 同じブランチを開いた 2 つのセッションの署名が食い違っても、起動し続けない ---
# .seen はセッションごとなので、それぞれの最初の 1 回 (計 2 回) で止まる。最低間隔が過ぎた後も同じ。
case_early_two_sessions() {
  local bash_bin=$1 script=$2 label=$3 i
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_fresh
  set_stdin '"my-session-1"' "$PR_A"
  run_sl "$bash_bin" "$script" >/dev/null
  wait_calls 1 || true
  set_stdin '"my-session-2"' "$PR_B"
  run_sl "$bash_bin" "$script" >/dev/null
  if ! wait_calls 2; then
    fail_case "early-two-sessions [$label]" "それぞれの最初の前倒しが起動しない (gh 呼び出し $(sentinel_count) 回)"
    return
  fi
  write_seen my-session-1 "$(( $(date +%s) - 100 ))" "$SIG_A"
  write_seen my-session-2 "$(( $(date +%s) - 100 ))" "$SIG_B"
  for i in 1 2 3; do
    set_stdin '"my-session-1"' "$PR_A"
    run_sl "$bash_bin" "$script" >/dev/null
    set_stdin '"my-session-2"' "$PR_B"
    run_sl "$bash_bin" "$script" >/dev/null
  done
  settle
  if [ "$(sentinel_count)" = "2" ]; then
    pass_case "early-two-sessions [$label]"
  else
    fail_case "early-two-sessions [$label]" \
      "2 つのセッションの描画が交互に続く間に gh が $(sentinel_count) 回呼ばれた (期待 2 回)"
  fi
}

# --- early-mr: pr.kind が mr (GitLab の MR) なら前倒しせず、.seen も作らない ---
case_early_mr() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  seed_fresh
  set_stdin '"my-session"' \
    '{"number":5,"url":"https://gitlab.com/my-org/my-project/-/merge_requests/5","review_state":"pending","kind":"mr"}'
  run_sl "$bash_bin" "$script" >/dev/null
  run_sl "$bash_bin" "$script" >/dev/null
  settle
  if [ "$(sentinel_count)" = "0" ] && [ ! -e "$(seen_path)" ]; then
    pass_case "early-mr [$label]"
  else
    fail_case "early-mr [$label]" "MR で gh が $(sentinel_count) 回呼ばれた、または .seen が作られた"
  fi
}

# --- early-session-id: session_id が空、許さない文字を含む、128 文字を超えるなら前倒しせず、ファイルも作らない ---
# 英数字と - _ : だけの 128 文字以内なら前倒しする (served: で始まるリモートのセッションと、128 文字ちょうど)。
case_early_session_id() {
  local bash_bin=$1 script=$2 label=$3 spec sid want got seen_files
  local a128 a129
  a128=$(printf 'a%.0s' $(seq 1 128))
  a129="${a128}a"
  for spec in '"";0' 'null;0' '"a/b";0' '"../x";0' '"my session";0' '"セッション";0' '"my.session";0' \
              "\"$a129\";0" '123;1' '"served:my-session_01";1' "\"$a128\";1"; do
    sid=${spec%;*}
    want=${spec##*;}
    setup_case "branch=main;ab=0,0"
    seed_fresh
    set_stdin "$sid" "$PR_A"
    run_sl "$bash_bin" "$script" >/dev/null
    if [ "$want" = "1" ]; then
      wait_calls 1 || true
    else
      settle
    fi
    got=$(sentinel_count)
    seen_files=$(find "$case_dir" -name '*.seen' | wc -l | tr -d ' ')
    cleanup_case
    if [ "$got" != "$want" ] || [ "$seen_files" != "$want" ]; then
      fail_case "early-session-id [$label]" \
        "session_id ${sid:0:40} で gh が ${got} 回呼ばれ、.seen が ${seen_files} 個できた (期待はどちらも ${want})"
      return
    fi
  done
  pass_case "early-session-id [$label]"
}

# --- early-stdin-robust: pr や session_id に改行や制御文字があっても、オブジェクトでない pr でも、
# ほかのフィールドがずれない ---
# 描画は、pr も session_id もない入力の描画と一致する。jq がエラーで終わるとすべてのフィールドが
# 空になり、署名に改行が残ると後ろの session_id がずれる。
case_early_stdin_robust() {
  local bash_bin=$1 script=$2 label=$3 baseline out spec sid pr want_calls want_sig
  setup_case "branch=main;ab=0,0"
  seed_fresh
  baseline=$(run_sl "$bash_bin" "$script")
  cleanup_case
  # 各要素は「session_id;pr;gh の呼び出し回数;.seen の署名」。
  for spec in \
    '"my-session";"https://github.com/my-org/my-project/pull/12";0;' \
    '"my-session";12;0;' \
    '"my-session";[1];0;' \
    '"my-session";true;0;' \
    '"my-session";{"url":null};0;' \
    '"my-\nsession";{"url":"https://github.com/my-org/my-project/pull/12"};0;' \
    '"my-session";{"number":12,"url":"https://github.com/my-org/my-project/pull/12"};1;https://github.com/my-org/my-project/pull/12:' \
    '"my-session";{"url":"https://github.com/my-org/my-project/pull/12\nx","review_state":"pending\u001b[31m"};1;https://github.com/my-org/my-project/pull/12 x:pending [31m'; do
    sid=${spec%%;*}; spec=${spec#*;}
    want_sig=${spec##*;}; spec=${spec%;*}
    want_calls=${spec##*;}; pr=${spec%;*}
    setup_case "branch=main;ab=0,0"
    seed_fresh
    set_stdin "$sid" "$pr"
    out=$(run_sl "$bash_bin" "$script")
    if [ "$want_calls" = "1" ]; then
      wait_calls 1 || true
    else
      settle
    fi
    local got lines=0
    got=$(sentinel_count)
    [ -f "$(seen_path)" ] && lines=$(wc -l < "$(seen_path)" | tr -d ' ')
    local sig
    sig=$(seen_sig)
    cleanup_case
    if [ "$out" != "$baseline" ]; then
      fail_case "early-stdin-robust [$label]" "pr=${pr} で描画がずれた: $out"
      return
    fi
    if [ "$got" != "$want_calls" ] || [ "$sig" != "$want_sig" ] \
       || { [ "$want_calls" = "1" ] && [ "$lines" != "2" ]; }; then
      fail_case "early-stdin-robust [$label]" \
        "session_id=${sid} pr=${pr} で gh が ${got} 回、.seen が ${lines} 行で署名 '${sig}' (期待 ${want_calls} 回、'${want_sig}')"
      return
    fi
  done
  pass_case "early-stdin-robust [$label]"
}

# --- early-no-extra-commands: 署名が変わらない描画と、最低間隔で見送る描画では、外部コマンドの起動が
# 増えない ---
# 主なコマンドを、呼ばれた名前を記録してから本物を exec するラッパーで隠し、pr も session_id もない
# 描画と回数を比べる。コマンドを伴わないサブシェル (組み込みだけの $(...)) の fork は検出できない。
case_early_no_extra_commands() {
  local bash_bin=$1 script=$2 label=$3
  setup_case "branch=main;ab=0,0"
  trap 'cleanup_case; trap - RETURN' RETURN

  local bin="$case_dir/count-bin" log="$case_dir/commands.log" cmd real
  mkdir "$bin"
  for cmd in date stat cksum mkdir rmdir mv mktemp rm cat touch sleep id uname awk tail chmod jq flock; do
    real=$(command -v "$cmd" 2>/dev/null) || continue
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexec "%s" "$@"\n' "$cmd" "$log" "$real" > "$bin/$cmd"
    chmod +x "$bin/$cmd"
  done
  local path="PATH=$bin:$GIT_SHIM_DIR:$GH_SHIM_DIR:$PATH"
  count_render() {
    : > "$log"
    run_sl "$bash_bin" "$script" "$path" >/dev/null
    wc -l < "$log" | tr -d ' '
  }

  seed_fresh
  set_stdin null null
  count_render >/dev/null
  local base same recent
  base=$(count_render)
  write_seen my-session "$(( $(date +%s) - 100 ))" "$SIG_A"
  set_stdin '"my-session"' "$PR_A"
  same=$(count_render)
  write_seen my-session "$(( $(date +%s) - 10 ))" "$SIG_A"
  set_stdin '"my-session"' "$PR_B"
  recent=$(count_render)
  settle
  if [ "$(sentinel_count)" != "0" ]; then
    fail_case "early-no-extra-commands [$label]" "前倒ししない描画で gh が $(sentinel_count) 回呼ばれた (前提が崩れている)"
  elif [ "$same" = "$base" ] && [ "$recent" = "$base" ]; then
    pass_case "early-no-extra-commands [$label] (${base} commands)"
  else
    fail_case "early-no-extra-commands [$label]" \
      "外部コマンドの起動が増えた: 基準 ${base} 回、署名が同じ ${same} 回、最低間隔の中 ${recent} 回"
  fi
}

# --- jq-*: --jq による変換 (候補の選び方、レビュー状態、CI、コメントの件数) ---
#   $4 ケース名 / $5 応答 / $6 期待するキャッシュの fetched_at 以降 (タブを | にしたもの。PR なしは空)
#   $7 repo の fake git 規約 (省略時は push 先のオーナー me)
run_jq_case() {
  local bash_bin=$1 script=$2 label=$3 name=$4 response=$5 expected=$6
  local spec=${7:-"branch=main;ab=0,0;push=origin~main;owner=me"}
  setup_case "$spec"
  trap 'cleanup_case; trap - RETURN' RETURN

  run_sl "$bash_bin" "$script" STATUSLINE_TEST_GH_RESPONSE="$RESPONSES_DIR/$response.json" >/dev/null
  if ! wait_until 5 '[ -s "$(cache_path main)" ]'; then
    fail_case "$name [$label]" "キャッシュが書かれなかった"
    return
  fi
  local got
  got=$(cache_body "$(cache_path main)")
  # PR なしのキャッシュは fetched_at だけなので、cache_body は fetched_at そのものを返す。
  case "$got" in *'|'*) ;; *) got="" ;; esac
  if [ "$got" = "$expected" ]; then
    pass_case "$name [$label]"
  else
    fail_case "$name [$label]" "キャッシュが違う: '$got' (期待 '$expected')"
  fi
}

run_all_cases() {
  local bash_bin=$1 script=$2 label=$3
  local url12="https://github.com/my-org/my-project/pull/12"
  case_invoked                    "$bash_bin" "$script" "$label"
  case_not_invoked_when_disabled  "$bash_bin" "$script" "$label"
  case_non_blocking               "$bash_bin" "$script" "$label"
  case_throttle                   "$bash_bin" "$script" "$label"
  case_single_flight              "$bash_bin" "$script" "$label"
  case_stale_inflight             "$bash_bin" "$script" "$label"
  case_timeout                    "$bash_bin" "$script" "$label"
  case_no_overwrite_by_older      "$bash_bin" "$script" "$label"
  case_branch_switch              "$bash_bin" "$script" "$label"
  case_push_branch_name           "$bash_bin" "$script" "$label"
  case_marker_unwritable          "$bash_bin" "$script" "$label"
  case_gh_failure_keeps_cache     "$bash_bin" "$script" "$label"
  case_env_sanitized              "$bash_bin" "$script" "$label"
  case_no_gh                      "$bash_bin" "$script" "$label"
  case_refresh_interval           "$bash_bin" "$script" "$label"
  case_not_invoked_without_prerequisites "$bash_bin" "$script" "$label"
  case_future_fetched_at          "$bash_bin" "$script" "$label"
  case_comment_count              "$bash_bin" "$script" "$label"
  case_early_on_change            "$bash_bin" "$script" "$label"
  case_early_seen_missing         "$bash_bin" "$script" "$label"
  case_early_mismatch_persists    "$bash_bin" "$script" "$label"
  case_early_branch_switch        "$bash_bin" "$script" "$label"
  case_early_save_failure         "$bash_bin" "$script" "$label"
  case_early_waits_inflight       "$bash_bin" "$script" "$label"
  case_early_inflight_during_lock "$bash_bin" "$script" "$label"
  case_early_min_interval         "$bash_bin" "$script" "$label"
  case_early_seen_bad_time        "$bash_bin" "$script" "$label"
  case_early_alternating          "$bash_bin" "$script" "$label"
  case_early_two_sessions         "$bash_bin" "$script" "$label"
  case_early_mr                   "$bash_bin" "$script" "$label"
  case_early_session_id           "$bash_bin" "$script" "$label"
  case_early_stdin_robust         "$bash_bin" "$script" "$label"
  case_early_no_extra_commands    "$bash_bin" "$script" "$label"
  # 他人の fork の同名ブランチの OPEN より、自分の MERGED (HEAD 一致) を選ぶ。オーナーは大文字小文字を区別しない
  run_jq_case "$bash_bin" "$script" "$label" jq-fork-same-name fork-same-name \
    "12|merged||pass|0|1|$url12"
  # reviewDecision が null でも latestReviews の APPROVED で approved になる
  run_jq_case "$bash_bin" "$script" "$label" jq-review-null-approved review-null-approved \
    "12|open|approved|pass|0|1|$url12"
  # statusCheckRollup が null なら ci は空、totalCommentsCount が null なら件数は 0
  run_jq_case "$bash_bin" "$script" "$label" jq-nullable-fields nullable-fields \
    "12|open|pending||0|1|$url12"
  # MERGED の headRefOid がローカルの HEAD と違えば PR なし
  run_jq_case "$bash_bin" "$script" "$label" jq-merged-head-mismatch merged-head-mismatch ""
  # push 先がない (まだ push していない) ときは base リポジトリのオーナーで候補を絞る。draft / EXPECTED
  run_jq_case "$bash_bin" "$script" "$label" jq-base-owner base-owner \
    "12|draft|pending|pending|0|1|$url12" "branch=main;ab=0,0"
  # push 先のオーナー (me) と違うオーナー (my-org) の PR は拾わない
  run_jq_case "$bash_bin" "$script" "$label" jq-other-owner base-owner ""
  # reviewDecision が null なら latestReviews の CHANGES_REQUESTED を APPROVED より優先する。
  # totalCommentsCount (2 桁) をそのまま件数にする。FAILURE は fail。headRefOid が違えば head_matches=0
  run_jq_case "$bash_bin" "$script" "$label" jq-open-changes-requested open-changes-requested \
    "12|open|changes_requested|fail|14|0|$url12" "branch=main;ab=0,0"
  # REVIEW_REQUIRED は latestReviews に APPROVED があっても pending。PENDING は pending
  run_jq_case "$bash_bin" "$script" "$label" jq-open-review-required open-review-required \
    "12|open|pending|pending|0|1|$url12" "branch=main;ab=0,0"
  # CLOSED (HEAD 一致) は closed で review は空。ERROR は fail
  run_jq_case "$bash_bin" "$script" "$label" jq-closed-error closed-error \
    "12|closed||fail|0|1|$url12" "branch=main;ab=0,0"
}

require_command() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'pr-status-behavior.sh: required command not found: %s\n' "$cmd" >&2
    exit 2
  fi
}

main() {
  require_command jq
  require_command perl
  require_debian_bash_if_requested "$(basename "$0")" "$DEBIAN_BASH"

  printf 'statusline pr token behavior tests\n'
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
