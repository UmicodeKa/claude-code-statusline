#!/usr/bin/env bash
# statusline 出力フォーマットの回帰テスト。
#
# fixtures/*.json を両 statusline スクリプトに食わせ、assertions/*.txt の
# 期待 (equals/contains/not_contains/matches) と突き合わせる。
#
# 本番履歴 dir の汚染を防ぐため CLAUDE_STATUSLINE_HISTORY_DIR を mktemp で
# 作った一時 dir に向け、実行終了後にその dir を削除する。実 uid 環境で
# 動くので所有者チェックを pass し、初回起動時の history_push (HISTORY_LEN
# 件の現在値埋め) が動作する。結果としてチャート部にも現在値の spark 文字が
# 出力され、フォーマットを全カラム検証できる。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURES_DIR="$TESTS_DIR/fixtures"
ASSERTIONS_DIR="$TESTS_DIR/assertions"
# seeds/<case>.txt があればそのケースの履歴 dir に rate 履歴として仕込む。
# 大多数のケースは seed を持たず、空の履歴 dir で初回 push 経路を通る。
SEEDS_DIR="$TESTS_DIR/seeds"
# disable-history/<case> があればそのケースで HISTORY_DIR を安全性チェックで
# 無効化させる (symlink を CLAUDE_STATUSLINE_HISTORY_DIR に渡す = 本体の symlink
# ガード発動経路そのもの)。履歴無効でも右端 = 現在値が保たれることを検証する。
DISABLE_HISTORY_DIR="$TESTS_DIR/disable-history"
# show-model-off/<case> があればそのケースで CLAUDE_STATUSLINE_SHOW_MODEL_NAME=0 を
# 渡してモデル名非表示 (✻ <effort> のみ) を検証する。マーカーが無ければ既定の 1 (表示)。
SHOW_MODEL_OFF_DIR="$TESTS_DIR/show-model-off"
# git-fetch-on/<case> があればそのケースで CLAUDE_STATUSLINE_GIT_FETCH=1 を渡し、
# バックグラウンド fetch 有効時も描画出力が不変であることを検証する。マーカーが無ければ
# 既定の 0 (無効)。fetch 自体は fake git の no-op なので実ネットワークには出ない。
GIT_FETCH_ON_DIR="$TESTS_DIR/git-fetch-on"
# show-cwd-off/<case> があればそのケースで CLAUDE_STATUSLINE_SHOW_CWD=0 を渡し、
# 1 行目の directory 列だけが消えること (2 行構成そのものは維持) を検証する。
# マーカーが無ければ既定の 1 (表示)。
SHOW_CWD_OFF_DIR="$TESTS_DIR/show-cwd-off"
# config-file/<case> があればそのケースだけ CLAUDE_STATUSLINE_CONFIG をそのパスに向け、
# 中身を設定ファイル (~/.claude/statusline.conf 相当) として読み込ませる。
# マーカーが無いケースは存在しないパスに固定する (lib/config-file.sh)。
# layout/<case> があればそのケースで 1 行目 / 2 行目のレイアウト文字列を
# CLAUDE_STATUSLINE_LAYOUT_LINE1 / _LINE2 に渡す (lib/layout.sh)。無ければ既定レイアウト。
# pr-cache/<case> があればそのケースの履歴 dir に PR の状態表示のキャッシュとマーカーを仕込む
# (lib/pr-cache.sh)。マーカーが新しいので描画は取得を起動しない。
# hyperlink-off/<case> があればそのケースで FORCE_HYPERLINK=0 を渡す (OSC 8 を出さない)。
# マーカーが無ければ空文字を渡す (開発者の shell の値を混ぜない)。
HYPERLINK_OFF_DIR="$TESTS_DIR/hyperlink-off"
# pr-status-on/<case> があればそのケースで CLAUDE_STATUSLINE_PR_STATUS=1 を渡す (PR の状態を表示する)。
PR_STATUS_ON_DIR="$TESTS_DIR/pr-status-on"

# shellcheck source=lib/config-file.sh
source "$TESTS_DIR/lib/config-file.sh"
# shellcheck source=lib/layout.sh
source "$TESTS_DIR/lib/layout.sh"
# shellcheck source=lib/pr-cache.sh
source "$TESTS_DIR/lib/pr-cache.sh"
# shellcheck source=lib/escape-ansi.sh
source "$TESTS_DIR/lib/escape-ansi.sh"
# shellcheck source=lib/find-debian-bash.sh
source "$TESTS_DIR/lib/find-debian-bash.sh"
# shellcheck source=lib/is-macos-host.sh
source "$TESTS_DIR/lib/is-macos-host.sh"

# branch 取得経路は lib/git-shim/git (fake git) で検証する。statusline 実行時に
# PATH 先頭へこの dir を差し込み、本物の git を覆い隠す。fixture の current_dir に
# 埋めた #branch=<name> / #detached の規約を fake git が読んでブランチ名を返す。
GIT_SHIM_DIR="$TESTS_DIR/lib/git-shim"
# PR の状態表示の取得は lib/gh-shim/gh (fake gh) が受ける。既定では何もせずに失敗するので、
# 取得が起動されても実ネットワークには出ず、仕込んだキャッシュも書き換えない。
GH_SHIM_DIR="$TESTS_DIR/lib/gh-shim"

MACOS_SCRIPT="$REPO_DIR/statusline-macos.sh"
DEBIAN_SCRIPT="$REPO_DIR/statusline-linux.sh"

# Linux 版は bash 4.1+ 必須。見つからなければ Linux 版のケースを skip する。
DEBIAN_BASH="$(find_debian_bash)"
# macOS 版は BSD 系コマンド前提。macOS ホストでなければ macOS 分のケースを skip する。
RUN_MACOS=0
is_macos_host && RUN_MACOS=1

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }

# 各 assertion 行を評価する。引数:
#   $1: 実出力 (ANSI 可読化済み)
#   $2: assertion ファイルのパス
# env 経由 (呼び出し側が前置きで渡す):
#   exit_code: statusline の終了コード (assertion `exit_code:` 用)
#   hist_dir:  そのケースの履歴 dir (assertion `fetch_marker:` 用)
# 戻り値: 全アサーション通れば 0、いずれか失敗で 1
check_assertions() {
  local output=$1
  local assertion_file=$2
  local line kind expected
  local failed=0

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    kind="${line%%:*}"
    # `expected` の切り出しは ": " (コロン + 半角スペース) 区切りが前提。
    # 区切りが無い行では ${line#*: } が **行全体をそのまま返す** ため、
    # 種別だけ合っていてアサーションが黙って無効化される
    # (例: 引数を使わない no_line2 は素通しで pass、matches_line2 は行全体が ERE になる)。
    # 書き間違いを検証漏れにしないよう、ここで明示的に落とす。
    case "$line" in
      *': '*) expected="${line#*: }" ;;
      *)
        printf '    [FAIL] malformed assertion (": " 区切りが無い): %s\n' "$line" >&2
        failed=1
        continue
        ;;
    esac
    case "$kind" in
      equals)
        if [ "$output" != "$expected" ]; then
          printf '    [FAIL] equals: %s\n' "$expected" >&2
          printf '      actual: %s\n' "$output" >&2
          failed=1
        fi
        ;;
      contains)
        if ! printf '%s' "$output" | grep -qF -- "$expected"; then
          printf '    [FAIL] contains: %s\n' "$expected" >&2
          failed=1
        fi
        ;;
      not_contains)
        if printf '%s' "$output" | grep -qF -- "$expected"; then
          printf '    [FAIL] not_contains: %s\n' "$expected" >&2
          printf '      actual: %s\n' "$output" >&2
          failed=1
        fi
        ;;
      matches)
        # bash の =~ 演算子。expected は ERE。
        # 注意: glibc regcomp は UTF-8 マルチバイト文字の範囲 (例 [▁-█]) を
        # 解釈しないため、assertion 側ではスパーク文字を列挙する ([▁▂▃▄▅▆▇█])。
        # 出力全体 (2 行なら改行込み) を 1 つの文字列として評価するため、
        # 行単位で両端アンカーしたいときは matches_line1 / matches_line2 を使う。
        if ! [[ "$output" =~ $expected ]]; then
          printf '    [FAIL] matches: %s\n' "$expected" >&2
          printf '      actual: %s\n' "$output" >&2
          failed=1
        fi
        ;;
      matches_line1)
        # 出力の 1 行目だけを ERE で評価する。`$` が 1 行目の末尾に効くので、
        # 2 行構成でも「1 行目がちょうどこの形」を両端アンカーで表現できる。
        local line1="${output%%$'\n'*}"
        if ! [[ "$line1" =~ $expected ]]; then
          printf '    [FAIL] matches_line1: %s\n' "$expected" >&2
          printf '      actual(line1): %s\n' "$line1" >&2
          failed=1
        fi
        ;;
      matches_line2)
        # 出力の 2 行目だけを ERE で評価する。2 行目が無ければ失敗させる
        # (「2 行目が出ること」自体もこの assertion の検証対象)。
        # 注意: ここで `continue` を使うと case ではなく **while read ループ** が
        # 進み、そのファイルの残りのアサーションが丸ごと skip される。
        # 必ず if/else で分岐させること。
        local line2
        if [ "$output" = "${output%%$'\n'*}" ]; then
          printf '    [FAIL] matches_line2: %s\n' "$expected" >&2
          printf '      actual: 2 行目が無い (出力は 1 行のみ)\n' >&2
          failed=1
        else
          line2="${output#*$'\n'}"
          if ! [[ "$line2" =~ $expected ]]; then
            printf '    [FAIL] matches_line2: %s\n' "$expected" >&2
            printf '      actual(line2): %s\n' "$line2" >&2
            failed=1
          fi
        fi
        ;;
      not_contains_line1)
        # 1 行目だけを対象にした部分一致の否定。2 行化で 1 行目が directory/branch/
        # session_name 行になったため、「1 行目に出ないこと」を検証したい既存の
        # 意図は not_contains では表現できなくなった。
        local nc_line1="${output%%$'\n'*}"
        if printf '%s' "$nc_line1" | grep -qF -- "$expected"; then
          printf '    [FAIL] not_contains_line1: %s\n' "$expected" >&2
          printf '      actual(line1): %s\n' "$nc_line1" >&2
          failed=1
        fi
        ;;
      not_contains_line2)
        # 2 行目だけを対象にした部分一致の否定。1 行目由来の文字 (rate の "-" 等) を
        # 誤検知せずに「2 行目に出ないこと」を検証する。2 行目が無ければ自明に pass。
        local nc_line2=""
        if [ "$output" != "${output%%$'\n'*}" ]; then nc_line2="${output#*$'\n'}"; fi
        if printf '%s' "$nc_line2" | grep -qF -- "$expected"; then
          printf '    [FAIL] not_contains_line2: %s\n' "$expected" >&2
          printf '      actual(line2): %s\n' "$nc_line2" >&2
          failed=1
        fi
        ;;
      no_line2)
        # 出力が 1 行だけであることを検証する。行入れ替え後は条件付きで省略されるのが
        # 1 行目 (directory/branch/session_name) なので、本種別は「1 行目が省略され
        # モデル行だけが残る」ケースで使う (種別名は互換のため据え置き)。
        # アサーションの不在は検証にならないため、空行を出さない不変条件は
        # この種別を明示的に置いて守る。expected は使わない (慣例として "true")。
        #
        # 注意: 素の $( ... ) は**末尾の改行を全て除去する**ため、「1 行目 + 余分な改行」
        # だけを出す退行 (= 空行が statusline の高さを 1 行占有する、まさにこの種別が
        # 防ぎたい回帰) は観測できない。run_case はセンチネル経由で末尾改行を保持した
        # `output_raw` を渡すので、そちらで判定する。
        # 正常系は行末の改行 1 個で終わるので、**まず終端の 1 個だけを剥がし**、
        # それでも改行が残っていれば 2 行目 (空行を含む) が出ている。
        local nl2_body="${output_raw-}"
        nl2_body="${nl2_body%$'\n'}"
        if [ "$nl2_body" != "${nl2_body%%$'\n'*}" ]; then
          printf '    [FAIL] no_line2: 出力が 2 行以上ある (省略されるはずの 1 行目や空行を出してはいけない)\n' >&2
          printf '      actual: %s\n' "$output" >&2
          failed=1
        fi
        ;;
      fetch_marker)
        # present / absent。maybe_git_fetch は fetch を投げる直前に間引きマーカー
        # ${HISTORY_DIR}/fetch-<key> を **同期的に** 作る。fetch 自体は投げっぱなしの
        # 非同期処理だが、マーカーの有無なら競合なく判定できるので「fetch を投げたか
        # skip したか」の検証にこれを使う。
        # ロックファイル (Linux 版の .lock / macOS の .lockd) も fetch-* に一致するため
        # 除外する。Linux 版は upstream 未設定ケースでも lockfile を作るので、
        # 除外しないと absent を present と誤判定する。
        local marker found=absent
        for marker in "${hist_dir:-/nonexistent}"/fetch-*; do
          case "$marker" in
            *.lock|*.lockd) continue ;;
          esac
          [ -e "$marker" ] && { found=present; break; }
        done
        if [ "$found" != "$expected" ]; then
          printf '    [FAIL] fetch_marker: %s\n' "$expected" >&2
          printf '      actual: %s\n' "$found" >&2
          failed=1
        fi
        ;;
      exit_code)
        # 第二引数として渡された期待 exit code と比較する。
        if [ "${exit_code:-x}" != "$expected" ]; then
          printf '    [FAIL] exit_code: %s\n' "$expected" >&2
          printf '      actual: %s\n' "${exit_code:-?}" >&2
          failed=1
        fi
        ;;
      *)
        printf '    [FAIL] unknown assertion kind: %s\n' "$kind" >&2
        failed=1
        ;;
    esac
  done < "$assertion_file"

  return $failed
}

# 1 fixture × 1 script を実行する。引数:
#   $1: fixture path
#   $2: assertion path
#   $3: target script path
#   $4: ラベル (表示用)
#   $5: 使用する bash 実行ファイル
#
# statusline が非ゼロ終了したり escape_ansi 側でこけても、ハーネス全体を
# 落とさず「そのケースが失敗した」として扱う。exit_code は assertion 種別
# `exit_code:` に渡るので、必要なケースでは「0 で終わること」を明示できる。
run_case() {
  local fixture=$1 assertion=$2 script=$3 label=$4 bash_bin=$5
  local case_name
  case_name="$(basename "$fixture" .json)"

  # 1 ケースごとに新しい一時 dir を作り、本番履歴 dir には触れない。
  # cleanup は trap で確実に走らせ、output 取得時の代入失敗時も孤児にしない。
  local hist_dir
  hist_dir="$(mktemp -d -t claude-statusline-test.XXXXXX)"

  # shellcheck disable=SC2064
  trap "rm -r '$hist_dir' 2>/dev/null || true" RETURN

  # seed があれば古い rate 履歴として仕込む。コピー直後の mtime は現在に近いため
  # statusline 内の history_push は POLL_INTERVAL_SEC 内と判定して skip する。
  # 結果、仕込んだ古い履歴がそのまま history_chart に読まれ、右端の現在値差し替え
  # (左 5 文字 = 古い値、右端 1 文字 = 現在値) を検証できる。
  local seed="$SEEDS_DIR/${case_name}.txt"
  if [ -f "$seed" ]; then
    cp "$seed" "$hist_dir/rate"
  fi

  seed_pr_cache_for_case "$case_name" "$fixture" "$hist_dir"

  # disable-history/<case> があれば HISTORY_DIR を symlink に向けて本体の
  # symlink ガードを発動させ、履歴機能を無効化した状態を作る。statusline は
  # この override 先が symlink だと HISTORY_DIR="" にする (履歴なしで継続)。
  local hist_override="$hist_dir"
  if [ -f "$DISABLE_HISTORY_DIR/${case_name}" ]; then
    ln -s "$hist_dir" "$hist_dir.link"
    hist_override="$hist_dir.link"
    # shellcheck disable=SC2064
    trap "rm -r '$hist_dir' 2>/dev/null || true; rm '$hist_dir.link' 2>/dev/null || true" RETURN
  fi

  # 起動時の共通前置きについて:
  # - CLAUDE_STATUSLINE_COLOR_SCHEME="" は開発者の shell の env が conf に勝って
  #   ケースが環境依存になるのを防ぐ (他の CLAUDE_STATUSLINE_* も下記マーカー経由で必ず渡す)。
  # - 短縮名 (SHOW_MODEL_NAME=0 / LAYOUT_LINE1 等) を全ケースで既定値と異なる値で渡す。本体は conf 読み込み前に
  #   これらを unset するので出力に影響しない。unset を消すと全ケースが落ちる回帰ガード。
  #
  # 以下の env は、マーカーが無いとき空文字を渡す。本体は `${CLAUDE_STATUSLINE_X:-...}`
  # で読むため空は未設定と同じ扱いになり、conf (config-file マーカー) の値 → 既定値の順に
  # フォールバックする。既定値を直接渡すと conf の値が常に env に負けて検証できない。

  # show-model-off/<case> があればモデル名非表示 (✻ <effort> のみ) を再現する。
  # 既定は 1 (表示) なので、マーカーの無い既存ケースは従来どおり ✻ <model> を出す。
  local show_model_name=""
  if [ -f "$SHOW_MODEL_OFF_DIR/${case_name}" ]; then show_model_name="0"; fi

  # git-fetch-on/<case> があればバックグラウンド fetch を有効化する (既定は 0 = 無効)。
  local git_fetch=""
  if [ -f "$GIT_FETCH_ON_DIR/${case_name}" ]; then git_fetch="1"; fi

  # show-cwd-off/<case> があれば directory 列を非表示にする (既定は 1 = 表示)。
  local show_cwd=""
  if [ -f "$SHOW_CWD_OFF_DIR/${case_name}" ]; then show_cwd="0"; fi

  # hyperlink-off/<case> があれば OSC 8 のリンクを出さない (既定は空 = リンクあり)。
  local force_hyperlink=""
  if [ -f "$HYPERLINK_OFF_DIR/${case_name}" ]; then force_hyperlink="0"; fi

  # pr-status-on/<case> があれば PR の状態表示を有効化する (既定は 0 = 無効)。
  local pr_status=""
  if [ -f "$PR_STATUS_ON_DIR/${case_name}" ]; then pr_status="1"; fi

  # config-file/<case> があればそれを設定ファイルとして読ませる (無ければ conf 無し)。
  local config
  config="$(config_for_case "$case_name")"

  # layout/<case> があればレイアウト文字列を渡す (無ければ空 = conf → 既定値)。
  local case_layout_line1 case_layout_line2
  layout_for_case "$case_name"

  # set -e + command substitution の組み合わせは、子プロセスが非ゼロ終了
  # した時点でハーネス全体を即死させる。`|| rc=$?` で吸収し、終了コードを
  # 別変数に取り出してアサーション側で扱えるようにする。pipefail 配下でも
  # rc にはパイプライン全体の終了コード (右端を含む最右の非ゼロ) が入る。
  #
  # PATH 先頭に git-shim を差し込み、statusline 本体の git 呼び出しを fake git
  # に差し替える。fixture の current_dir に埋めた #branch=... 規約が反映される。
  local output output_raw rc=0
  # $( ... ) は末尾の改行を**全て**除去するため、「1 行目の後に余分な改行だけを出す」
  # 退行 (空行が statusline の高さを 1 行占有する) が output からは観測できない。
  # センチネル文字を足してから取得し、末尾 1 個だけを剥がすことで、スクリプトが出した
  # 末尾改行をそのまま保持した output_raw を作る。no_line2 はこちらを見る。
  # センチネルは終了コードに **関わらず** 必ず付ける (`&&` ではなく `;` で連結する)。
  # `&&` にすると非ゼロ終了のケースでセンチネルが付かず、output_raw が末尾改行を
  # 失うため、`exit_code` 非ゼロ + `no_line2` を併記したケースが将来追加されたときに
  # そのアサーションが黙って空振り pass する。終了コードは rc_line 経由で別途拾う。
  output_raw=$(
    {
      CLAUDE_STATUSLINE_HISTORY_DIR="$hist_override" TZ=UTC \
      CLAUDE_STATUSLINE_CONFIG="$config" \
      CLAUDE_STATUSLINE_COLOR_SCHEME="" \
      SHOW_MODEL_NAME=0 COLOR_SCHEME=light GIT_FETCH=1 PR_STATUS=1 SHOW_CWD=0 \
      POLL_INTERVAL_SEC=0 GIT_FETCH_INTERVAL_SEC=0 \
      LAYOUT_LINE1="session" LAYOUT_LINE2="rate|model_ctx" \
      CLAUDE_STATUSLINE_SHOW_MODEL_NAME="$show_model_name" \
      CLAUDE_STATUSLINE_GIT_FETCH="$git_fetch" \
      CLAUDE_STATUSLINE_PR_STATUS="$pr_status" \
      CLAUDE_STATUSLINE_SHOW_CWD="$show_cwd" \
      CLAUDE_STATUSLINE_LAYOUT_LINE1="$case_layout_line1" \
      CLAUDE_STATUSLINE_LAYOUT_LINE2="$case_layout_line2" \
      FORCE_HYPERLINK="$force_hyperlink" \
      PATH="$GIT_SHIM_DIR:$GH_SHIM_DIR:$PATH" \
        "$bash_bin" "$script" < "$fixture" 2>&1 | escape_ansi
    }
    printf 'X%s' "$?"
  )
  # 末尾は "X<rc>" で終わる。rc を切り出してからセンチネルごと剥がす。
  rc="${output_raw##*X}"
  output_raw="${output_raw%X*}"
  # 正常系はスクリプトが必ず末尾に改行 1 個を出すので "…\n" で終わる。
  # 末尾改行 1 個を落とすと従来の output と一致する。
  output="${output_raw%$'\n'}"

  if exit_code="$rc" hist_dir="$hist_dir" output_raw="$output_raw" \
    check_assertions "$output" "$assertion"; then
    printf '  %s %s [%s]\n' "$(green ok)" "$case_name" "$label"
    return 0
  else
    printf '  %s %s [%s]\n' "$(red FAIL)" "$case_name" "$label"
    return 1
  fi
}

# Linux 版冒頭の bash 4.1+ ゲートが残っていることを静的に確認する。
# 実際に旧 bash で起動させて確認するのは難しいため、ガードブロックの **実コード片**
# が冒頭近傍に **完全一致** で存在することを比較する。コメント中のキーワード一致では
# 弾けないドリフト (例: コメントだけ残してコードを消す) もここで検出できる。
check_bash_version_gate() {
  printf '  '
  local expected actual
  read -r -d '' expected <<'EXPECTED' || true
if [ -z "${BASH_VERSINFO+x}" ] \
   || [ "${BASH_VERSINFO[0]}" -lt 4 ] \
   || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 1 ]; }; then
  printf '✻ -- (bash 4.1+ required)\n'
  exit 0
fi
EXPECTED
  # 冒頭 20 行に限定 (ファイル末尾のコメント等にコピペされても素通りしないため)。
  # bash の `==` パターン照合は複数行リテラルを一塊で比較できるので、grep -F の
  # 行単位 OR マッチ問題 (1 行でも合えば match) を回避できる。
  actual="$(sed -n '1,20p' "$DEBIAN_SCRIPT")"
  if [[ "$actual" == *"$expected"* ]]; then
    printf '%s bash-4.1-gate (Linux script)\n' "$(green ok)"
    return 0
  else
    printf '%s bash-4.1-gate (Linux script): guard block not found at top of %s\n' \
      "$(red FAIL)" "$DEBIAN_SCRIPT" >&2
    return 1
  fi
}

# 環境チェック (必要コマンドが揃っているか)
require_command() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'regression.sh: required command not found: %s\n' "$cmd" >&2
    exit 2
  fi
}

main() {
  require_command jq
  require_debian_bash_if_requested "$(basename "$0")" "$DEBIAN_BASH"
  require_command perl
  require_command bash

  printf 'statusline regression tests\n'
  printf 'scripts:\n  macOS:  %s\n  Linux:  %s\n' "$MACOS_SCRIPT" "$DEBIAN_SCRIPT"
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

  local total=0 failed=0 skipped_macos=0 skipped_debian=0
  local fixture assertion case_name

  for fixture in "$FIXTURES_DIR"/*.json; do
    case_name="$(basename "$fixture" .json)"
    assertion="$ASSERTIONS_DIR/${case_name}.txt"
    if [ ! -f "$assertion" ]; then
      printf '  %s %s: assertion file missing (%s)\n' \
        "$(red FAIL)" "$case_name" "$assertion" >&2
      failed=$((failed + 1))
      total=$((total + 1))
      continue
    fi

    if [ "$RUN_MACOS" -eq 1 ]; then
      total=$((total + 1))
      run_case "$fixture" "$assertion" "$MACOS_SCRIPT" macOS /bin/bash \
        || failed=$((failed + 1))
    else
      skipped_macos=$((skipped_macos + 1))
    fi

    if [ -n "$DEBIAN_BASH" ]; then
      total=$((total + 1))
      run_case "$fixture" "$assertion" "$DEBIAN_SCRIPT" Linux "$DEBIAN_BASH" \
        || failed=$((failed + 1))
    else
      skipped_debian=$((skipped_debian + 1))
    fi
  done

  total=$((total + 1))
  check_bash_version_gate || failed=$((failed + 1))

  printf '\n'
  if [ "$failed" -eq 0 ]; then
    printf '%s: %d/%d passed' "$(green PASS)" "$total" "$total"
    if [ "$skipped_macos" -gt 0 ]; then
      printf ' (%d macOS cases skipped: need macOS host)' "$skipped_macos"
    fi
    if [ "$skipped_debian" -gt 0 ]; then
      printf ' (%d Linux cases skipped: need bash 4.1+ and flock)' "$skipped_debian"
    fi
    printf '\n'
    exit 0
  else
    printf '%s: %d/%d failed\n' "$(red FAIL)" "$failed" "$total" >&2
    exit 1
  fi
}

main "$@"
