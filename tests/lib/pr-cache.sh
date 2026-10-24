# shellcheck shell=bash
# pr トークンのキャッシュをテストごとに仕込むヘルパ。
#
# pr-cache/<case> があれば、そのケースの履歴ディレクトリに次の 2 つを置く:
#   - キャッシュ ${hist_dir}/pr-<key>: 1 行目をキャッシュの 1 行として書く (空行なら置かない)。
#     printf '%b' で展開するので、タブは \t、ESC は \033 と書ける。さらに次のプレースホルダーを
#     置き換える (fetched_at は現在時刻に依存するため、仕込む直前に書き込む):
#       @NOW@   -> 現在時刻 (epoch 秒)
#       @STALE@ -> 現在時刻 - 4000 (PR_STALE_SEC の 1800 を超えて古い)
#   - マーカー ${hist_dir}/pr-<key>.marker: 今書いた空ファイル。再取得の間隔内になるため、
#     描画は取得を起動せず、仕込んだキャッシュがそのまま読まれる。
#
# <key> は本体と同じく「cwd + 改行 + ローカルのブランチ名」の cksum。ブランチ名は fixture の
# current_dir に埋めた fake git の規約 (#...;branch=<name>;...) から取る。
#
# regression.sh / e2e-preview.sh から使う (ドリフト防止のため共有)。

PR_CACHE_LIB_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# pr_cache_key <cwd> <branch> : 本体と同じ規則でキーを出す。
pr_cache_key() {
  local key
  key=$(printf '%s\n%s' "$1" "$2" | cksum)
  printf '%s' "${key%% *}"
}

# seed_pr_cache_for_case <case> <fixture> <hist_dir>
seed_pr_cache_for_case() {
  local case_name=$1 fixture=$2 hist_dir=$3
  local path="$PR_CACHE_LIB_TESTS_DIR/pr-cache/$case_name"
  [ -f "$path" ] || return 0

  local template=""
  IFS= read -r template < "$path" || true

  local cwd spec branch="" token
  cwd=$(jq -r '.workspace.current_dir // ""' < "$fixture")
  spec=${cwd##*'#'}
  while [ -n "$spec" ]; do
    token=${spec%%;*}
    case "$spec" in *';'*) spec=${spec#*;} ;; *) spec="" ;; esac
    case "$token" in branch=*) branch=${token#branch=} ;; esac
  done

  local cache
  cache="$hist_dir/pr-$(pr_cache_key "$cwd" "$branch")"
  if [ -n "$template" ]; then
    local now
    now=$(date +%s)
    template=${template//@NOW@/$now}
    template=${template//@STALE@/$((now - 4000))}
    printf '%b\n' "$template" > "$cache"
  fi
  : > "$cache.marker"
}
