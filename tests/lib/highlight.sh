# shellcheck shell=bash
# ハイライトの指定 (CLAUDE_STATUSLINE_HIGHLIGHT) をテストごとに解決するヘルパ。
#
# highlight/<case> があれば 1 行目を HIGHLIGHT として読む。マーカーが無いケースは空
# (= conf → 既定値。既定は空でどれも塗らない)。
#
# regression.sh / e2e-preview.sh から使う (ドリフト防止のため共有)。
# 結果は呼び出し側の変数 case_highlight に返す。

HIGHLIGHT_LIB_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

highlight_for_case() {
  local path="$HIGHLIGHT_LIB_TESTS_DIR/highlight/$1"
  case_highlight=""
  if [ -f "$path" ]; then
    IFS= read -r case_highlight < "$path" || true
  fi
}
