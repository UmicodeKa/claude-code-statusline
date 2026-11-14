# shellcheck shell=bash
# statusline の設定ファイル (CLAUDE_STATUSLINE_CONFIG) をテストごとに解決するヘルパ。
#
# 既定の読み込み先 ~/.claude/statusline.conf は $HOME 依存なので、テストで固定し
# 忘れると開発者の実 conf を読んで環境依存で落ちる/通るテストになる。statusline の起動は
# lib/statusline-env.sh の sl_run が担い、CLAUDE_STATUSLINE_CONFIG の既定を NO_CONFIG にする。
# ケースごとの conf は config_for_case の結果を sl_run に渡す。
#
# lib/statusline-env.sh (NO_CONFIG / conf_sets) と、config-file マーカーを読むハーネスから使う。

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

# conf $1 が設定 $2 (例: PR_STATUS) を代入していれば 0 を返す。
# GIT_FETCH / PR_STATUS は本体の既定が 1 のため、sl_run は env で 0 を渡す。env は conf に勝つので、
# conf でこれらを指定するときは env を空にして conf に決めさせる必要がある。判定は sl_run だけが行う。
conf_sets() {
  [ -f "$1" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?$2=" "$1"
}
