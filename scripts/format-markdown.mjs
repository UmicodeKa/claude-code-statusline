#!/usr/bin/env node

import { readdir, readFile, writeFile } from 'fs/promises';
import { join, relative } from 'path';
import { fileURLToPath } from 'url';
import { argv } from 'process';

/**
 * マークダウンファイルの文字を統一するフォーマッター
 */

// 変換ルール
export const CONVERSIONS = [
  // 句読点
  { from: /､/g, to: '、' },
  { from: /｡/g, to: '。' },

  // 括弧
  { from: /（/g, to: '(' },
  { from: /）/g, to: ')' },

  // 引用符
  { from: /「/g, to: '｢' },
  { from: /」/g, to: '｣' },

  // 中黒
  { from: /・/g, to: '･' },

  // 全角数字 -> 半角数字
  { from: /０/g, to: '0' },
  { from: /１/g, to: '1' },
  { from: /２/g, to: '2' },
  { from: /３/g, to: '3' },
  { from: /４/g, to: '4' },
  { from: /５/g, to: '5' },
  { from: /６/g, to: '6' },
  { from: /７/g, to: '7' },
  { from: /８/g, to: '8' },
  { from: /９/g, to: '9' },

  // 全角英字（小文字） -> 半角英字
  { from: /ａ/g, to: 'a' },
  { from: /ｂ/g, to: 'b' },
  { from: /ｃ/g, to: 'c' },
  { from: /ｄ/g, to: 'd' },
  { from: /ｅ/g, to: 'e' },
  { from: /ｆ/g, to: 'f' },
  { from: /ｇ/g, to: 'g' },
  { from: /ｈ/g, to: 'h' },
  { from: /ｉ/g, to: 'i' },
  { from: /ｊ/g, to: 'j' },
  { from: /ｋ/g, to: 'k' },
  { from: /ｌ/g, to: 'l' },
  { from: /ｍ/g, to: 'm' },
  { from: /ｎ/g, to: 'n' },
  { from: /ｏ/g, to: 'o' },
  { from: /ｐ/g, to: 'p' },
  { from: /ｑ/g, to: 'q' },
  { from: /ｒ/g, to: 'r' },
  { from: /ｓ/g, to: 's' },
  { from: /ｔ/g, to: 't' },
  { from: /ｕ/g, to: 'u' },
  { from: /ｖ/g, to: 'v' },
  { from: /ｗ/g, to: 'w' },
  { from: /ｘ/g, to: 'x' },
  { from: /ｙ/g, to: 'y' },
  { from: /ｚ/g, to: 'z' },

  // 全角英字（大文字） -> 半角英字
  { from: /Ａ/g, to: 'A' },
  { from: /Ｂ/g, to: 'B' },
  { from: /Ｃ/g, to: 'C' },
  { from: /Ｄ/g, to: 'D' },
  { from: /Ｅ/g, to: 'E' },
  { from: /Ｆ/g, to: 'F' },
  { from: /Ｇ/g, to: 'G' },
  { from: /Ｈ/g, to: 'H' },
  { from: /Ｉ/g, to: 'I' },
  { from: /Ｊ/g, to: 'J' },
  { from: /Ｋ/g, to: 'K' },
  { from: /Ｌ/g, to: 'L' },
  { from: /Ｍ/g, to: 'M' },
  { from: /Ｎ/g, to: 'N' },
  { from: /Ｏ/g, to: 'O' },
  { from: /Ｐ/g, to: 'P' },
  { from: /Ｑ/g, to: 'Q' },
  { from: /Ｒ/g, to: 'R' },
  { from: /Ｓ/g, to: 'S' },
  { from: /Ｔ/g, to: 'T' },
  { from: /Ｕ/g, to: 'U' },
  { from: /Ｖ/g, to: 'V' },
  { from: /Ｗ/g, to: 'W' },
  { from: /Ｘ/g, to: 'X' },
  { from: /Ｙ/g, to: 'Y' },
  { from: /Ｚ/g, to: 'Z' },

  // 全角スペース -> 半角スペース
  { from: /　/g, to: ' ' },
];

/**
 * テキストにフォーマット変換を適用
 */
export function formatText(text) {
  let result = text;
  for (const { from, to } of CONVERSIONS) {
    result = result.replace(from, to);
  }
  return result;
}

/**
 * ディレクトリを再帰的に走査してマークダウンファイルを取得
 */
async function findMarkdownFiles(dir, baseDir = dir) {
  const files = [];
  const entries = await readdir(dir, { withFileTypes: true });

  for (const entry of entries) {
    const fullPath = join(dir, entry.name);

    // node_modules, .gitなどを除外
    if (entry.name === 'node_modules' || entry.name.startsWith('.')) {
      continue;
    }

    if (entry.isDirectory()) {
      files.push(...await findMarkdownFiles(fullPath, baseDir));
    } else if (entry.isFile() && entry.name.endsWith('.md')) {
      files.push(fullPath);
    }
  }

  return files;
}

/**
 * マークダウンファイルを処理(フォーマットまたはチェック)
 * @param {string} filePath
 * @param {boolean} checkOnly - trueの場合はファイルを書き込まずチェックのみ
 * @returns {'formatted' | 'unchanged' | 'error'} 処理結果
 */
async function processMarkdownFile(filePath, checkOnly = false) {
  try {
    const content = await readFile(filePath, 'utf-8');
    const formatted = formatText(content);

    if (content !== formatted) {
      if (!checkOnly) {
        await writeFile(filePath, formatted, 'utf-8');
      }
      return 'formatted';
    }
    return 'unchanged';
  } catch (error) {
    console.error(`Error processing ${filePath}:`, error?.message ?? String(error));
    return 'error';
  }
}

/**
 * メイン処理
 */
async function main() {
  const isCheckMode = process.argv.includes('--check');
  const rootDir = process.cwd();

  const mdFiles = await findMarkdownFiles(rootDir);

  if (mdFiles.length === 0) {
    console.log('No markdown files found.');
    return;
  }

  let changedCount = 0;
  let errorCount = 0;

  for (const filePath of mdFiles) {
    const relativePath = relative(rootDir, filePath);
    const result = await processMarkdownFile(filePath, isCheckMode);

    if (result === 'formatted') {
      if (isCheckMode) {
        console.log(`[warn] ${relativePath}`);
      } else {
        console.log(`[formatted] ${relativePath}`);
      }
      changedCount++;
    } else if (result === 'error') {
      errorCount++;
    }
  }

  if (isCheckMode) {
    if (changedCount > 0) {
      console.log(`\nCode style issues found in ${changedCount} file(s). Run \`npm run format\` to fix.`);
    } else {
      console.log('All files are formatted.');
    }
  } else {
    if (changedCount > 0) {
      console.log(`\n${changedCount} file(s) formatted.`);
    } else {
      console.log('All files are already formatted.');
    }
  }

  if (errorCount > 0) {
    console.error(`${errorCount} file(s) had errors.`);
    process.exit(1);
  }

  if (isCheckMode && changedCount > 0) {
    process.exit(1);
  }
}

// このファイルを直接実行したときだけ CLI として走らせる
// (format-file.mjs から import されたときは main を呼ばない)
if (argv[1] && fileURLToPath(import.meta.url) === argv[1]) {
  main().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
  });
}
