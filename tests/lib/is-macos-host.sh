# shellcheck shell=bash
# macOS 版 statusline を実行できる環境 (= macOS ホスト) かを判定するヘルパ。
#
# macOS 版は BSD 系コマンド前提のため、Linux (CI の ubuntu runner 等) では動かない。
# macOS ホストでなければ呼び出し側は macOS 分のケースを skip する
# (Debian 版を find_debian_bash で skip するのと対になる仕組み)。
#
# regression.sh と git-fetch-behavior.sh の両方から使う (ドリフト防止のため共有)。
is_macos_host() {
  [ "$(uname -s)" = "Darwin" ]
}
