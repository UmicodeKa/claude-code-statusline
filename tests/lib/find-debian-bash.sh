# shellcheck shell=bash
# Linux 版 statusline を実行できる環境かを判定し、その bash (4.1+) を返すヘルパ。
#
# Linux 版は `exec {fd}>...` (named file descriptor) を使うため bash 4.1+ 必須。
# macOS の /bin/bash は 3.2 で冒頭ガードに引っかかるため、4.1 以上が見つかった
# ときだけ Linux 版をテストする。見つからなければ空文字を返し、呼び出し側は
# Linux 版を skip する。
#
# bash に加えて `flock` も必須とする。Linux 版はロックを flock で取るため冒頭で
# その存在をチェックし、無ければ `✻ -- (flock required: ...)` を出して exit する。
# flock は macOS に標準で存在しないので、brew bash だけが入った mac では bash の
# バージョンだけを見ると Linux 版のケースが起動して必ず落ちる。
# (jq は Linux 版固有ではなく両版共通の要件なので、ここではなく各テストの前提チェックで見る)
#
# regression.sh と git-fetch-behavior.sh の両方から使う (ドリフト防止のため共有)。
find_debian_bash() {
  local candidate full_path
  command -v flock >/dev/null 2>&1 || { printf ''; return; }
  for candidate in bash /opt/homebrew/bin/bash /usr/local/bin/bash; do
    full_path="$(command -v "$candidate" 2>/dev/null || true)"
    [ -z "$full_path" ] && continue
    if "$full_path" -c '
      [ "${BASH_VERSINFO[0]}" -gt 4 ] \
        || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }
    ' >/dev/null 2>&1; then
      printf '%s' "$full_path"
      return 0
    fi
  done
  printf ''
}

# CI 用: STATUSLINE_TEST_REQUIRE_DEBIAN=1 のとき、Linux 版を実行できなければ
# skip せずエラー終了する。Linux 版は CI でしか検証しないため、環境の不備で
# 全件 skip されたまま green になるのを防ぐ。
# 引数: $1 呼び出し元スクリプト名 (エラーメッセージ用) / $2 find_debian_bash の結果
require_debian_bash_if_requested() {
  local caller=$1 debian_bash=$2
  [ "${STATUSLINE_TEST_REQUIRE_DEBIAN:-0}" = "1" ] || return 0
  [ -n "$debian_bash" ] && return 0
  printf '%s: STATUSLINE_TEST_REQUIRE_DEBIAN=1 but Linux script cannot run (need bash 4.1+ and flock)\n' \
    "$caller" >&2
  exit 2
}
