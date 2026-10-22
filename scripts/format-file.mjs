#!/usr/bin/env node
// Claude Code の PostToolUse hook から呼ばれ、編集された「単一ファイルだけ」を整形する。
//
// ┌─ 同期について (重要) ─────────────────────────────────────────────────────┐
// │ この処理は package.json の `fix` を単一ファイル向けに再現したもの:          │
// │   fix = run-s format lint:fix                                              │
// │     - format    : format-markdown.mjs の文字正規化 → 下記 formatText 分岐  │
// │     - lint:fix   : markdownlint-cli2 --fix         → 下記 markdownlint 分岐 │
// │ 整形の振り分けを変えるときは package.json 側の `format` / `lint:fix` と揃える。│
// │ (文字正規化ルールは format-markdown.mjs、lint ルールは .markdownlint*.json/  │
// │  .markdownlint-cli2.jsonc が正本。markdownlint-cli2 は cwd=リポジトリルート  │
// │  から設定を自動探索するので CI と同一になる)                                 │
// └──────────────────────────────────────────────────────────────────────────┘
//
// best-effort: 整形に失敗しても hook をブロックしない (常に exit 0 で終える)。

import { execFile } from 'node:child_process';
import { access, constants, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { promisify } from 'node:util';

import { formatText } from './format-markdown.mjs';

const execFileAsync = promisify(execFile);

// このスクリプトは scripts/ 配下にあるので、一つ上がリポジトリルート。
// markdownlint-cli2 は cwd 起点で設定を探索するため、必ずここを cwd にして実行する。
const repoRoot = resolve(import.meta.dirname, '..');
const binDir = resolve(repoRoot, 'node_modules', '.bin');

// 対象拡張子は Markdown のみ。
const MARKDOWNLINT_EXTS = new Set(['.md']);

// .markdownlint-cli2.jsonc の ignores と揃える。
// markdownlint-cli2 は単一ファイルを引数指定すると ignores を無視するため、
// ここで明示的に除外判定を入れて全体 lint と挙動を合わせる。
const IGNORE_PATTERNS = [
  /(^|\/)node_modules(\/|$)/,
  /(^|\/)\.github\/pull_request_template\.md$/,
  /(^|\/)\.claude\/handovers\.local\//,
];

/** hook の stdin から渡る JSON 全体を読み取る。 */
function readStdin() {
  return new Promise((resolveStdin) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
      data += chunk;
    });
    process.stdin.on('end', () => resolveStdin(data));
    process.stdin.on('error', () => resolveStdin(''));
  });
}

/** tool_input から対象ファイルパスを取り出す (単一/複数の両方に対応)。 */
function extractFilePaths(payload) {
  const toolInput = payload?.tool_input ?? {};
  const paths = [];
  if (typeof toolInput.file_path === 'string') paths.push(toolInput.file_path);
  if (Array.isArray(toolInput.file_paths)) {
    for (const p of toolInput.file_paths) {
      if (typeof p === 'string') paths.push(p);
    }
  }
  return paths;
}

/** node_modules/.bin のバイナリを repoRoot を cwd にして実行する (失敗は握り潰す)。 */
async function runTool(bin, args) {
  try {
    await execFileAsync(resolve(binDir, bin), args, { cwd: repoRoot });
  } catch (err) {
    // 整形失敗・lint エラーは hook をブロックしない。原因だけ stderr に残す。
    const msg = err?.stderr || err?.stdout || err?.message || String(err);
    process.stderr.write(`format-file: ${bin} failed for ${args.at(-1)}\n${msg}\n`);
  }
}

/** 文字正規化 (format-markdown.mjs と同一ルール) を単一ファイルに適用する。 */
async function normalizeChars(abs) {
  try {
    const content = await readFile(abs, 'utf8');
    const formatted = formatText(content);
    if (content !== formatted) {
      await writeFile(abs, formatted, 'utf8');
    }
  } catch (err) {
    process.stderr.write(`format-file: normalize failed for ${abs}\n${err?.message || err}\n`);
  }
}

/** 単一ファイルを整形する (Markdown のみ対象)。 */
async function formatFile(filePath) {
  const abs = resolve(repoRoot, filePath);

  // リポジトリ外・node_modules 配下・存在しないファイルは対象外。
  if (!abs.startsWith(repoRoot + '/')) return;
  const rel = abs.slice(repoRoot.length + 1);
  // ドット始まりのディレクトリ/ファイル (.claude/, .github/ 等) は対象外。
  // format-markdown.mjs の findMarkdownFiles が startsWith('.') で全スキップする
  // のと揃える (一括 fix で正規化されないファイルを hook が書き換えないため)。
  if (rel.split('/').some((seg) => seg.startsWith('.'))) return;
  if (IGNORE_PATTERNS.some((re) => re.test(rel))) return;
  try {
    await access(abs, constants.F_OK);
  } catch {
    return;
  }

  const ext = abs.slice(abs.lastIndexOf('.')).toLowerCase();
  if (!MARKDOWNLINT_EXTS.has(ext)) return;

  // fix と同じ順序: 文字正規化 → markdownlint --fix。
  await normalizeChars(abs);
  await runTool('markdownlint-cli2', ['--fix', abs]);
}

async function main() {
  const raw = await readStdin();
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch {
    return; // JSON でなければ何もしない。
  }

  const paths = extractFilePaths(payload);
  // ファイルごとに順次整形 (1 ファイル想定だが複数でも安全に処理)。
  for (const p of paths) {
    await formatFile(p);
  }
}

// 何があっても hook をブロックしない: 常に exit 0。
main()
  .catch((err) => {
    process.stderr.write(`format-file: ${err?.message || err}\n`);
  })
  .finally(() => {
    process.exitCode = 0;
  });
