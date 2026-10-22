# shellcheck shell=bash
# レイアウト文字列 (CLAUDE_STATUSLINE_LAYOUT_LINE1 / _LINE2) をテストごとに解決するヘルパ。
#
# layout/<case> があれば 1 行目を LAYOUT_LINE1、2 行目を LAYOUT_LINE2 として読む
# (空行 = 指定なし)。マーカーが無いケースは両方とも空 = 既定レイアウト。
#
# regression.sh / e2e-preview.sh から使う (ドリフト防止のため共有)。
# 結果は呼び出し側の変数 case_layout_line1 / case_layout_line2 に返す。

LAYOUT_LIB_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

layout_for_case() {
  local path="$LAYOUT_LIB_TESTS_DIR/layout/$1"
  case_layout_line1=""
  case_layout_line2=""
  if [ -f "$path" ]; then
    { IFS= read -r case_layout_line1 || true; IFS= read -r case_layout_line2 || true; } < "$path"
  fi
}
