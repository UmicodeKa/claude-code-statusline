#!/usr/bin/env bash
# 人間目視用の E2E プレビュー。
#
# regression.sh は ANSI シーケンスをエスケープして文字列比較するが、
# こちらは実際の ANSI を端末に流して **色とフォーマットを肉眼で確認** する。
# 履歴は CLAUDE_STATUSLINE_HISTORY_DIR で mktemp 一時 dir に隔離し、
# 各ケース終了後にその dir を削除する。
#
# rate チャートは「均一に並ぶ」初回起動の見た目ではなく、右肩下がり (古い値ほど
# 残量多) の遷移として表示するためダミー履歴を仕込む。最右端は fixture の現在値に
# 揃える。ctx は履歴を持たず、現在値の 1 文字 spark だけが描かれる。
# statusline 内の history_push は POLL_INTERVAL_SEC (既定 300 秒) のサンプリング間引きで
# 直後の追記を skip するため、仕込んだダミーがそのまま history_chart に読まれる。
#
# branch 取得経路は regression.sh と同じく lib/git-shim/git (fake git) で再現する。
# fixture の current_dir に埋めた #branch=<name> / #detached 規約を fake git が読む。
#
# Usage:
#   bash tests/e2e-preview.sh           # 環境を自動判定
#   bash tests/e2e-preview.sh --macos   # macOS 版のみ
#   bash tests/e2e-preview.sh --linux   # Linux 版のみ

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURES_DIR="$TESTS_DIR/fixtures"
# show-model-off/<case> があればそのケースを SHOW_MODEL_NAME=0 (モデル名非表示) で表示する。
SHOW_MODEL_OFF_DIR="$TESTS_DIR/show-model-off"
# show-cwd-off/<case> があればそのケースを SHOW_CWD=0 (directory 列なし) で表示する。
SHOW_CWD_OFF_DIR="$TESTS_DIR/show-cwd-off"
# config-file/<case> があればそのケースだけ中身を設定ファイルとして読ませる。
# shellcheck source=lib/config-file.sh
source "$TESTS_DIR/lib/config-file.sh"
# layout/<case> があればそのケースをそのレイアウト文字列で表示する。
# shellcheck source=lib/layout.sh
source "$TESTS_DIR/lib/layout.sh"
# pr-cache/<case> があればそのケースの履歴 dir に PR の状態表示のキャッシュを仕込む。
# shellcheck source=lib/pr-cache.sh
source "$TESTS_DIR/lib/pr-cache.sh"
# hyperlink-off/<case> があればそのケースを FORCE_HYPERLINK=0 (OSC 8 なし) で表示する。
HYPERLINK_OFF_DIR="$TESTS_DIR/hyperlink-off"
# pr-status-on/<case> があればそのケースを PR_STATUS=1 (PR の状態を表示) で表示する。
PR_STATUS_ON_DIR="$TESTS_DIR/pr-status-on"

# branch 取得経路を fake git で差し替えるための shim ディレクトリ。
# statusline 実行時に PATH 先頭へ差し込み、本物の git を覆い隠す。
GIT_SHIM_DIR="$TESTS_DIR/lib/git-shim"
# PR の状態表示の取得を fake gh で受け、本物の gh (ネットワーク) に出さないための shim ディレクトリ。
GH_SHIM_DIR="$TESTS_DIR/lib/gh-shim"

MACOS_SCRIPT="$REPO_DIR/statusline-macos.sh"
DEBIAN_SCRIPT="$REPO_DIR/statusline-linux.sh"

MODE=auto
for arg in "$@"; do
  case "$arg" in
    --macos)  MODE=macos ;;
    --linux|--debian) MODE=debian ;;
    --help|-h)
      # Usage ブロック (18-21 行目) も含めるためファイル冒頭の説明全体を出す。
      sed -n '2,21p' "$0"
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

# bash 4.1+ 検出 (Linux 版が動くかの判定)
find_debian_bash() {
  local candidate full_path
  for candidate in bash /opt/homebrew/bin/bash /usr/local/bin/bash; do
    full_path="$(command -v "$candidate" 2>/dev/null || true)"
    [ -z "$full_path" ] && continue
    if "$full_path" -c '
      [ "${BASH_VERSINFO[0]}" -gt 4 ] \
        || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }
    ' >/dev/null 2>&1; then
      printf '%s\n' "$full_path"
      return 0
    fi
  done
  return 1
}

DEBIAN_BASH="$(find_debian_bash || true)"

case "$MODE" in
  auto)
    RUN_MACOS=1
    if [ -n "$DEBIAN_BASH" ]; then RUN_DEBIAN=1; else RUN_DEBIAN=0; fi
    ;;
  macos)
    RUN_MACOS=1
    RUN_DEBIAN=0
    ;;
  debian)
    RUN_MACOS=0
    RUN_DEBIAN=1
    if [ -z "$DEBIAN_BASH" ]; then
      printf 'error: bash 4.1+ not found, cannot run Linux script\n' >&2
      exit 2
    fi
    ;;
esac

print_header() {
  printf '\n\033[1;36m==== %s ====\033[0m\n' "$1"
}

# 現在値 (0-100) から 20 件 (本体が履歴ファイルに残す件数) の履歴系列を組み立て、改行区切りで標準出力に流す。
# 古い側は 100 / 0 で頭打ちになるので、RATE_CHART_LEN を伸ばしたケースでも左端まで遷移が並ぶ。
# trend=down: 最新値が最小、古いほど高い (rate 残量用)。
# 値が空の場合は何も出さない (statusline 側で履歴ファイル無しと同等に扱われる)。
build_history_lines() {
  local current=$1
  local trend=$2
  local step=10
  [ -z "$current" ] && return
  awk -v cur="$current" -v trend="$trend" -v step="$step" -v len=20 '
    BEGIN {
      for (i = 0; i < len; i++) {
        # 古い → 新しいの順に len 行出力。新しい (末尾) を current に揃える。
        offset = (len - 1 - i) * step
        if (trend == "up") {
          v = cur - offset
        } else {
          v = cur + offset
        }
        if (v < 0)   v = 0
        if (v > 100) v = 100
        print v
      }
    }
  '
}

# fixture からダミー rate 履歴ファイルを hist_dir に書き込む。
# 仕込んだ後に statusline が呼ばれると POLL_INTERVAL_SEC 内のため
# history_push は skip され、history_chart はこの 20 件の末尾 RATE_CHART_LEN 件をそのまま読む。
# ctx は履歴を持たないため、seeding は rate だけで十分。
seed_history() {
  local fixture=$1 hist_dir=$2
  local rate_pct rate_remaining
  rate_pct="$(jq -r '.rate_limits.five_hour.used_percentage // ""' "$fixture")"

  if [ -n "$rate_pct" ]; then
    rate_remaining=$((100 - rate_pct))
    build_history_lines "$rate_remaining" down > "$hist_dir/rate"
  fi
}

print_case() {
  local fixture=$1 script=$2 bash_bin=$3 label=$4
  local case_name
  case_name="$(basename "$fixture" .json)"

  local hist_dir
  hist_dir="$(mktemp -d -t claude-statusline-preview.XXXXXX)"
  seed_history "$fixture" "$hist_dir"
  seed_pr_cache_for_case "$case_name" "$fixture" "$hist_dir"
  printf '\n\033[1;33m-- %s [%s] --\033[0m\n' "$case_name" "$label"
  printf 'input: '
  cat "$fixture"
  printf 'output: '
  # マーカーが無いとき env は空文字を渡す (未設定扱い = conf → 既定値へフォールバック)。
  # show-model-off マーカーがあればモデル名非表示 (✻ <effort> のみ) で表示する。
  local show_model_name=""
  if [ -f "$SHOW_MODEL_OFF_DIR/${case_name}" ]; then show_model_name="0"; fi
  # show-cwd-off マーカーがあれば directory 列なし (2 行構成は維持) で表示する。
  local show_cwd=""
  if [ -f "$SHOW_CWD_OFF_DIR/${case_name}" ]; then show_cwd="0"; fi
  # config-file マーカーがあればそれを設定ファイルとして読ませる。無ければ存在しない
  # パスに固定し、開発者の実 ~/.claude/statusline.conf がプレビューへ漏れ込むのを防ぐ。
  # COLOR_SCHEME / GIT_FETCH も空で渡し、開発者の shell の env が conf に勝つのを防ぐ。
  local config
  config="$(config_for_case "$case_name")"
  # layout マーカーがあればそのレイアウト文字列で表示する (無ければ空 = 既定レイアウト)。
  local case_layout_line1 case_layout_line2
  layout_for_case "$case_name"
  # hyperlink-off マーカーがあれば OSC 8 のリンクを出さない (無ければ空 = リンクあり)。
  local force_hyperlink=""
  if [ -f "$HYPERLINK_OFF_DIR/${case_name}" ]; then force_hyperlink="0"; fi
  # pr-status-on マーカーがあれば PR の状態を表示する (無ければ空 = 無効)。
  local pr_status=""
  if [ -f "$PR_STATUS_ON_DIR/${case_name}" ]; then pr_status="1"; fi
  # PATH 先頭に git-shim / gh-shim を差し込み、statusline 本体の git / gh 呼び出しを fake に差し替える。
  CLAUDE_STATUSLINE_HISTORY_DIR="$hist_dir" TZ=UTC \
    CLAUDE_STATUSLINE_CONFIG="$config" \
    CLAUDE_STATUSLINE_SHOW_MODEL_NAME="$show_model_name" \
    CLAUDE_STATUSLINE_COLOR_SCHEME="" CLAUDE_STATUSLINE_GIT_FETCH="" CLAUDE_STATUSLINE_PR_STATUS="$pr_status" \
    CLAUDE_STATUSLINE_SHOW_CWD="$show_cwd" \
    CLAUDE_STATUSLINE_LAYOUT_LINE1="$case_layout_line1" \
    CLAUDE_STATUSLINE_LAYOUT_LINE2="$case_layout_line2" FORCE_HYPERLINK="$force_hyperlink" \
    PATH="$GIT_SHIM_DIR:$GH_SHIM_DIR:$PATH" \
    "$bash_bin" "$script" < "$fixture"
  printf '\n'
  rm -r "$hist_dir" 2>/dev/null || true
  return 0
}

if [ "$RUN_MACOS" -eq 1 ]; then
  print_header "macOS script ($MACOS_SCRIPT)"
  for fixture in "$FIXTURES_DIR"/*.json; do
    print_case "$fixture" "$MACOS_SCRIPT" /bin/bash macOS
  done
fi

if [ "$RUN_DEBIAN" -eq 1 ]; then
  print_header "Linux script ($DEBIAN_SCRIPT, bash=$DEBIAN_BASH)"
  for fixture in "$FIXTURES_DIR"/*.json; do
    print_case "$fixture" "$DEBIAN_SCRIPT" "$DEBIAN_BASH" Linux
  done
fi

printf '\n'
