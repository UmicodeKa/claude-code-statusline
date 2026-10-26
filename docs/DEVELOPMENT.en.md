English | [🗾 日本語はこちら](./DEVELOPMENT.md)

# Development Guide

> This is an English translation. If it differs from the Japanese version ([DEVELOPMENT.md](./DEVELOPMENT.md)), the Japanese version is authoritative.

This document is for the owner and coding agents, and covers setting up the development environment and how to proceed with changes.
This repository does not accept Issues or Pull Requests (see the "For developers" section of [README.en.md](../README.en.md#for-developers) for the policy).

## Related Documents

| Document | Contents |
| --- | --- |
| [README.en.md](../README.en.md) | Installation and configuration for users |
| [SPEC.en.md](SPEC.en.md) | Output specification (observable behavior such as separators, ordering, trimming, and colors) |
| [DESIGN.en.md](DESIGN.en.md) | The reasons behind design decisions, and implementation notes whose removal would cause bugs |
| [tests/README.en.md](../tests/README.en.md) | Structure of the test harness and how to write fixtures and assertions |

## Core Principles

This repository has two scripts: the macOS version (`statusline-macos.sh`) and the Linux version (`statusline-linux.sh`).

- The two **share a specification, and their implementations differ only in the platform-dependent parts** (the commands for getting dates and file times, the locking mechanism, and so on).
- The requirement is that the two scripts return identical output for the same input. Changing only one of them easily causes the outputs to drift apart, so changes that affect the shared specification go into both scripts.
- Changes that do not alter the output, such as refactoring and hardening, do not rewrite existing assertions (`tests/assertions/*`). That the existing tests pass unchanged is the confirmation that the output has not changed.
- Changes that alter the output update [SPEC.en.md](SPEC.en.md) and the relevant assertions in the same change.
- The criterion is not how broad the change is, but whether any existing case fails. A refactoring for which `npm test` passes without changing any existing assertion may be included in the same change as a feature addition.
  A change that alters the output, even a small one, is verified on its own.

## Setting Up the Development Environment

### Requirements

- bash and `jq` (needed to run the scripts and the tests)
- `git`
- Node.js and npm

Node.js is used only for Markdown linting (`markdownlint-cli2`) and formatting, and for running npm scripts in parallel and in sequence (`npm-run-all2`). The statusline scripts themselves do not depend on Node.js.

### Setup

```sh
git clone https://github.com/UmicodeKa/claude-code-statusline.git
cd claude-code-statusline
npm ci
```

Running `npm ci` runs the `prepare` script (`scripts/setup-hooks.mjs`), which sets `git config core.hooksPath .githooks` to enable the bundled git hooks.

- If `core.hooksPath` is already set to a different value, it is not overwritten; a warning is shown and the script exits. To enable the hooks in that case, run `git config core.hooksPath .githooks` manually.
- In an environment without `.git` or without `git`, it does nothing, and the installation itself does not fail.

### Branch Name Rules

`.githooks/reference-transaction` checks the name when a branch is created, and rejects the creation of a branch whose name does not follow the rules. The following are allowed.

- Names that start with the prefix `feature/`, `release/`, `hotfix/`, or `dependabot/`
- `main`

Only new creation is checked. Commits to existing branches and renames (`git branch -m`) are not checked.

```sh
git switch -c feature/your-topic
```

### Commit Message Template

Write commit messages in the form `<type>[(scope)]: <content>` following the `.gitmessage` template. The type uses a prefix with an emoji (for example `🐛fix`, `✨feat`, `📝docs`, `♻️refactor`, `💚test`, `🔧ci`, `🧹chore`).
The full list and examples of how to write them are in the template.

To enable the template, run the following.

```sh
git config commit.template .gitmessage
```

## Common Commands

| Command | What it does |
| --- | --- |
| `npm test` | Runs, in order, the regression tests (`tests/regression.sh`), the background fetch behavior tests (`tests/git-fetch-behavior.sh`), the PR status display retrieval behavior tests (`tests/pr-status-behavior.sh`), the rate history behavior tests (`tests/rate-history-behavior.sh`), the static parity check of both versions (`tests/script-parity.sh`), and the sync check of the Japanese and English documents (`tests/translation-parity.sh`) |
| `npm run preview` | Shows the actual output of each fixture in the terminal with the ANSI colors intact (`tests/e2e-preview.sh`). `--macos` / `--linux` shows only one version (`bash tests/e2e-preview.sh --linux`) |
| `npm run check` | Runs the Markdown format check and lint |
| `npm run fix` | Runs the Markdown formatting and the automatic lint fixes |

For the structure of the tests and how to add fixtures, see [tests/README.en.md](../tests/README.en.md).

## How to Proceed with Changes

1. Before starting a change, run `npm test` and confirm that everything passes (confirming the baseline).
2. Check the section of [SPEC.en.md](SPEC.en.md) and the notes in [DESIGN.en.md](DESIGN.en.md) that relate to the part you are changing.
3. Apply the change to both scripts.
4. If the change alters the output, update [SPEC.en.md](SPEC.en.md) and the assertions, and add fixtures as needed.
5. When you change a Japanese document that has an English version (`README.md`, `docs/SPEC.md`, `docs/DESIGN.md`, `docs/DEVELOPMENT.md`, `tests/README.md`), update the corresponding `*.en.md` in the same change.
   The Japanese version is authoritative, and wins when the two differ.
   `tests/translation-parity.sh` (part of `npm test`) detects mismatches in headings, table rows, code spans and list nesting.
   The comments in `statusline.conf` are bilingual and have no automatic check, so when you change a comment, update both the Japanese and the English lines.
6. Verify with the following three.
   - `npm test` passes completely
   - `npm run check` passes (if there are errors, `npm run fix` fixes most of them)
   - Visually check the actual display, including colors, with `npm run preview`

### Verifying on macOS and Linux

The test harness skips the cases for the script that cannot run in the current environment. The skip conditions and the CI settings are summarized in [tests/README.en.md](../tests/README.en.md#execution-environment-and-skips).

- GitHub Actions (`.github/workflows/ci.yml`) runs `lint` (`npm run check:ci`) and `test` (`npm test`) on ubuntu. The only tests that run on CI are for the Linux version.
  The macOS version is skipped on CI, so changes involving the macOS version are verified by running `npm test` on a local macOS.
- If you install bash 4.1 or later and `flock` on macOS with `brew install bash flock`, the harness also runs the Linux version's cases.
  However, the Linux version uses GNU coreutils' `stat -c` and `date -d`, and the BSD `stat` / `date` that ship with macOS do not accept these options.
  As a result, the history directory check and the display of the reset time (`HH:MM`) do not work, and most of the Linux version's cases fail on macOS.
- Verify the Linux version on CI, or by running `npm test` in a Linux container or virtual machine.

## Markdown Formatting

`npm run fix` unifies the notation of Markdown punctuation and parentheses (converting half-width punctuation to full-width, and full-width parentheses and alphanumerics to half-width, for example).
The conversion rules are in `scripts/format-markdown.mjs`.

You do not need to fix notation inconsistencies by hand. If you notice one, run `npm run fix`.

## Writing a Pull Request

Write the Pull Request description following the template (`.github/pull_request_template.md`). For what else to include, see the "変更の進め方" (How to proceed with changes) section of [CLAUDE.md](../CLAUDE.md).

If you change the constants for history sampling and throttling (the defaults and recommended ranges of `RATE_CHART_LEN` / `RATE_CHART_LEN_MAX` / `POLL_INTERVAL_SEC` / `LOCK_TIMEOUT_SEC` / `GIT_FETCH_INTERVAL_SEC`), first clarify the purpose in an Issue.

## License

This repository is published under the [0BSD](../LICENSE) license.
