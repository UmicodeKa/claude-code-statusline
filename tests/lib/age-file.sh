# shellcheck shell=bash
# ファイルの mtime をずらすヘルパ。間引き (マーカーや履歴ファイルの mtime) を検証する挙動テストで使う。
#
# pr-status-behavior.sh / rate-history-behavior.sh から使う (ドリフト防止のため共有)。

# ファイル $1 の mtime を $2 秒前にする。touch -t は macOS / GNU の両方にあり、時刻はローカル時刻で
# 解釈される。epoch 秒からの変換は BSD date (-r) を先に試し、だめなら GNU date (-d @) を使う。
age_file() {
  local old=$(( $(date +%s) - $2 ))
  touch -t "$(date -r "$old" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$old" +%Y%m%d%H%M.%S)" "$1"
}
