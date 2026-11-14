# shellcheck shell=bash
# statusline をテストから起動するときの環境を組み立てるヘルパ。全ハーネスは statusline を
# 必ず sl_run 経由で起動する。
#
# 許可リスト方式: `env -i` で継承した環境を捨て、ここで組んだ変数と呼び出し側が渡した変数だけを
# statusline に渡す。開発者の shell が export した CLAUDE_STATUSLINE_* / FORCE_HYPERLINK /
# COLORFGBG / CLAUDE_CONFIG_DIR / HOME は届かない。渡し忘れた変数は「未設定」になるので、
# 本体に新しい環境変数が増えても、開発者の値が黙って混ざることはない。
#
# 既定:
#   PATH                              追加分 (--path):git shim:gh shim:外側の PATH
#                                     (jq / perl / flock などの実コマンドは外側の PATH から使う)
#   HOME                              存在しないパス (conf と settings.json の既定の場所を実ファイルに向けない)
#   TZ                                UTC
#   CLAUDE_CONFIG_DIR                 存在しないパス (theme なし = dark)
#   CLAUDE_STATUSLINE_CONFIG          存在しないパス (conf 無し)
#   CLAUDE_STATUSLINE_GIT_FETCH       0 (本体の既定は 1。実 git fetch に出ない側に倒す)
#   CLAUDE_STATUSLINE_PR_STATUS       0 (同上。gh を起動しない側に倒す)
#
# LANG / LC_* は渡さない (本体が冒頭で LC_ALL=C.UTF-8 にする)。TMPDIR も本体が使わないので渡さない。
#
# 使い方:
#   sl_run [--path DIR]... [--replace-path PATH] [VAR=value]... -- COMMAND [ARG]...
#   例: sl_run --path "$STUBS" CLAUDE_STATUSLINE_PR_STATUS=1 -- "$bash_bin" "$script" < "$fixture"
#
# - 上書きはその 1 回の起動だけに効く (グローバルな状態を持たない)。同じ名前を複数回渡すと、
#   env と同じく後のものが勝つ。ハーネス固有のラッパーは既定値を先に、呼び出し側の値を後に並べる。
# - PATH= は渡せない (shim を書き落とすため)。ディレクトリの追加は --path、外側の PATH を含めない
#   PATH が要るときだけ --replace-path で丸ごと差し替える。--replace-path の空の値と --path との併用は拒否する。
# - conf が GIT_FETCH / PR_STATUS を代入しているときは、それらの env を空にして conf に決めさせる
#   (env は conf に勝つため)。判定は全引数を並べた後、最終的な CLAUDE_STATUSLINE_CONFIG に対して行うので、
#   conf の指定は既定値にも呼び出し側の値にも勝つ。

SL_ENV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=config-file.sh
source "$SL_ENV_LIB_DIR/config-file.sh"

# fake git / fake gh。statusline の git / gh 呼び出しを受け、実ネットワークに出さない。
GIT_SHIM_DIR="$SL_ENV_LIB_DIR/git-shim"
GH_SHIM_DIR="$SL_ENV_LIB_DIR/gh-shim"

sl_run() {
  local extra_path="" replace_path="" config="$NO_CONFIG" name
  local -a vars=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
      --path)
        [ "$#" -ge 2 ] || { printf 'sl_run: --path needs a directory\n' >&2; return 2; }
        extra_path="${extra_path}$2:"
        shift 2
        ;;
      --replace-path)
        # 空の値は「外側の PATH に戻る」と区別できないため拒否する。
        [ "$#" -ge 2 ] && [ -n "$2" ] || { printf 'sl_run: --replace-path needs a non-empty value\n' >&2; return 2; }
        replace_path=$2
        shift 2
        ;;
      PATH=*)
        printf 'sl_run: use --path or --replace-path instead of PATH=\n' >&2
        return 2
        ;;
      CLAUDE_STATUSLINE_CONFIG=*)
        config=${1#*=}
        vars+=("$1")
        shift
        ;;
      [A-Za-z_]*=*)
        vars+=("$1")
        shift
        ;;
      *)
        printf 'sl_run: unknown argument: %s\n' "$1" >&2
        return 2
        ;;
    esac
  done
  if [ "$#" -lt 2 ]; then
    printf 'sl_run: missing -- COMMAND\n' >&2
    return 2
  fi
  shift
  # --replace-path は PATH を丸ごと決めるので、--path と併用すると追加分が黙って捨てられる。併用は拒否する。
  if [ -n "$replace_path" ] && [ -n "$extra_path" ]; then
    printf 'sl_run: --path and --replace-path cannot be combined\n' >&2
    return 2
  fi

  local path=${replace_path:-"${extra_path}$GIT_SHIM_DIR:$GH_SHIM_DIR:$PATH"}
  local -a env_args=(
    "PATH=$path"
    "HOME=/nonexistent-home"
    "TZ=UTC"
    "CLAUDE_CONFIG_DIR=/nonexistent-claude-config-dir"
    "CLAUDE_STATUSLINE_CONFIG=$NO_CONFIG"
    "CLAUDE_STATUSLINE_GIT_FETCH=0"
    "CLAUDE_STATUSLINE_PR_STATUS=0"
    ${vars[@]+"${vars[@]}"}
  )
  for name in GIT_FETCH PR_STATUS; do
    if conf_sets "$config" "$name"; then env_args+=("CLAUDE_STATUSLINE_$name="); fi
  done
  env -i "${env_args[@]}" "$@"
}
