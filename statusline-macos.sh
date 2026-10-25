#!/bin/bash

# ロケールを C.UTF-8 で固定する。理由は 2 つ:
#   - UTF-8 のスパークライン (▁..█) と ✻ アイコンを確実に表示する
#   - ブランチ名/セッション名のトリムを文字数で行う (`${#var}` はロケール依存で、
#     C ロケールだとバイト数換算になり CJK が早期トリムされてしまう)
export LC_ALL=C.UTF-8

# === ユーザー設定ファイルの読み込み ===
# ~/.claude/statusline.conf が存在すればシェルスクリプトとして読み込む
# (fork を増やさないため JSON 等ではなく `.` で source する)。
# conf には下記カスタマイズ設定の変数名 (SHOW_MODEL_NAME=0 等) をそのまま単純代入で書く。
# 優先順位は env (CLAUDE_STATUSLINE_*) > conf > 既定値。各設定の
# `${CLAUDE_STATUSLINE_X:-${X:-既定値}}` で担保する。
# 読み込み前に対象の変数を unset し、外の環境から同名の変数が紛れ込まないようにする。
# 読めない (存在しない/権限無し/ディレクトリ) ときは黙って無視して描画を続ける。
# 内部定数と clamp はこの後に定義されるため、conf で上書きしても無効/丸められる。
# CLAUDE_STATUSLINE_CONFIG で読み込み先を差し替えられる (回帰テストが実 conf を読まないため)。
STATUSLINE_CONFIG="${CLAUDE_STATUSLINE_CONFIG:-$HOME/.claude/statusline.conf}"
# `/` を含まないパスを `.` に渡すと $PATH から探索されるため、カレント相対に固定する。
case "$STATUSLINE_CONFIG" in */*) ;; *) STATUSLINE_CONFIG="./$STATUSLINE_CONFIG" ;; esac
unset SHOW_MODEL_NAME COLOR_SCHEME GIT_FETCH PR_STATUS SHOW_CWD POLL_INTERVAL_SEC GIT_FETCH_INTERVAL_SEC \
  LAYOUT_LINE1 LAYOUT_LINE2
if [ -f "$STATUSLINE_CONFIG" ] && [ -r "$STATUSLINE_CONFIG" ]; then
  # shellcheck source=/dev/null
  . "$STATUSLINE_CONFIG"
  # CRLF 改行で保存された conf は値の末尾に \r が残り、黙って既定値扱いになるため剥がす。
  SHOW_MODEL_NAME="${SHOW_MODEL_NAME%$'\r'}"
  COLOR_SCHEME="${COLOR_SCHEME%$'\r'}"
  GIT_FETCH="${GIT_FETCH%$'\r'}"
  PR_STATUS="${PR_STATUS%$'\r'}"
  SHOW_CWD="${SHOW_CWD%$'\r'}"
  POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC%$'\r'}"
  GIT_FETCH_INTERVAL_SEC="${GIT_FETCH_INTERVAL_SEC%$'\r'}"
  LAYOUT_LINE1="${LAYOUT_LINE1%$'\r'}"
  LAYOUT_LINE2="${LAYOUT_LINE2%$'\r'}"
fi

# === カスタマイズ設定 (~/.claude/statusline.conf で上書きする。一部は env 変数でも上書き可) ===
# HISTORY_DIR (履歴保存先) は conf の対象外 (env CLAUDE_STATUSLINE_HISTORY_DIR のみ)。
# /tmp の安全性チェックと一体の処理のため後方の「履歴ディレクトリ」セクションに置く。

# モデル名表示の ON/OFF。1=表示 (✻ <model>∙<effort>)、0=非表示 (✻ <effort>)。
# 0 でも ✻ は model 色で必ず残す (記号の色でモデルを判別するため)。
# env CLAUDE_STATUSLINE_SHOW_MODEL_NAME でも上書き可。
SHOW_MODEL_NAME="${CLAUDE_STATUSLINE_SHOW_MODEL_NAME:-${SHOW_MODEL_NAME:-1}}"

# カラースキーム。light/dark の切替のみ。既定は dark。
# env CLAUDE_STATUSLINE_COLOR_SCHEME=light でも上書き可。
COLOR_SCHEME="${CLAUDE_STATUSLINE_COLOR_SCHEME:-${COLOR_SCHEME:-dark}}"

# バックグラウンド git fetch のオプトイン設定。既定 0=無効 (従来動作を完全維持)。
# 1 のとき、描画経路とは分離した投げっぱなし子プロセスで git fetch を実行し、
# ↓behind を自動最新化する。描画自体はローカル完結のまま (ネットワーク I/O を持ち込まない)。
# env CLAUDE_STATUSLINE_GIT_FETCH でも上書き可。
GIT_FETCH="${CLAUDE_STATUSLINE_GIT_FETCH:-${GIT_FETCH:-0}}"

# PR の状態表示のオプトイン設定。既定 0=無効。
# 1 のとき、branch 列の末尾 (diff の右) に、現在のブランチに紐付く GitHub の PR の状態を半角スペース区切りで出す。
# 取得は gh で行い、描画経路とは分離した投げっぱなし子プロセスに任せる (gh のインストールと gh auth login が必要)。
# env CLAUDE_STATUSLINE_PR_STATUS でも上書き可。
PR_STATUS="${CLAUDE_STATUSLINE_PR_STATUS:-${PR_STATUS:-0}}"

# 1 行目のカレントディレクトリ表示の ON/OFF。既定 1=表示。
# 0 にすると directory 列だけが消え、2 行構成 (branch 列は 1 行目に残る) は維持する。
# 1 行構成へ戻す設定は設けない (2 行化は仕様であり戻す口は用意しない)。
# env CLAUDE_STATUSLINE_SHOW_CWD でも上書き可。
SHOW_CWD="${CLAUDE_STATUSLINE_SHOW_CWD:-${SHOW_CWD:-1}}"

# 表示要素の並び。トークンを `|` で区切って並べる (前後の空白は無視)。
# 1 行目: directory / branch / session。値が空のトークンは列ごと省略し、全て空なら 1 行目ごと出さない。
# 2 行目: model_ctx / rate。並び順だけを変えられる (書かなかったトークンは既定順で末尾に補い、常に両方出す)。
# 未知のトークンは黙って無視する。空文字は既定値扱い (1 行目を消したいときは none 等の未知トークンを書く)。
# SHOW_CWD=0 は 1 行目から directory を外すのと等価 (directory トークンが空を返す)。
# env CLAUDE_STATUSLINE_LAYOUT_LINE1 / CLAUDE_STATUSLINE_LAYOUT_LINE2 でも上書き可。
LAYOUT_LINE1="${CLAUDE_STATUSLINE_LAYOUT_LINE1:-${LAYOUT_LINE1:-directory|branch|session}}"
LAYOUT_LINE2="${CLAUDE_STATUSLINE_LAYOUT_LINE2:-${LAYOUT_LINE2:-model_ctx|rate}}"

# 履歴サンプリング間隔 (秒)。推奨レンジ (60〜3000) は後方の「間引き定数」参照。
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-480}"            # この秒数未満の連続呼び出しは skip

# git fetch の最小間隔 (秒)。推奨レンジ (60〜1800) は後方の「間引き定数」参照。
GIT_FETCH_INTERVAL_SEC="${GIT_FETCH_INTERVAL_SEC:-900}"  # この間隔未満の連続呼び出しは fetch を skip

# === 内部定数 (変更しない。出力フォーマット/排他制御/レンジガードに直結する実装値) ===

# スパークラインの 8 階調とチャートのサンプル数。出力フォーマットの一部。
SPARKS=('▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')   # 8階調
HISTORY_LEN=6                               # チャートに表示する履歴サンプル数

# 未追跡の行数取得 (diff --no-index) を行う上限件数。超過分はファイル数のみ数える。
UNTRACKED_DIFF_LIMIT=50

# PR の状態表示の再取得間隔 (秒)。conf からは変えられない (この位置は conf の読み込みより後)。
#   FAST: CI が実行中、またはローカルの HEAD が PR の head と違う (push 直後や push 前)
#   SLOW: open で CI が完了している / PR がない / 前回の試行が失敗した / キャッシュがない
#   DONE: merged / closed
PR_INTERVAL_FAST_SEC=30
PR_INTERVAL_SLOW_SEC=300
PR_INTERVAL_DONE_SEC=900
# 最後に取得に成功してからこの秒数を超えたキャッシュは表示しない。最長の間隔 (DONE) の 2 倍にして、
# 取得が正常なのに再取得の直前に期限切れになって表示がちらつくのを避ける。
PR_STALE_SEC=1800
# 取得の実行中を示す .inflight をこの秒数より古ければ、子プロセスが異常終了した跡として消す。
# 打ち切り (PR_TIMEOUT_SEC) より長くしておき、動いている取得の印は消さない。
PR_INFLIGHT_STALE_SEC=90
# gh 1 回の打ち切り (秒)。CLAUDE_STATUSLINE_TEST_PR_TIMEOUT_SEC はテストで短くするための口。
PR_TIMEOUT_SEC="${CLAUDE_STATUSLINE_TEST_PR_TIMEOUT_SEC:-60}"
# 0 / 先頭が 0 (算術式で 8 進数と解釈される) / 非数値 / 4 桁以上は既定値に戻す。
case "$PR_TIMEOUT_SEC" in ''|0*|*[!0-9]*|????*) PR_TIMEOUT_SEC=60 ;; esac
# --- PR の状態表示の内部定数ここまで ---

# --- 間引き定数の推奨レンジ ---
# POLL_INTERVAL_SEC / GIT_FETCH_INTERVAL_SEC は env 上書き口を持たず、conf (または上の定数の直接編集) で変える運用。
# 秒数比較は算術式なので 0 / 負値 / 非数値を入れても構文エラーにならず、間引きが静かに無効化される
# (描画のたびに git fetch が多重起動する / rate 履歴が毎回更新され HISTORY_LEN 件のチャートが傾向を示さなくなる)。
# 逆に極端に大きい値は機能を事実上無効化するが警告も出ない。どちらもユーザーが気付けないため、
# 範囲外は安全側へ丸めて描画は継続する (HISTORY_DIR の安全性チェックと同じ「無効値ならフォールバックして表示は続ける」方針)。
#
# レンジの根拠:
#   GIT_FETCH_INTERVAL_SEC 60..1800
#     下限: statusline は数秒〜十数秒間隔で呼ばれ得るため、60 未満では間引きが実質機能せず fetch が頻発する
#     上限: 30 分を超えると ↓behind 自動最新化の意味が薄れ、手動 fetch と大差なくなる
#   POLL_INTERVAL_SEC 60..3000
#     下限: 同上 (呼び出し頻度に近づくと間引きが無意味になる)
#     上限: rate limit は 5 時間 (18000 秒) ウィンドウで HISTORY_LEN=6 サンプルなので、
#           18000/6=3000 を超えるとウィンドウをカバーしきれずチャートが傾向を示さなくなる
#
# 下記 4 つの MIN/MAX とその直後の clamp 処理はレンジガードそのもの。変更しない。
POLL_INTERVAL_MIN_SEC=60
POLL_INTERVAL_MAX_SEC=3000
GIT_FETCH_INTERVAL_MIN_SEC=60
GIT_FETCH_INTERVAL_MAX_SEC=1800

# 非数値・空・負値 (先頭の `-` が非数字として弾かれる) は既定値へ、範囲外は最寄りの境界へ丸める。
# 9 桁以上は上限へ直接丸める (整数範囲を超える桁数だと `[ -lt ]` がエラー終了し丸めが素通りするため)。
# command substitution を使わず変数へ直接代入する (fork を増やさないため)。
case "$POLL_INTERVAL_SEC" in ''|*[!0-9]*) POLL_INTERVAL_SEC=480 ;; ?????????*) POLL_INTERVAL_SEC=$POLL_INTERVAL_MAX_SEC ;; esac
[ "$POLL_INTERVAL_SEC" -lt "$POLL_INTERVAL_MIN_SEC" ] && POLL_INTERVAL_SEC=$POLL_INTERVAL_MIN_SEC
[ "$POLL_INTERVAL_SEC" -gt "$POLL_INTERVAL_MAX_SEC" ] && POLL_INTERVAL_SEC=$POLL_INTERVAL_MAX_SEC

case "$GIT_FETCH_INTERVAL_SEC" in ''|*[!0-9]*) GIT_FETCH_INTERVAL_SEC=900 ;; ?????????*) GIT_FETCH_INTERVAL_SEC=$GIT_FETCH_INTERVAL_MAX_SEC ;; esac
[ "$GIT_FETCH_INTERVAL_SEC" -lt "$GIT_FETCH_INTERVAL_MIN_SEC" ] && GIT_FETCH_INTERVAL_SEC=$GIT_FETCH_INTERVAL_MIN_SEC
[ "$GIT_FETCH_INTERVAL_SEC" -gt "$GIT_FETCH_INTERVAL_MAX_SEC" ] && GIT_FETCH_INTERVAL_SEC=$GIT_FETCH_INTERVAL_MAX_SEC

# --- カラースキーム ---
# 以下の COLOR_* は Claude Code の light/dark テーマの配色に合わせた RGB 値。値を変更しない。
# セマンティック名 (success/error/warning/claude/permission ...) は公式キーをそのまま維持し、
# 未使用キーも将来用に保持する。各使用箇所はこの定数を参照する。
# COLOR_subagent_* は公式キー <color>_FOR_SUBAGENTS_ONLY に対応する (名前のみ短縮)。

# R;G;B を truecolor 前景 ESC (\033[38;2;R;G;Bm) に変換する。定義時のみ使う。
_fg() { printf '\033[38;2;%sm' "$1"; }

# shellcheck disable=SC2034
case "$COLOR_SCHEME" in
  light)
    COLOR_autoAccept=$(_fg '135;0;255');             COLOR_bashBorder=$(_fg '255;0;135')
    COLOR_claude=$(_fg '215;119;87');                COLOR_permission=$(_fg '87;105;247')
    COLOR_secondaryBorder=$(_fg '153;153;153');      COLOR_text=$(_fg '0;0;0')
    COLOR_secondaryText=$(_fg '102;102;102');        COLOR_suggestion=$(_fg '87;105;247')
    COLOR_remember=$(_fg '0;0;255');                 COLOR_success=$(_fg '44;122;57')
    COLOR_error=$(_fg '171;43;63');                  COLOR_warning=$(_fg '150;108;30')
    COLOR_diff_added=$(_fg '105;219;124');           COLOR_diff_removed=$(_fg '255;168;180')
    COLOR_diff_addedDimmed=$(_fg '199;225;203');     COLOR_diff_removedDimmed=$(_fg '253;210;216')
    COLOR_diff_addedWord=$(_fg '47;157;68');         COLOR_diff_removedWord=$(_fg '209;69;75')
    COLOR_diff_addedWordDimmed=$(_fg '144;194;156'); COLOR_diff_removedWordDimmed=$(_fg '232;165;173')
    COLOR_planMode=$(_fg '51;102;102');              COLOR_effortUltra=$(_fg '135;0;255')
    COLOR_rate_limit_fill=$(_fg '51;102;255');       COLOR_rate_limit_empty=$(_fg '23;46;114')
    COLOR_claudeShimmer=$(_fg '255;183;101');        COLOR_permissionShimmer=$(_fg '101;152;255')
    COLOR_warningShimmer=$(_fg '255;183;50');        COLOR_professionalBlue=$(_fg '106;155;204')
    COLOR_chromeYellow=$(_fg '251;188;4');           COLOR_subtle=$(_fg '175;175;175')
    COLOR_inactive=$(_fg '102;102;102');             COLOR_merged=$(_fg '135;0;255')
    COLOR_fastMode=$(_fg '255;106;0');               COLOR_fastModeShimmer=$(_fg '255;150;50')
    COLOR_subagent_red=$(_fg '204;0;0');             COLOR_subagent_orange=$(_fg '255;128;0')
    COLOR_subagent_yellow=$(_fg '255;204;0');        COLOR_subagent_green=$(_fg '0;204;0')
    COLOR_subagent_cyan=$(_fg '0;178;178');          COLOR_subagent_blue=$(_fg '0;102;204')
    COLOR_subagent_purple=$(_fg '128;0;128');        COLOR_subagent_pink=$(_fg '255;102;178')
    ;;
  *)  # dark (既定)
    COLOR_autoAccept=$(_fg '175;135;255');           COLOR_bashBorder=$(_fg '253;93;177')
    COLOR_claude=$(_fg '215;119;87');                COLOR_permission=$(_fg '177;185;249')
    COLOR_secondaryBorder=$(_fg '136;136;136');      COLOR_text=$(_fg '255;255;255')
    COLOR_secondaryText=$(_fg '153;153;153');        COLOR_suggestion=$(_fg '177;185;249')
    COLOR_remember=$(_fg '177;185;249');             COLOR_success=$(_fg '78;186;101')
    COLOR_error=$(_fg '255;107;128');                COLOR_warning=$(_fg '255;193;7')
    COLOR_diff_added=$(_fg '34;92;43');              COLOR_diff_removed=$(_fg '122;41;54')
    COLOR_diff_addedDimmed=$(_fg '71;88;74');        COLOR_diff_removedDimmed=$(_fg '105;72;77')
    COLOR_diff_addedWord=$(_fg '56;166;96');         COLOR_diff_removedWord=$(_fg '179;89;107')
    COLOR_diff_addedWordDimmed=$(_fg '46;107;58');   COLOR_diff_removedWordDimmed=$(_fg '139;57;69')
    COLOR_planMode=$(_fg '0;102;102');               COLOR_effortUltra=$(_fg '135;0;255')
    COLOR_rate_limit_fill=$(_fg '87;105;247');       COLOR_rate_limit_empty=$(_fg '39;47;111')
    COLOR_claudeShimmer=$(_fg '245;149;117');        COLOR_permissionShimmer=$(_fg '137;155;255')
    COLOR_warningShimmer=$(_fg '200;158;80');        COLOR_professionalBlue=$(_fg '106;155;204')
    COLOR_chromeYellow=$(_fg '251;188;4');           COLOR_subtle=$(_fg '175;175;175')
    COLOR_inactive=$(_fg '102;102;102');             COLOR_merged=$(_fg '135;0;255')
    COLOR_fastMode=$(_fg '255;106;0');               COLOR_fastModeShimmer=$(_fg '255;150;50')
    COLOR_subagent_red=$(_fg '220;38;38');           COLOR_subagent_orange=$(_fg '217;119;87')
    COLOR_subagent_yellow=$(_fg '202;138;4');        COLOR_subagent_green=$(_fg '22;163;74')
    COLOR_subagent_cyan=$(_fg '8;145;178');          COLOR_subagent_blue=$(_fg '106;155;204')
    COLOR_subagent_purple=$(_fg '130;125;189');      COLOR_subagent_pink=$(_fg '196;102;134')
    ;;
esac

# `jq` は macOS には標準搭載されない。欠如時はシェルエラーで真っ赤になるより
# 1 行のヒントだけ出して exit したほうが Claude Code 上で読みやすい。
if ! command -v jq >/dev/null 2>&1; then
  printf '✻ -- (jq required: brew install jq)\n'
  exit 0
fi

# --- 履歴ディレクトリ ---
# 履歴は /tmp に置く。再起動で自動消滅するので肥大化しない。
# /tmp は他ユーザーからも読めるため uid を混ぜたサブディレクトリを 700 で作る。
# 回帰テストが本番履歴を汚さずに済むよう CLAUDE_STATUSLINE_HISTORY_DIR で上書き可能にする。
HISTORY_DIR="${CLAUDE_STATUSLINE_HISTORY_DIR:-/tmp/claude-statusline-$(id -u)}"

# レートリミットのリセット時刻を HH:MM 形式に変換する
# macOS (BSD date) を先に試し、失敗したら GNU date を使う。
# Linux で stderr に毎回エラーを出さないよう順序を OS で切り替える。
case "$(uname -s)" in
  Darwin|*BSD)
    format_reset_time() {
      date -r "$1" '+%H:%M' 2>/dev/null
    }
    file_mtime() {
      stat -f %m "$1" 2>/dev/null
    }
    file_owner_uid() {
      stat -f %u "$1" 2>/dev/null
    }
    file_mode() {
      stat -f %Lp "$1" 2>/dev/null
    }
    ;;
  *)
    format_reset_time() {
      date -d "@$1" '+%H:%M' 2>/dev/null
    }
    file_mtime() {
      stat -c %Y "$1" 2>/dev/null
    }
    file_owner_uid() {
      stat -c %u "$1" 2>/dev/null
    }
    file_mode() {
      stat -c %a "$1" 2>/dev/null
    }
    ;;
esac

# HISTORY_DIR を安全に用意する。
# /tmp は他ユーザーから書ける場所なので、別ユーザーが事前に作った
# ディレクトリや symlink を掴まないよう次を確認する:
#   - symlink でないこと
#   - 自分の uid 所有であること
#   - mode 700 であること
# 不適合なら HISTORY_DIR を空にして履歴機能を無効化する (statusline 自体は表示継続)。
#
# CLAUDE_STATUSLINE_HISTORY_DIR で override が来ている場合、override 先が既存の
# symlink だったときに chmod 700 がリンク先を変えてしまうのを避けるため、
# mkdir/chmod 前に **既存ディレクトリの symlink チェック** を済ませて弾く。
if [ -L "$HISTORY_DIR" ]; then
  HISTORY_DIR=""
else
  mkdir -p "$HISTORY_DIR" 2>/dev/null
  chmod 700 "$HISTORY_DIR" 2>/dev/null
  if [ -L "$HISTORY_DIR" ] \
     || [ ! -d "$HISTORY_DIR" ] \
     || [ "$(file_owner_uid "$HISTORY_DIR")" != "$(id -u)" ] \
     || [ "$(file_mode "$HISTORY_DIR")" != "700" ]; then
    HISTORY_DIR=""
  fi
fi

# 0-100 の使用率を 1文字の縦棒 (▁..█ の8階調) に変換する
spark_single() {
  local pct=$1
  [ -z "$pct" ] && { printf '%s\n' "·"; return; }
  local idx
  idx=$(awk -v p="$pct" 'BEGIN {
    i = int((p/100.0) * 8 + 0.5)
    if (i < 1) i = 1
    if (i > 8) i = 8
    printf "%d", i - 1
  }')
  printf '%s\n' "${SPARKS[$idx]}"
}

# 履歴ファイルに値を append し、末尾 HISTORY_LEN 件だけ残す。
# 値が空なら何もしない (起動直後に履歴を汚さない)。
# 履歴がまだ無いファイルへの初回 push は現在値で HISTORY_LEN 件埋める。
# 「ずっとその値だった」という見た目になり、初回表示でドットが並ぶのを避ける。
#
# 並行性: rate 用ファイルは全セッション共通のため、複数の statusline が同時に
# このパスへ突入しうる。`flock(1)` は macOS に標準で無く、無いと黙って
# 失敗するため使えない。代わりに `mkdir` の原子性 (POSIX で UNIX 上原子的と
# 保証されているのは mkdir と symlink のみ) で排他を実装する。
# ロック取得失敗時はその回をスキップ — statusline は高頻度に呼ばれるので
# 1 回飛ばしても次の呼び出しで反映される。
# [内部定数] ロック待機上限 (秒)。排他制御に使う実装値。変更しない。
LOCK_TIMEOUT_SEC=2

# acquire_lock <lockdir> : 取得できれば 0、タイムアウトなら 1。
# 古い stale ロック (LOCK_TIMEOUT_SEC×5 経過) は強制解除する。
# sleep 0.2 を 1 試行とするので、LOCK_TIMEOUT_SEC 秒待つには
# LOCK_TIMEOUT_SEC × 5 回試す必要がある。
acquire_lock() {
  local lockdir=$1
  local attempts=0
  local max_attempts=$((LOCK_TIMEOUT_SEC * 5))
  while ! mkdir "$lockdir" 2>/dev/null; do
    local age
    age=$(file_mtime "$lockdir")
    if [ -n "$age" ]; then
      local now
      now=$(date +%s)
      if [ $((now - age)) -gt $((LOCK_TIMEOUT_SEC * 5)) ]; then
        rmdir "$lockdir" 2>/dev/null
        continue
      fi
    fi
    if [ "$attempts" -ge "$max_attempts" ]; then
      return 1
    fi
    sleep 0.2
    attempts=$((attempts + 1))
  done
  return 0
}

release_lock() {
  rmdir "$1" 2>/dev/null
}

history_push() {
  local file=$1
  local value=$2
  [ -z "$value" ] && return

  local lockdir="${file}.lockd"
  acquire_lock "$lockdir" || return

  if [ ! -s "$file" ]; then
    local i
    for ((i = 0; i < HISTORY_LEN; i++)); do
      printf '%s\n' "$value" >> "$file"
    done
  else
    # 直前の更新から POLL_INTERVAL_SEC 経っていなければ skip。
    # statusline は高頻度に呼ばれるため、サンプル間隔を一定に保つ。
    local now
    now=$(date +%s)
    local mtime
    mtime=$(file_mtime "$file")
    [ -z "$mtime" ] && mtime=0
    if [ $((now - mtime)) -lt "$POLL_INTERVAL_SEC" ]; then
      release_lock "$lockdir"
      return
    fi
    printf '%s\n' "$value" >> "$file"
    local tmp
    tmp=$(mktemp "${file}.XXXXXX") || { release_lock "$lockdir"; return; }
    if tail -n "$HISTORY_LEN" "$file" > "$tmp"; then
      mv "$tmp" "$file"
    else
      rm -f "$tmp"
    fi
  fi
  release_lock "$lockdir"
}

# 履歴ファイルから各値を spark 文字に変換して連結する。
# サンプル数が HISTORY_LEN に満たない場合は左側を中点 (·) でパディング。
# `history_push` の trim が失敗してファイルが膨らんでも出力長が崩れないよう、
# `tail -n HISTORY_LEN` で末尾だけ読む。
history_chart() {
  local file=$1
  local out=""
  local count=0
  if [ -f "$file" ]; then
    local v
    while IFS= read -r v; do
      [ -z "$v" ] && continue
      out+=$(spark_single "$v")
      count=$((count + 1))
    done < <(tail -n "$HISTORY_LEN" "$file" 2>/dev/null)
  fi
  local pad=$((HISTORY_LEN - count))
  local i
  local prefix=""
  for ((i = 0; i < pad; i++)); do
    prefix+="·"
  done
  printf '%s\n' "${prefix}${out}"
}

# 色付けは 3 段構成: paint (エフェクトディスパッチャ) → static / rainbow (プリミティブ)。
# 全色付け経路 (model / rate / ctx / diff) は paint を経由する。色決定関数
# (model_color / rate_color / ctx_color) は "static <ansi>" / "rainbow" のような
# effect 名を返し、それを paint の <effect> [arg] にそのまま展開して渡す。
# 将来エフェクトが増えても paint に 1 ブランチ足すだけで済む。

# static: 文字列を単色で囲む。color が空なら素通し。
# `echo` は値が `-n` / `-e` で始まったり、バックスラッシュを含むと壊れる
# (xpg_echo の有無や処理系で挙動が変わる) ため `printf '%s'` で統一する。
static() {
  local text=$1
  local color=$2
  if [ -z "$color" ]; then
    printf '%s\n' "$text"
  else
    printf '%s%s\033[0m' "$color" "$text"
  fi
}

# RAINBOW_PALETTE: rainbow が 1 文字ずつ塗る固定色パレット (truecolor "R;G;B")。
# 赤→橙→黄→緑→青→藍→紫の 7 色。i 番目の文字に palette[i % len] を割り当てる
# (補間せず定義値そのまま、文字数 < パレット数なら後半色は出ない)。
# effort=max のとき effort_color が rainbow を返すため、live 経路 (main の effort 描画) から呼ばれる。色付けの基盤として削除しない。
RAINBOW_PALETTE=(
  "235;95;87"   "245;139;87"  "250;195;95"  "145;200;130"
  "130;170;220" "155;130;200" "200;130;180"
)

# rainbow: テキストを 1 文字ずつ RAINBOW_PALETTE で塗り、末尾に \033[0m を 1 回付ける。
# i 番目の文字には palette[i % len] を割り当てる (循環、補間なし)。
#
# 文字数カウント (${#text}) と 1 文字切り出し (${text:i:1}) は LC_ALL=C.UTF-8 固定下で
# 「文字数換算」になることに依存する (truncate_label と同じ前提)。C ロケールに戻ると
# バイト数換算になり ✻ など 3 バイト UTF-8 が壊れる。
rainbow() {
  local text=$1
  local n=${#text}
  [ "$n" -eq 0 ] && { printf '\033[0m'; return; }

  local plen=${#RAINBOW_PALETTE[@]}
  local i=0 ch rgb
  local out=""
  while [ "$i" -lt "$n" ]; do
    ch=${text:i:1}
    rgb=${RAINBOW_PALETTE[$((i % plen))]}
    out+=$(printf '\033[38;2;%sm%s' "$rgb" "$ch")
    i=$((i + 1))
  done
  printf '%s\033[0m' "$out"
}

# paint: effect に応じて static / rainbow に振り分ける共通ラッパー。
#   paint <text> static [color]  -> static "$text" "$color"
#   paint <text> rainbow         -> rainbow "$text"
paint() {
  local text=$1
  local effect=$2
  local arg=$3
  case "$effect" in
    rainbow) rainbow "$text" ;;
    *)       static "$text" "$arg" ;;
  esac
}

# 残量に応じた paint の effect 指定 (static <ansi> / static) を返す。
# 警戒→危険→致命の 3 段を公式パレットで階調化: 40% 以下=warning (黄), 15% 以下=claude (橙),
# 5% 以下=error (赤) + 点滅 (\033[5m)。点滅は色ではなく属性なので公式色に重ねて残す。
rate_color() {
  local remaining=$1
  if   [ "$remaining" -le 5 ];  then printf 'static \033[5m%s' "$COLOR_error"
  elif [ "$remaining" -le 15 ]; then printf 'static %s' "$COLOR_claude"
  elif [ "$remaining" -le 40 ]; then printf 'static %s' "$COLOR_warning"
  else                               printf 'static'
  fi
}

# モデル名に応じた ✻ + モデル名の paint の effect 指定を返す。
# 公式テーマのセマンティック色を流用: Fable→autoAccept (紫), Opus→claude (ブランドのオレンジ),
# Haiku→subagent_cyan (シアン), Sonnet 等→無色。
# Fable はバージョン非依存に *Fable* 部分一致で判定し、*Opus* より前に置く。
model_color() {
  local model=$1
  case "$model" in
    *Fable*) printf 'static %s' "$COLOR_autoAccept" ;;
    *Opus*)  printf 'static %s' "$COLOR_claude" ;;
    *Haiku*) printf 'static %s' "$COLOR_subagent_cyan" ;;
    *)       printf 'static' ;;
  esac
}

# reasoning effort (推論強度) に応じた paint の effect 指定を返す。model とは別色で塗る。
# low/medium/high/xhigh は単色、max は rainbow (RAINBOW_PALETTE で 1 文字ずつ着色)。
# ultracode は JSON 入力上 xhigh と区別できないため専用色は持たない (xhigh と同一)。
# *) は想定外 level でも無色で素通しする保険。空文字は呼び出し側でガード済み。
effort_color() {
  local level=$1
  case "$level" in
    low)    printf 'static %s' "$COLOR_warning" ;;
    medium) printf 'static %s' "$COLOR_success" ;;
    high)   printf 'static %s' "$COLOR_permission" ;;
    xhigh)  printf 'static %s' "$COLOR_autoAccept" ;;
    max)    printf 'rainbow' ;;
    *)      printf 'static' ;;
  esac
}

# 使用率に応じた paint の effect 指定 (static <ansi> / static) を返す。
# 警戒→危険→致命の 3 段を公式パレットで階調化: 70% 以上=warning (黄), 80% 以上=claude (橙),
# 90% 以上=error (赤) + 点滅 (\033[5m)。点滅は色ではなく属性なので公式色に重ねて残す。
ctx_color() {
  local used=$1
  if   [ "$used" -ge 90 ]; then printf 'static \033[5m%s' "$COLOR_error"
  elif [ "$used" -ge 80 ]; then printf 'static %s' "$COLOR_claude"
  elif [ "$used" -ge 70 ]; then printf 'static %s' "$COLOR_warning"
  else                          printf 'static'
  fi
}

# 文字列を `max` 文字以下に丸め、超過時は先頭 `max-1` 文字 + `…` (U+2026) にする。
# 文字数カウントは LC_ALL=C.UTF-8 固定下の bash `${#var}` / `${var:0:N}` に依存する。
# 詳細は README の「トリム仕様」参照。
truncate_label() {
  local max=$1
  local text=$2
  if [ "${#text}" -le "$max" ]; then
    printf '%s\n' "$text"
  else
    printf '%s…\n' "${text:0:$((max - 1))}"
  fi
}

# 作業ツリーの変更行数を色付きで返す。
#   出力: <ファイル数>(text)<+追加>(緑)<-削除>(赤) を区切りなしで詰めて連結する。
#   例 "3+13-5" = 3 ファイル, +13 行, -5 行。追加のみ "3+8"、削除のみ "2-5"。
#   集計範囲:
#     - 追跡変更: git diff HEAD --numstat (ステージ済み + 未ステージの合算)。
#       numstat の行数を変更ファイル数として数え (バイナリ行 "-\t-" も含む)、数値行のみ add/del 加算。
#     - 未追跡:   git status -z で NUL 終端列挙し ("?? path" 相当) パスを抽出。
#       NUL 終端なので空白・改行・特殊文字を含むパスもクォートなしで安全に扱える。
#       各ファイルを git diff --no-index --numstat -- /dev/null <path> で numstat 取得し、
#       テキストは追加行を + に加算、バイナリ ("-\t-") は行数加算せずファイル数のみ +1。
#       未追跡が UNTRACKED_DIFF_LIMIT 件を超えた分は diff を呼ばずファイル数のみ数える
#       (大量未追跡時に describe ごとの fork で描画が遅延するのを防ぐ)。
#   gitignore 対象は git status/git diff が元々除外する。
#   ファイル数 0 かつ追加 0 かつ削除 0 (クリーン)、または HEAD 無し/git 失敗時は無色の · (U+00B7) を返す。
#   ファイル数は変更があれば常に表示する。+0/-0 はその側を省略する。
#   ファイル数は意図的に text (dark 純白 / light 純黒) で塗る。デフォルトの前景色ではなく COLOR_SCHEME に応じた固定色。
git_diff_stat() {
  local repo=$1

  # 追跡変更: numstat の行数を変更ファイル数として数え、数値行のみ add/del 加算する。
  local tracked
  tracked=$(git -C "$repo" diff HEAD --numstat 2>/dev/null | awk '
    { files++ }
    $1 ~ /^[0-9]+$/ { add += $1 }
    $2 ~ /^[0-9]+$/ { del += $2 }
    END { printf "%d %d %d", files, add, del }
  ')
  local files=${tracked%% *}
  local _rest=${tracked#* }
  local add=${_rest%% *}
  local del=${_rest##* }

  # 未追跡: git status -z の NUL 終端エントリから "?? path" を抽出し、追加行を加算する。
  # NUL 終端なのでパスはクォートされず空白・改行入りも安全。上限超過分は diff を呼ばない。
  local entry path n untracked_seen=0
  while IFS= read -r -d '' entry; do
    case "$entry" in
      '?? '*) path=${entry#\?\? } ;;
      *)      continue ;;
    esac
    files=$((files + 1))
    untracked_seen=$((untracked_seen + 1))
    [ "$untracked_seen" -gt "$UNTRACKED_DIFF_LIMIT" ] && continue
    n=$(git -C "$repo" diff --no-index --numstat -- /dev/null "$repo/$path" 2>/dev/null \
          | awk '$1 ~ /^[0-9]+$/ { s += $1 } END { printf "%d", s }')
    [ -n "$n" ] && add=$((add + n))
  done < <(git -C "$repo" status -z 2>/dev/null)

  [ "$files" = "0" ] && [ "$add" = "0" ] && [ "$del" = "0" ] && { printf '%s' '·'; return; }

  # ファイル数 (text=dark 純白 / light 純黒) → +add (success=緑) → -del (error=赤) を区切りなしで詰める。
  # COLOR_* は既に実 ESC 化済みなので $(printf ...) でラップせずそのまま static へ渡す。
  local out
  out=$(paint "$files" static "$COLOR_text")
  [ "$add" != "0" ] && out="${out}$(paint "+${add}" static "$COLOR_success")"
  [ "$del" != "0" ] && out="${out}$(paint "-${del}" static "$COLOR_error")"
  printf '%s' "$out"
}

# ローカルとリモート追跡ブランチ (@{upstream}) の差を色付きで返す。
#   出力: <↑ahead>(青)<↓behind>(黄) を区切りなしで詰めて連結する (例 "↑2↓3")。
#   git rev-list --left-right --count '@{upstream}...HEAD' で取得する:
#     左 = @{upstream} 側 = behind (pull 待ち)、右 = HEAD 側 = ahead (push 待ち)。
#   git fetch は呼ばない (数秒ブロックし得るため)。最後に fetch/pull した時点で
#   ローカルが把握しているリモート追跡ブランチとの差を出す (git status の ahead/behind と同義)。
#   ahead=professionalBlue (青)、behind=warning (黄)。ahead に success (緑) は使わない
#   (隣接する diff の +add が緑を使っており混ざるため)。ahead/behind は別 paint で塗る。
#   COLOR_* は実 ESC 化済みなので $(printf ...) でラップせずそのまま static へ渡す。
#   第2引数 is_detached (main で検出済み: branch --show-current 空→rev-parse 代替) を受け、
#   関数内で git を再呼び出ししない (fork を増やさない)。
#   rev-list が非ゼロ終了する (ab を出せない) とき、ブランチ未発行を * で可視化する:
#     - detached HEAD (@{upstream} が無く rev-list 失敗) -> 無色 * (前景色)
#     - upstream 未設定 (rev-list 失敗)                  -> 青 * (professionalBlue)
#   (branch は取れるのに rev-list だけ失敗するリポジトリ内異常系も、upstream 未設定と
#    exit code で区別できないため一律 青 * 扱い。git 外は branch 空で本関数が呼ばれず列ごと省略。)
#   無色 * は static の素通し経路が末尾改行を付けるため、out=$(paint ...) で改行を潰してから出す。
#   次のとき空文字列を返す (フィールドごと省略):
#     - ahead も behind も 0 (同期済み。* は出さない)
git_ahead_behind() {
  local repo=$1 is_detached=${2:-0} counts behind ahead out=""
  if ! counts=$(git -C "$repo" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null); then
    if [ "$is_detached" = "1" ]; then
      out=$(paint "*" static "")
    else
      out=$(paint "*" static "$COLOR_professionalBlue")
    fi
    printf '%s' "$out"
    return
  fi
  behind=${counts%%[[:space:]]*}
  ahead=${counts##*[[:space:]]}
  [ -z "$ahead" ] && return
  [ "$ahead" = "0" ] && [ "$behind" = "0" ] && return
  [ "$ahead" != "0" ]  && out="${out}$(paint "↑${ahead}" static "$COLOR_professionalBlue")"
  [ "$behind" != "0" ] && out="${out}$(paint "↓${behind}" static "$COLOR_warning")"
  printf '%s' "$out"
}

# GIT_FETCH=1 のときだけ、描画経路と分離したバックグラウンド子プロセスで git fetch を実行する。
# 目的は ↓behind の自動最新化。描画 (git_ahead_behind) はローカル完結のままで、
# ここで投げた fetch の結果は「次回以降の」呼び出しの rev-list に反映される (今回の描画は待たない)。
#
# ネットワーク I/O を描画経路に持ち込まないための約束事:
#   - fetch は ( ... & ) の投げっぱなし子プロセスに分離する。
#   - 子プロセスの stdout/stderr/stdin を /dev/null に付け替える。これをしないと親の
#     command substitution / statusline 呼び出し元が子の EOF (= fetch 完了) を待って
#     ブロックする (数秒〜数分ハングし得る)。この 3 点セットは外さない。
#   - fd 0/1/2 を塞いでも制御端末 (/dev/tty) は子に残る。OpenSSH は端末があるとき
#     SSH_ASKPASS を無視して /dev/tty を直接開くため、SSH_ASKPASS_REQUIRE=force が無いと
#     パスフレーズ/ホスト鍵のプロンプトが Claude Code の TUI に漏れ、キー入力を奪う。
#     GIT_TERMINAL_PROMPT=0 が封じるのは git 自身の HTTPS プロンプトだけ。
#     force + GIT_ASKPASS/SSH_ASKPASS=/bin/true (空を返す) で、資格情報が無い remote では
#     端末に触れず即座に諦めさせる。この 4 変数も外さない (4 つで 1 セット)。
#   - ロックは fetch を投げる「前」に解放する (下記)。
#
# 間引き: マーカー ${HISTORY_DIR}/fetch-<cwdキー> の mtime を見て GIT_FETCH_INTERVAL_SEC
# 未満なら何もしない (fetch を投げない)。キーは repo ルートではなく cwd 単位で、cksum で作る
# (cksum はバイト列 CRC なのでロケール非依存・マルチバイトパス安全)。
maybe_git_fetch() {
  local repo=$1 branch=$2 is_detached=${3:-0}
  [ "$GIT_FETCH" = "1" ] || return
  [ -n "$repo" ] || return
  [ -n "$branch" ] || return
  [ "$is_detached" = "1" ] && return
  [ -n "$HISTORY_DIR" ] || return

  # cksum の出力は "<CRC> <バイト数>"。awk を挟まずパラメータ展開で CRC だけ取る (fork 削減)。
  local key
  key=$(printf '%s' "$repo" | cksum)
  key=${key%% *}
  local marker="${HISTORY_DIR}/fetch-${key}"

  # rev-list より前に mtime で間引く (fork を増やさない)。
  local now mtime
  now=$(date +%s)
  if [ -f "$marker" ]; then
    mtime=$(file_mtime "$marker")
    [ -z "$mtime" ] && mtime=0
    [ $((now - mtime)) -lt "$GIT_FETCH_INTERVAL_SEC" ] && return
  fi

  # 並行する複数 statusline が同時に fetch を投げないようロックする。
  local lockdir="${marker}.lockd"
  acquire_lock "$lockdir" || return

  # ロック取得までの待機中に他プロセスが fetch 済みかもしれないので mtime を再確認する。
  if [ -f "$marker" ]; then
    mtime=$(file_mtime "$marker")
    [ -z "$mtime" ] && mtime=0
    if [ $((now - mtime)) -lt "$GIT_FETCH_INTERVAL_SEC" ]; then
      release_lock "$lockdir"
      return
    fi
  fi

  # upstream が設定されていない (rev-list が非ゼロ終了) リポジトリでは fetch しても
  # 追跡ブランチが更新されず無意味なので投げない。detached はこの関数の入口で弾き済み。
  if ! git -C "$repo" rev-list --left-right --count '@{upstream}...HEAD' >/dev/null 2>&1; then
    release_lock "$lockdir"
    return
  fi

  # マーカーの mtime を「今」に更新する (次回間引きの基点)。
  # 書けなければ間引きの基点が残らず、以降の描画すべてで fetch が多重起動するため、
  # fetch を投げずにロックを解放して諦める。`:` は POSIX special built-in で、sh 互換モードでは
  # リダイレクト失敗時にシェルごと終了してしまうので非 special の `true` を使う。リダイレクトは
  # 左から右に処理されるため、エラーメッセージを捨てるには後置の `2>/dev/null` ではなく
  # ブロックごと囲む必要がある (後置だと fd 2 の差し替え前に失敗し端末へ漏れる)。
  if ! { true > "$marker"; } 2>/dev/null; then
    release_lock "$lockdir"
    return
  fi

  # マーカーを書いた時点で他プロセスは mtime 判定で弾かれるので、ロックはここで役目を終える。
  # fetch を投げる「前」に解放する: 子プロセスにロックを持ち越さないための順序であり、
  # marker 更新 → unlock → fetch 起動 の順を入れ替えない (Linux 版と共通)。
  release_lock "$lockdir"

  # 投げっぱなしの子プロセスで fetch する。stdout/stderr/stdin を /dev/null に付け替えて
  # 親をブロックさせない。認証プロンプトは環境変数で封じる (/dev/tty を含む)。
  ( GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
      SSH_ASKPASS=/bin/true SSH_ASKPASS_REQUIRE=force \
      git -C "$repo" fetch --quiet >/dev/null 2>&1 </dev/null & )
}

# --- PR の状態表示 ---
# PR_STATUS=1 のときだけ、現在のブランチに紐付く GitHub の PR を
# `#<番号>[<CI記号>][ <件数>]` で表示する。情報はバックグラウンドの子プロセスが gh api graphql で
# 取得してキャッシュに書き、描画はキャッシュを読むだけにする (gh も追加の git も描画経路に入れない)。
# stdin の pr フィールドは、同じセッションで PR を切り替えても更新されないため使わない。
#
# ファイル (<key> は「cwd + 改行 + ローカルのブランチ名」の cksum):
#   ${HISTORY_DIR}/pr-<key>           キャッシュ。子プロセスが取得に成功したときだけ置き換える
#   ${HISTORY_DIR}/pr-<key>.marker    空ファイル。親が書き、mtime が最後に取得を試みた時刻になる
#   ${HISTORY_DIR}/pr-<key>.inflight  ディレクトリ。子プロセスが取得している間だけ存在する
# キャッシュとマーカーを分けるのは、マーカーの書き方 (`true > file`) がファイルを空にするため。
#
# キャッシュはタブ区切りの 1 行。PR がないときは fetched_at だけを書く。
#   <fetched_at>\t<number>\t<state>\t<review>\t<ci>\t<comments>\t<head_matches>\t<url>
#   fetched_at:   取得を始めた時刻 (epoch 秒)。期限切れの判定と、古い結果での上書きの防止に使う
#   state:        open / draft / merged / closed
#   review:       approved / pending / changes_requested (open / draft 以外では空)
#   ci:           pass / fail / pending / 空 (チェックが 1 つもない)
#   comments:     コメントの件数 (0 以上の整数)
#   head_matches: 1 / 0 (ローカルの HEAD が PR の head と一致するか。再取得の間隔に使う)

# 1 回で取る GraphQL。必要なのは件数と集約値だけなので、コメントやレビューの本文は取らない。
# repository.owner は、push 先が分からないときに head のオーナーとして使う。
# totalCommentsCount は GitHub が数えたコメントの件数 (会話のコメント、コードの行へのコメント、
# 本文付きのレビュー) で、PR 一覧の吹き出しの数字と同じ値。種類ごとの totalCount を足すと、
# reviewThreads はスレッドの数なので返信を数えられない。
PR_QUERY='query($owner: String!, $repo: String!, $head: String!) {
  repository(owner: $owner, name: $repo) {
    owner { login }
    pullRequests(headRefName: $head, first: 10, orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes {
        number url state isDraft headRefOid
        headRepositoryOwner { login }
        reviewDecision
        latestReviews(first: 20) { nodes { state } }
        totalCommentsCount
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
}'

# gh --jq に渡す変換。候補の選び方と状態の決め方をここで済ませ、キャッシュの fetched_at 以降の
# 1 行 (PR がなければ "none") を出す。--jq は --arg を受け付けないため、ローカルの HEAD と
# head のオーナーは環境変数で渡して $ENV で読む (値を式に文字列として埋め込まない)。
#   候補: headRepositoryOwner が head のオーナーと一致するもの (大文字小文字は区別しない)。
#         他人の fork の同名ブランチから出た PR を拾わないため
#   選択: OPEN の最新 → なければ headRefOid がローカルの HEAD と一致する MERGED / CLOSED の最新
#   review: reviewDecision はレビュー必須でないリポジトリでは常に null なので、
#           null のときは latestReviews から決める
#   ci: statusCheckRollup.state (PR 画面のチェック表示と同じ集約値) をそのまま使う
#   comments: totalCommentsCount をそのまま使う。null は 0 とする
PR_JQ='.data.repository as $r
| (($ENV.HEAD_OWNER // "") | if . == "" then ($r.owner.login // "") else . end | ascii_downcase) as $owner
| [$r.pullRequests.nodes[] | select(((.headRepositoryOwner.login // "") | ascii_downcase) == $owner)] as $c
| (([$c[] | select(.state == "OPEN")] | first)
   // ([$c[] | select(.state != "OPEN" and .headRefOid == $ENV.LOCAL_HEAD)] | first)) as $p
| if $p == null then "none" else
    (if $p.state == "OPEN" then (if $p.isDraft then "draft" else "open" end)
     elif $p.state == "MERGED" then "merged"
     elif $p.state == "CLOSED" then "closed"
     else "" end) as $state
  | (if $p.state != "OPEN" then ""
     elif $p.reviewDecision == "APPROVED" then "approved"
     elif $p.reviewDecision == "CHANGES_REQUESTED" then "changes_requested"
     elif $p.reviewDecision == "REVIEW_REQUIRED" then "pending"
     elif any($p.latestReviews.nodes[]?; .state == "CHANGES_REQUESTED") then "changes_requested"
     elif any($p.latestReviews.nodes[]?; .state == "APPROVED") then "approved"
     else "pending" end) as $review
  | (($p.commits.nodes[0].commit.statusCheckRollup.state // "")
     | if . == "SUCCESS" then "pass"
       elif . == "FAILURE" or . == "ERROR" then "fail"
       elif . == "PENDING" or . == "EXPECTED" then "pending"
       else "" end) as $ci
  | (($p.totalCommentsCount // 0) | tostring) as $comments
  | (if $p.headRefOid == $ENV.LOCAL_HEAD then "1" else "0" end) as $head_matches
  | [($p.number | tostring), $state, $review, $ci, $comments, $head_matches, ($p.url // "")]
  | join("\t")
  end'

# $1 が先頭に 0 のない 9 桁以内の正の整数なら 0 を返す (PR の番号とコメントの件数の検証)。
# 値が 0 のときも偽を返すので、コメントが 0 件なら件数がないものとして扱われる。
pr_is_positive_int() {
  case "$1" in ''|0*|*[!0-9]*|??????????*) return 1 ;; esac
}

# キャッシュを読み、pr_fetched / pr_state / pr_number / pr_review / pr_ci / pr_comments /
# pr_head_matches / pr_url に入れる。PR がないキャッシュは pr_state=none にする。
# 読めない、または形が壊れている (fetched_at か number か state が不正、フィールド数が違う) ときは
# 1 を返し、キャッシュがないものとして扱わせる。
# それ以外のフィールドは信用せず、想定外の値はそのフィールドがないものとして扱う。
# comments は 1 件以上のときだけ pr_comments に入れる。
# url は https:// で始まり、残りが URL に使う ASCII の英数字と記号だけのときに残す (OSC 8 に
# 埋め込むため)。許す文字を列挙するのは、[[:cntrl:]] などの文字クラスや A-Z の範囲が、どの文字を
# 含むかを OS のロケール実装ごとに変え、両版で結果が食い違いうるため。
# 描画経路で呼ぶので、組み込みの read とパラメータ展開だけで済ませる (fork しない)。
pr_cache_load() {
  local file=$1 line="" rest
  local url_bad='*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~:/?#=&+@%-]*'
  local -a f=()
  pr_fetched="" pr_state="" pr_number="" pr_review="" pr_ci="" pr_comments="" pr_head_matches="" pr_url=""
  [ -f "$file" ] || return 1
  { IFS= read -r line; } 2>/dev/null < "$file"
  [ -n "$line" ] || return 1
  # タブは IFS の空白文字で、read で分けると連続するタブ (空のフィールド) が 1 つに潰れるため、
  # パラメータ展開で 1 つずつ切り出す。
  rest="${line}"$'\t'
  while [ -n "$rest" ]; do
    f+=("${rest%%$'\t'*}")
    rest="${rest#*$'\t'}"
  done
  # 先頭が 0 の値 (0 単独は除く) は $((...)) で 8 進数と解釈され、08 などで算術エラーになるため弾く。
  case "${f[0]}" in ''|0?*|*[!0-9]*|?????????????*) return 1 ;; esac
  if [ "${#f[@]}" -eq 1 ]; then
    pr_fetched=${f[0]}
    pr_state=none
    return 0
  fi
  [ "${#f[@]}" -eq 8 ] || return 1
  pr_is_positive_int "${f[1]}" || return 1
  case "${f[2]}" in open|draft|merged|closed) ;; *) return 1 ;; esac
  pr_fetched=${f[0]}
  pr_number=${f[1]}
  pr_state=${f[2]}
  case "${f[3]}" in approved|pending|changes_requested) pr_review=${f[3]} ;; esac
  case "${f[4]}" in pass|fail|pending) pr_ci=${f[4]} ;; esac
  pr_is_positive_int "${f[5]}" && pr_comments=${f[5]}
  [ "${f[6]}" = "1" ] && pr_head_matches=1
  case "${f[7]}" in
    https://$url_bad) ;;
    https://?*) pr_url=${f[7]} ;;
  esac
  return 0
}

# 読み込んだキャッシュから PR の状態表示の値を組み立てて pr_str に入れる。PR がなければ空。
#   #<番号>: 状態の色で塗り、下線 (SGR 4) を付ける。merged / closed は取り消し線 (SGR 9) も重ねる。
#            url があり FORCE_HYPERLINK=0 でなければ、ここだけを OSC 8 で PR へのリンクにする
#   CI 記号: open / draft のときだけ、#<番号> に詰めて続ける
#   件数:    open / draft でコメントが 1 件以上のときだけ、半角スペースを挟んで続ける。
#            詰めると、CI 記号がないときに番号と続けて読めてしまう (#12 と 3 で #123)
# OSC 8 のエスケープ列を含むので、truncate_label や ${#var} の幅計算には渡さない。
format_pr() {
  pr_str=""
  local color="" deco=4 num
  case "$pr_state" in
    open)
      case "$pr_review" in
        approved)          color=$COLOR_success ;;
        changes_requested) color=$COLOR_error ;;
        *)                 color=$COLOR_permission ;;
      esac
      ;;
    draft)  ;;
    merged) color=$COLOR_merged; deco='4;9' ;;
    closed) deco='4;9' ;;
    *) return ;;
  esac
  num=$'\033['"${deco}m${color}#${pr_number}"$'\033[0m'
  if [ -n "$pr_url" ] && [ "${FORCE_HYPERLINK-}" != "0" ]; then
    num=$'\033]8;;'"${pr_url}"$'\a'"${num}"$'\033]8;;\a'
  fi
  pr_str=$num
  case "$pr_state" in
    open|draft)
      case "$pr_ci" in
        pass)    pr_str="${pr_str}${COLOR_success}✓"$'\033[0m' ;;
        fail)    pr_str="${pr_str}${COLOR_error}✗"$'\033[0m' ;;
        pending) pr_str="${pr_str}${COLOR_warning}●"$'\033[0m' ;;
      esac
      [ -n "$pr_comments" ] && pr_str="${pr_str} ${pr_comments}"
      ;;
  esac
}

# 読み込んだキャッシュから、次の取得までの間隔を pr_interval に入れる ($(...) を挟まないため)。
# $1 はマーカーの mtime。キャッシュがない (pr_state が空) か、fetched_at がマーカーより古い
# (最後の試行が失敗した、または実行中) ときは SLOW にする。
pr_refresh_interval() {
  local marker_mtime=$1
  pr_interval=$PR_INTERVAL_SLOW_SEC
  [ -n "$pr_state" ] || return
  [ "$pr_fetched" -lt "$marker_mtime" ] && return
  case "$pr_state" in
    merged|closed) pr_interval=$PR_INTERVAL_DONE_SEC ;;
    open|draft)
      if [ "$pr_ci" = "pending" ] || [ "$pr_head_matches" != "1" ]; then
        pr_interval=$PR_INTERVAL_FAST_SEC
      fi
      ;;
  esac
}

# マーカー $1 の mtime から見て再取得の間隔が過ぎていれば 0 を返す。マーカーがなければ 0。
#   $2 現在時刻。間隔は読み込んだキャッシュから pr_refresh_interval で決める
pr_refresh_due() {
  local marker=$1 now=$2 mtime
  [ -f "$marker" ] || return 0
  mtime=$(file_mtime "$marker")
  [ -z "$mtime" ] && mtime=0
  pr_refresh_interval "$mtime"
  [ $((now - mtime)) -ge "$pr_interval" ]
}

# 前の取得がまだ動いていれば 0 を返す。PR_INFLIGHT_STALE_SEC より古い .inflight ($1) は
# 子プロセスが異常終了した跡として消し、1 を返す。$2 は現在時刻。
pr_inflight_busy() {
  local inflight=$1 now=$2 mtime
  [ -d "$inflight" ] || return 1
  mtime=$(file_mtime "$inflight")
  [ -z "$mtime" ] && mtime=0
  [ $((now - mtime)) -le "$PR_INFLIGHT_STALE_SEC" ] && return 0
  rmdir "$inflight" 2>/dev/null
  return 1
}

# 取得の子プロセスを投げっぱなしで起動する。引数は pr_refresh_child と同じ。
# ロックを解放した後に呼ぶ。fd 0/1/2 を /dev/null に付け替え、描画をブロックさせない。
# GH_REPO は cwd ではなくそのリポジトリを問い合わせさせ、GH_FORCE_TTY / CLICOLOR_FORCE は
# 出力を端末向けの書式や色付きにして TSV を壊すので外す。GH_TOKEN / GITHUB_TOKEN / GH_HOST /
# GH_ENTERPRISE_TOKEN はユーザーが選んだ認証方法と接続先なので残す。
# git 用の 4 つは maybe_git_fetch と同じ理由で設定する (子プロセスも git を呼ぶ)。
pr_spawn_refresh() {
  local cwd=$1 branch=$2 cache=$3 inflight=$4
  ( unset GH_REPO GH_FORCE_TTY CLICOLOR_FORCE
    export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_NO_EXTENSION_UPDATE_NOTIFIER=1
    export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
      SSH_ASKPASS=/bin/true SSH_ASKPASS_REQUIRE=force
    pr_refresh_child "$cwd" "$branch" "$cache" "$inflight" >/dev/null 2>&1 </dev/null & )
}

# PR の状態表示の値を pr_str に入れ、必要ならバックグラウンドで取得を起動する。layout_token が
# branch 列を組み立てるときだけ呼び、PR_STATUS=1 でなければ何もしない。PR_STATUS=0 か、
# LAYOUT_LINE1 に branch が無ければ gh も date も cksum も起動しない。
# キャッシュを先に読んでから起動するので、今回の描画は起動した取得の結果を待たない。
# キーは毎回「今の cwd とブランチ」から作るため、ブランチの切り替えや /clear で別の PR が残らない。
# fetched_at が現在より未来のキャッシュ (時計が戻った後など) は期限切れと同じく表示しない。
pr_token() {
  pr_str=""
  [ "$PR_STATUS" = "1" ] || return
  [ -n "$branch" ] && [ "$branch_detached" != "1" ] && [ -n "$HISTORY_DIR" ] || return
  command -v gh >/dev/null 2>&1 || return
  local key cache now age
  key=$(printf '%s\n%s' "$cwd" "$branch" | cksum)
  cache="${HISTORY_DIR}/pr-${key%% *}"
  now=$(date +%s)
  if pr_cache_load "$cache"; then
    age=$((now - pr_fetched))
    [ "$age" -ge 0 ] && [ "$age" -le "$PR_STALE_SEC" ] && format_pr
  fi
  maybe_pr_refresh "$cwd" "$branch" "$cache" "$now"
}

# 子プロセスの入口。pr_spawn_refresh の ( ... & ) の中で呼ぶ (描画は待たない)。
#   $1 cwd / $2 ローカルのブランチ名 / $3 キャッシュのパス / $4 .inflight のパス
# .inflight は mkdir の原子性で取り合い、作れなければ (ほかの子プロセスが先に作った) 何もしない。
# 後始末は trap ではなく呼び出しの後で行う。bash 3.2 では & で起動したサブシェルに張った
# EXIT の trap が走らないため。kill などで rmdir まで届かなかった印は PR_INFLIGHT_STALE_SEC で消える。
# スリープなどで止まっている間に親が印を古いものとして消し、次の子が作り直していることがあるので、
# mtime が作ったときと同じ (自分の印) ときだけ消す。
pr_refresh_child() {
  local inflight=$4 created
  mkdir "$inflight" 2>/dev/null || return
  created=$(file_mtime "$inflight")
  pr_refresh_run "$1" "$2" "$3"
  [ "$(file_mtime "$inflight")" = "$created" ] && rmdir "$inflight" 2>/dev/null
}

# 子プロセスの本体。head を決めて gh を 1 回だけ呼び、成功したらキャッシュを置き換える。
# head のブランチ名とオーナーは push 先 (@{push}) から決める。ローカル名で探すと、
# push 先の名前が違うブランチ (gh pr checkout の <owner>-<branch> など) で PR が見つからない。
# push 先が分からない (まだ push していない) ときは、ローカル名と base リポジトリのオーナーを使う。
# 失敗 (gh の非ゼロ終了、打ち切り、想定外の出力) のときはキャッシュを書き換えない。
pr_refresh_run() {
  local cwd=$1 branch=$2 cache=$3
  local started head push remote url path head_branch=$branch head_owner=""
  started=$(date +%s)
  # gh は {owner} / {repo} をカレントディレクトリのリポジトリから決めるので cd する。
  cd "$cwd" 2>/dev/null || return
  head=$(git -C "$cwd" rev-parse HEAD 2>/dev/null) || return
  [ -n "$head" ] || return
  if push=$(git -C "$cwd" rev-parse --abbrev-ref '@{push}' 2>/dev/null); then
    case "$push" in
      ?*/?*)
        remote=${push%%/*}
        head_branch=${push#*/}
        # URL からオーナーを取り出す。git@host:owner/repo.git / https://host/owner/repo(.git) /
        # ssh://git@host/owner/repo の 3 形式に対応する。取れなければ base のオーナーを使う。
        # --push で pushurl を優先する (fetch は upstream、push は fork の remote でも push 先を取る)。
        if url=$(git -C "$cwd" remote get-url --push "$remote" 2>/dev/null); then
          case "$url" in
            *://*) path=${url#*://}; path=${path#*/} ;;
            *:*)   path=${url#*:} ;;
            *)     path="" ;;
          esac
          case "$path" in ?*/?*) head_owner=${path%%/*} ;; esac
        fi
        ;;
    esac
  fi

  local tmp
  tmp=$(mktemp "${cache}.tmp.XXXXXX") || return
  # head は -f (文字列のまま) で渡す。-F だと 123 / true / null などのブランチ名が数値や真偽値に
  # 変換されて String! 型の変数とずれ、@ で始まる名前はファイルとして読まれる。
  LOCAL_HEAD=$head HEAD_OWNER=$head_owner \
    gh api graphql -f query="$PR_QUERY" -F owner='{owner}' -F repo='{repo}' \
      -f head="$head_branch" --jq "$PR_JQ" >"$tmp" 2>/dev/null </dev/null &
  # macOS には timeout(1) がないため、gh をさらにバックグラウンドで起動して見張り、
  # PR_TIMEOUT_SEC を過ぎたら kill する。ネットワークが詰まっても gh が溜まらない。
  # sleep の回数はスリープ中に進まないので、壁時計の SECONDS でも打ち切る (印の stale 判定と揃える)。
  # TERM で終わらなければ 1 秒後に KILL する (wait が gh を待ち続けないように)。
  local gh_pid=$! waited=0 rc=0 deadline=$((SECONDS + PR_TIMEOUT_SEC))
  while kill -0 "$gh_pid" 2>/dev/null; do
    if [ "$waited" -ge $((PR_TIMEOUT_SEC * 5)) ] || [ "$SECONDS" -gt "$deadline" ]; then
      kill "$gh_pid" 2>/dev/null
      sleep 1
      kill -9 "$gh_pid" 2>/dev/null
      break
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  wait "$gh_pid" || rc=$?

  local out="" line=""
  [ "$rc" -eq 0 ] && out=$(cat "$tmp" 2>/dev/null)
  case "$out" in
    *$'\n'*) ;;
    none) line=$started ;;
    [1-9]*$'\t'*) line="${started}"$'\t'"${out}" ;;
  esac
  if [ -z "$line" ]; then
    rm -- "$tmp" 2>/dev/null
    return
  fi

  # 自分より後に始まった取得の結果が既にあれば、古い結果で上書きしない。現在より未来の
  # fetched_at (時計が戻った後など) は後から始まった取得のものではないので上書きする。
  # 子プロセスの中なので、pr_cache_load が描画用の変数を書き換えても描画には影響しない。
  local finished
  finished=$(date +%s)
  if pr_cache_load "$cache" && [ "$pr_fetched" -gt "$started" ] \
     && [ "$pr_fetched" -le "$finished" ]; then
    rm -- "$tmp" 2>/dev/null
    return
  fi
  # 一時ファイルに書いてから mv で置き換え、描画が書きかけのファイルを読まないようにする。
  if printf '%s\n' "$line" >"$tmp"; then
    mv -- "$tmp" "$cache" 2>/dev/null || rm -- "$tmp" 2>/dev/null
  else
    rm -- "$tmp" 2>/dev/null
  fi
}

# maybe_pr_refresh: 前回の試行から間隔が過ぎていれば、バックグラウンドで取得を起動する。
#   $1 cwd / $2 ローカルのブランチ名 / $3 キャッシュのパス / $4 現在時刻
# 前提 (ブランチがある、HISTORY_DIR が有効、gh がある) は呼び出し側の pr_token で確かめる。
# 今回の描画は待たず、結果は次回以降の描画に反映される。maybe_git_fetch と同じ約束事を守る:
#   - ロック取得 → 間隔の再確認 → マーカー更新 → ロック解放 → 子プロセス起動、の順に行う
#   - マーカーを書けなければ子プロセスを起動しない (間引きの基点が残らず描画ごとに起動するため)
#   - fd の付け替えとプロンプトを封じる環境変数は pr_spawn_refresh にまとめてある
# 両版で違うのはロックの取り方だけ。
maybe_pr_refresh() {
  local cwd=$1 branch=$2 cache=$3 now=$4
  local marker="${cache}.marker" inflight="${cache}.inflight"
  pr_refresh_due "$marker" "$now" || return
  pr_inflight_busy "$inflight" "$now" && return

  local lockdir="${marker}.lockd"
  acquire_lock "$lockdir" || return

  # ロック取得までの待機中に他プロセスが起動済みかもしれないので間隔を再確認する。
  # マーカーの書き込み失敗時の扱いとリダイレクトの書き方は maybe_git_fetch と同じ。
  if ! pr_refresh_due "$marker" "$now" || ! { true > "$marker"; } 2>/dev/null; then
    release_lock "$lockdir"
    return
  fi

  # marker 更新 → unlock → 子プロセス起動 の順を入れ替えない (Linux 版と共通)。
  release_lock "$lockdir"
  pr_spawn_refresh "$cwd" "$branch" "$cache" "$inflight"
}

# レートリミット残量の文字列を組み立てる (履歴チャート版)
# 第3引数 chart は呼び出し側で構築済みの履歴チャート (残量ベース、HISTORY_LEN 文字)
format_rate() {
  local rate_pct=$1
  local rate_reset=${2:-0}
  local chart=${3:-$(history_chart /dev/null)}

  [ -z "$rate_pct" ] && { printf '%s\n' "${chart} --"; return; }

  local rate_int
  rate_int=$(printf '%.0f' "$rate_pct")
  local remaining=$((100 - rate_int))

  # rate_color は paint の effect 指定 ("static <ansi>" / "static") を返す。
  # 色付き分岐は ANSI コードを伴うとき (= "static " の後ろに値があるとき) だけ。
  local color_spec ansi
  color_spec=$(rate_color "$remaining")
  ansi=${color_spec#static}
  ansi=${ansi# }

  # 数値は色が付くとき (= 残量が減ってきたとき) だけ表示する。
  # 区切りのハイフンも数値側に組み込む: デフォルトは `chart HH:MM`、
  # 警戒域に入ると `chart NN% - HH:MM` のように数値とハイフンが挿入される。
  local time_str=""
  if [ -n "$rate_reset" ] && [ "$rate_reset" -gt 0 ] 2>/dev/null; then
    time_str=$(format_reset_time "$rate_reset")
  fi

  local body
  if [ -n "$ansi" ]; then
    if [ -n "$time_str" ]; then
      body="${chart} ${remaining}% - ${time_str}"
    else
      body="${chart} ${remaining}%"
    fi
    paint "$body" $color_spec
  else
    if [ -n "$time_str" ]; then
      printf '%s\n' "${chart} ${time_str}"
    else
      printf '%s\n' "$chart"
    fi
  fi
}

# コンテキスト使用率の文字列を組み立てる (現在値 1 文字スパーク版)
# 履歴は持たず、現在値の spark を 1 文字描画する。70% 以上のときだけ数値併記。
format_ctx() {
  local ctx_pct=$1

  [ -z "$ctx_pct" ] && { printf '%s\n' "· --"; return; }

  local spark
  spark=$(spark_single "$ctx_pct")

  local ctx_int
  ctx_int=$(printf '%.0f' "$ctx_pct")

  # ctx_color は paint の effect 指定 ("static <ansi>" / "static") を返す。
  # 色付き分岐は ANSI コードを伴うときだけ。
  local color_spec ansi
  color_spec=$(ctx_color "$ctx_int")
  ansi=${color_spec#static}
  ansi=${ansi# }
  if [ -n "$ansi" ]; then
    paint "${spark} ${ctx_int}%" $color_spec
  else
    printf '%s\n' "$spark"
  fi
}

# レイアウトのトークンを描画済み文字列に引く。値は token_value に返す (呼び出し側で $(...) を
# 挟まないため。branch/session のトリムは従来どおり truncate_label の command substitution を伴う)。
# トークン内部の区切り (branch の ab/diff/PR 前のスペース、model_ctx の ∙/スペース) は
# トークン間の " | " とは別ルールなので、ここで組み立て済みの 1 塊として返す。
layout_token() {
  token_value=""
  case "$1" in
    directory) token_value="$dir_field" ;;
    branch)
      if [ -n "$branch" ]; then
        pr_token
        token_value="$(truncate_label 25 "$branch")${ab_str:+ $ab_str}${diff_str:+ $diff_str}${pr_str:+ $pr_str}"
      fi
      ;;
    session)
      if [ -n "$session" ]; then
        token_value="$(truncate_label 40 "$session")"
      fi
      ;;
    model_ctx) token_value="${model_field} ${ctx_str}" ;;
    rate) token_value="$rate_str" ;;
  esac
}

# レイアウト文字列 (トークンを | で区切った列) を走査し、描画済みの列を layout_parts に積む。
#   $1: レイアウト文字列
#   $2: その行で有効なトークン ("|a|b|" 形式。それ以外は未知として黙って無視する)
#   $3: 1 = 値が空でも積む (2 行目) / 0 = 値が空なら列ごと省略する (1 行目)
# 重複は最初の 1 回だけ採る。トークン前後の空白 (タブ含む) は剥がす。
# 分割･トリムはパラメータ展開のみで行う (tr / awk 等の外部コマンドを使わない)。
build_layout() {
  local rest="$1|" allowed=$2 keep_empty=$3 seen="|" token
  layout_parts=()
  while [ -n "$rest" ]; do
    token="${rest%%|*}"
    rest="${rest#*|}"
    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    case "$allowed" in *"|${token}|"*) ;; *) continue ;; esac
    case "$seen" in *"|${token}|"*) continue ;; esac
    seen="${seen}${token}|"
    layout_token "$token"
    if [ "$keep_empty" = "1" ] || [ -n "$token_value" ]; then
      layout_parts+=("$token_value")
    fi
  done
}

# 配列を区切り文字で結合する
join_by() {
  local sep=$1
  shift
  local result=$1
  shift
  local item
  for item in "$@"; do
    result+="${sep}${item}"
  done
  printf '%s\n' "$result"
}

# --- main ---

input=$(cat)

# jq は起動コストが高い (1 回 ~20-50ms) ため、必要なフィールドを 1 回で取り出す。
# 1 フィールド 1 行で出力し、`read` を 7 回呼んで空フィールドも保持する。
# (bash 3.2 の `read -d` は IFS が非空白だと連続デリミタを圧縮するため @tsv 経路は使えない。
#  値に改行が混入せず、ESC などの制御文字で端末の表示が崩れないよう、文字列フィールドは
#  gsub で制御文字をすべて半角スペースに潰してから渡す。)
# effort は必ず末尾に追加する (read 個数 = jq 出力行数。途中挿入すると既存変数の対応がズレる)。
{
  IFS= read -r model
  IFS= read -r ctx_pct
  IFS= read -r rate_pct
  IFS= read -r rate_reset
  IFS= read -r session
  IFS= read -r cwd
  IFS= read -r effort
} <<EOF
$(printf '%s' "$input" | jq -r '
  def safe: tostring | gsub("[[:cntrl:]]"; " ");
  (.model.display_name                       // "" | safe),
  (.context_window.used_percentage           // "" | tostring),
  (.rate_limits.five_hour.used_percentage    // "" | tostring),
  (.rate_limits.five_hour.resets_at          // 0  | tostring),
  (.session_name                             // "" | safe),
  (.workspace.current_dir                    // "" | safe),
  (.effort.level                             // "" | safe)
')
EOF

# rate は残量を履歴に積む (チャートも数字も 100→0 に減っていく様子になる)
rate_remaining=""
if [ -n "$rate_pct" ]; then
  rate_int=$(printf '%.0f' "$rate_pct")
  rate_remaining=$((100 - rate_int))
fi

# rate は 5 時間ウィンドウのアカウント単位の値で全セッション共通なので、
# グローバルな 1 ファイルに集約し、セッションを跨いで観測を継続する。
# ctx は現在値の 1 文字 spark のみで描画するため履歴は持たない。
# 右端 = 現在値の不変条件を HISTORY_DIR の状態と独立に保つため、まず履歴なしの
# パディング (······) を土台に置く。HISTORY_DIR が安全性チェックで無効化された
# ケースでもこの土台が残り、右端 1 文字を現在値に差し替えられる。
rate_chart=$(history_chart /dev/null)
if [ -n "$HISTORY_DIR" ]; then
  rate_hist_file="${HISTORY_DIR}/rate"
  history_push "$rate_hist_file" "$rate_remaining"
  rate_chart=$(history_chart "$rate_hist_file")
fi

# チャート右端 1 文字は履歴サンプリング間隔 (POLL_INTERVAL_SEC) と独立に常に現在値を描く。
# history_push は 480 秒間引きするため、リセットで残量が戻った直後はチャートが古い値の
# まま据え置かれる。右端だけ現在値 spark に差し替えて最新残量を即時反映する。
# (左 HISTORY_LEN-1 文字は履歴の遷移、右端 1 文字だけが現在値)
# rate_chart は history_chart /dev/null で必ず非空なので、rate_remaining の有無だけで分岐する。
# ${var:0:N} は LC_ALL=C.UTF-8 固定下で文字数換算になり、spark の 3 バイト文字でも先頭
# HISTORY_LEN-1 文字を正しく切り出せる (truncate_label と同じロケール前提)。
if [ -n "$rate_remaining" ]; then
  rate_chart="${rate_chart:0:$((HISTORY_LEN - 1))}$(spark_single "$rate_remaining")"
fi

# cwd から git ブランチ名を取得する。空文字 / git 外 / git 未インストール時は空のまま。
# 重要: $cwd 空チェックは必須。空のまま `git -C ""` を呼ぶとカレントディレクトリ扱いになり、
# 無関係なリポジトリのブランチが表示されてしまうため。
branch=""
branch_detached=0
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
  if [ -z "$branch" ]; then
    branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
    [ -n "$branch" ] && branch_detached=1
  fi
fi

# GIT_FETCH=1 のとき、描画とは独立にバックグラウンド fetch を投げる (↓behind の自動最新化)。
# branch/branch_detached/cwd が揃った直後・ab_str/diff_str を計算する前に置く。
maybe_git_fetch "$cwd" "$branch" "$branch_detached"

# ブランチが取れたときだけ作業ツリーの変更行数を集計する (git 外なら diff も不要)。
diff_str=""
if [ -n "$branch" ]; then
  diff_str=$(git_diff_stat "$cwd")
fi

# ブランチが取れたときだけ ahead/behind を集計する (git fetch はしない。ローカル完結)。
# 同期済みのときは空になり列で省略。upstream 未設定 / detached のときは * を返す
# (branch_detached を渡して detached=無色 / upstream 未設定=青 に分岐させる)。
ab_str=""
if [ -n "$branch" ]; then
  ab_str=$(git_ahead_behind "$cwd" "$branch_detached")
fi

model_str="${model:-Unknown}"
ctx_str=$(format_ctx "$ctx_pct")
rate_str=$(format_rate "$rate_pct" "$rate_reset" "$rate_chart")

# ✻ (+ トリム後モデル名) をモデル色で塗る。色判定はトリム前の全長で行う。
# model_color は paint の effect 指定 (Fable/Opus/Haiku→static <ansi>, 他→static) を返す。
# 全モデルが単色 (無色含む)。無色 (Sonnet) でも $(...) で末尾改行が
# 除去されるため後続の連結で出力は崩れない。
# SHOW_MODEL_NAME=0 のときは ✻ 単体を model 色で塗る (記号の色でモデルを判別するため常に残す)。
model_effect=$(model_color "$model_str")
if [ "$SHOW_MODEL_NAME" = "1" ]; then
  model_field=$(paint "✻ $(truncate_label 13 "$model_str")" $model_effect)
else
  model_field=$(paint "✻" $model_effect)
fi

# effort (推論強度) を model とは別色で塗り、model_field に連結する。
# effort はトリムしない (最長 5 文字の固定語彙)。13 文字トリムは ✻ <model> 部にのみ掛かる。
# effort 欠落 (非対応モデル) 時は effort も区切りも一切出さない (= 既存出力と同一)。
# SHOW_MODEL_NAME=1 (モデル名表示) のときは model 名との境界を明確化するため `∙` 区切りで連結
# する (∙ は無色リテラル。model 色と effort 色が別シーケンスなので前後にスペースは置かない)。
# OFF のときは従来どおりスペース 1 個で連結する。
# effort 語句のみ effort_effect で塗る (∙ は塗らない。max でも ∙ は rainbow 循環に入らない)。
# 連結は変数展開のみ。effort_field は $(...) で改行除去済みのため static 無色時の末尾改行は混入しない。
if [ -n "$effort" ]; then
  effort_effect=$(effort_color "$effort")
  effort_field=$(paint "$effort" $effort_effect)
  if [ "$SHOW_MODEL_NAME" = "1" ]; then
    model_field="${model_field}∙${effort_field}"
  else
    model_field="${model_field} ${effort_field}"
  fi
fi

# 1 行目に出すカレントディレクトリ名。cwd の basename を追加の git 呼び出しなしで得る。
# cwd が "/" または空のとき ${cwd##*/} は空文字になるため、その場合は列ごと省略する
# (branch / session_name と同じ「空なら列ごと省く」方針)。
# SHOW_CWD=0 のときは directory 列だけを出さず、2 行構成そのものは維持する
# (branch 列と session_name は 1 行目に残る)。
#
# 末尾スラッシュの剥がしは必要: cwd="/tmp/project/" のような値でも
# ${cwd##*/} は空文字になるため、剥がさないと **実在する名前付きディレクトリなのに
# directory 列が丸ごと消える**。cwd は入力 JSON 由来で末尾スラッシュ付きも渡り得る。
# "/" だけは剥がすと空文字になり、本来の「ルートは列ごと省略」と同じ結果へ収束する。
# 剥がしもパラメータ展開のみで完結させる (描画経路に git / basename の fork を足さない)。
dir_field=""
if [ "$SHOW_CWD" = "1" ]; then
  dir_path="$cwd"
  while [ "${dir_path%/}" != "$dir_path" ]; do
    dir_path="${dir_path%/}"
  done
  dir_name="${dir_path##*/}"
  [ -n "$dir_name" ] && dir_field=$(truncate_label 25 "$dir_name")
fi

# 2 行目の列順: LAYOUT_LINE2 (既定 model_ctx → rate)
# model_ctx は model と ctx をスペース 1 個で結合した 1 トークン (両者の間にパイプは出さない)。
# 2 行目は常に出力するため、値が空でも要素を落とさず無条件に積む (空なら省略は 1 行目のみ)。
# 末尾に既定の全トークンを足して走査し、書かれなかったトークンを既定順で補う (✻ を消せないようにする)。
build_layout "${LAYOUT_LINE2}|model_ctx|rate" "|model_ctx|rate|" 1
parts=("${layout_parts[@]}")

# 1 行目の列順: LAYOUT_LINE1 (既定 directory? → branch? → session?)
# 2 行目の parts とは別の配列で組み立て、空でないときだけ「join + 改行」を出す。
# 値が空のトークンと未知のトークンは列ごと省略する (区切りも出さない)。
# 全部空のときは改行そのものを出さない (空行が statusline の高さを 1 行占有するため)。
# 改行は 1 行目の**末尾**に置く (2 行目の先頭に置くと、1 行目が無いとき先頭に空行が出る)。
build_layout "$LAYOUT_LINE1" "|directory|branch|session|" 0
line1_parts=("${layout_parts[@]}")

# " | " で結合
if [ ${#line1_parts[@]} -gt 0 ]; then
  printf '%s\n' "$(join_by ' | ' "${line1_parts[@]}")"
fi
printf '%s' "$(join_by ' | ' "${parts[@]}")"
printf '\n'
