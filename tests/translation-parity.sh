#!/usr/bin/env bash
# 日本語の Markdown (正本) と英語版 (*.en.md) の同期漏れを検出する簡易チェック。
#
# 翻訳の質は見ない。日本語版だけを更新して英語版が取り残されたときに気づくための、
# 構造の一致だけを比べる。OS に依存しないため、どちらの環境でも CI でも走らせる。
#
#   0. lang-link:<名前>: 冒頭の 1 行が互いの言語版へのリンクになっている
#   1. headings:<名前> : 見出しの数が一致する
#   2. tables:<名前>   : 表の行数が一致する
#   3. spans:<名前>    : 日本語版のコードスパン (設定変数名やコマンド) が英語版にすべて含まれる
#                        (英語版にだけあるスパンは、日本語の語句の翻訳なので比べない)
#   4. lists:<名前>    : 箇条書きの項目の並びと字下げ (入れ子の深さ) が一致する
#                        (折り返しで字下げが落ちると、入れ子の項目が最上位の項目になる)
#
# コードブロックの中は数えない。コードスパンは日本語の文字やプレースホルダ (<...>) を含む
# ものを比べない (翻訳で変わるため)。比べる対象は PAIRS に並べる。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"

PAIRS=(
  "README.md README.en.md"
  "docs/SPEC.md docs/SPEC.en.md"
  "docs/DESIGN.md docs/DESIGN.en.md"
  "docs/DEVELOPMENT.md docs/DEVELOPMENT.en.md"
  "tests/README.md tests/README.en.md"
)

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }

total=0
failed=0

pass() {
  total=$((total + 1))
  printf '  %s %s\n' "$(green ok)" "$1"
}

fail() {
  total=$((total + 1))
  failed=$((failed + 1))
  printf '  %s %s: %s\n' "$(red FAIL)" "$1" "$2" >&2
}

strip_code_blocks() {
  awk '
    /^[[:space:]]*```/ { in_code = !in_code; next }
    !in_code { print }
  ' "$1"
}

count_headings() {
  strip_code_blocks "$1" | grep -c '^#\{1,6\} ' || true
}

count_table_rows() {
  strip_code_blocks "$1" | grep -c '^[[:space:]]*|' || true
}

# 日本語の文字 (UTF-8 の先頭バイトが 0xE3〜0xEF) と、翻訳で名前が変わるプレースホルダ (<...>) を
# 含まないコードスパンを重複なしで出す。
code_spans() {
  strip_code_blocks "$1" \
    | LC_ALL=C grep -o '`[^`]*`' \
    | LC_ALL=C grep -v -e "$(printf '[\343-\357]')" -e '<' \
    | LC_ALL=C sort -u || true
}

# 箇条書き (- * 1.) の項目ごとの字下げの幅を、出現順に 1 行ずつ出す。
list_indents() {
  strip_code_blocks "$1" \
    | LC_ALL=C sed -nE 's/^([[:space:]]*)([-*]|[0-9]+\.) .*/\1/p' \
    | LC_ALL=C awk '{ print length($0) }'
}

check_count() {
  local kind=$1 name=$2 ja_count=$3 en_count=$4
  if [ "$ja_count" -eq "$en_count" ]; then
    pass "$kind:$name ($ja_count)"
  else
    fail "$kind:$name" "ja=$ja_count en=$en_count"
  fi
}

check_pair() {
  local ja=$1 en=$2
  local name=${ja%.md}
  if [ ! -f "$REPO_DIR/$ja" ] || [ ! -f "$REPO_DIR/$en" ]; then
    fail "exists:$name" "missing $ja or $en"
    return
  fi

  check_language_links "$ja" "$en"
  check_count headings "$name" "$(count_headings "$REPO_DIR/$ja")" "$(count_headings "$REPO_DIR/$en")"
  check_count tables "$name" "$(count_table_rows "$REPO_DIR/$ja")" "$(count_table_rows "$REPO_DIR/$en")"

  local first_diff
  first_diff="$(paste -d: <(list_indents "$REPO_DIR/$ja") <(list_indents "$REPO_DIR/$en") \
    | awk -F: '$1 != $2 { print NR; exit }' || true)"
  if [ -z "$first_diff" ]; then
    pass "lists:$name"
  else
    fail "lists:$name" "list item #$first_diff differs in indent (nesting) or count between $ja and $en"
  fi

  local only_ja
  only_ja="$(LC_ALL=C comm -23 <(code_spans "$REPO_DIR/$ja") <(code_spans "$REPO_DIR/$en"))"
  if [ -z "$only_ja" ]; then
    pass "spans:$name"
  else
    fail "spans:$name" "code spans missing from $en"
    printf '%s\n' "$only_ja" | sed 's/^/      /' >&2
  fi
}

check_language_links() {
  local ja=$1 en=$2
  local name=${ja%.md}
  local ja_base=${ja##*/} en_base=${en##*/}
  if head -n 1 "$REPO_DIR/$ja" | grep -qF "[🌍 English version here](./$en_base)" \
    && [ "$(head -n 1 "$REPO_DIR/$en")" = "English | [🗾 日本語はこちら](./$ja_base)" ]; then
    pass "lang-link:$name"
  else
    fail "lang-link:$name" "first line must link to the other language ($ja_base <-> $en_base)"
  fi
}

main() {
  local pair ja en
  for pair in "${PAIRS[@]}"; do
    read -r ja en <<<"$pair"
    check_pair "$ja" "$en"
  done

  printf '\n'
  if [ "$failed" -eq 0 ]; then
    printf '%s: %d/%d passed\n' "$(green PASS)" "$total" "$total"
    exit 0
  else
    printf '%s: %d/%d failed\n' "$(red FAIL)" "$failed" "$total" >&2
    exit 1
  fi
}

main "$@"
