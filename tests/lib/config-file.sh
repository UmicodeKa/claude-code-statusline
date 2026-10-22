# shellcheck shell=bash
# statusline の設定ファイル (CLAUDE_STATUSLINE_CONFIG) をテストごとに解決するヘルパ。
#
# 既定の読み込み先 ~/.claude/statusline.conf は $HOME 依存なので、テストで固定し
# 忘れると開発者の実 conf を読んで環境依存で落ちる/通るテストになる。全ハーネスは
# statusline 起動時の共通前置きで、必ず config_for_case の結果 (または NO_CONFIG) を
# CLAUDE_STATUSLINE_CONFIG に渡すこと。
#
# regression.sh / e2e-preview.sh / git-fetch-behavior.sh から使う (ドリフト防止のため共有)。

CONFIG_LIB_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 存在しないパス = conf 無し。
NO_CONFIG="$CONFIG_LIB_TESTS_DIR/nonexistent/statusline.conf"

# config-file/<case> があればそのパスを、無ければ NO_CONFIG を返す。
# ディレクトリも置ける (「読めない conf は黙って無視する」の検証用) ので -e で判定する。
config_for_case() {
  local path="$CONFIG_LIB_TESTS_DIR/config-file/$1"
  if [ -e "$path" ]; then
    printf '%s' "$path"
  else
    printf '%s' "$NO_CONFIG"
  fi
}
