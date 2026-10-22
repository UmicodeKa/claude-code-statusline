# shellcheck shell=bash
# ANSI エスケープシーケンスを可読化するヘルパ。
# 入力中の 0x1b を文字列 "\e" に変換する。
# 例: "\033[33mhello\033[0m" -> "\e[33mhello\e[0m"
escape_ansi() {
  perl -pe 's/\x1b/\\e/g'
}
