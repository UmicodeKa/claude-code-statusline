English | [🗾 日本語はこちら](./README.md)

# Tests

> This is an English translation. If it differs from the Japanese version ([README.md](./README.md)), the Japanese version is authoritative.

These tests check that the macOS version (`statusline-macos.sh`) and the Linux version (`statusline-linux.sh`) return the same output for the same input. For the output specification, see [docs/SPEC.en.md](../docs/SPEC.en.md).
For the mapping between each defensive piece of code and the test that guards it, see [docs/DESIGN.en.md](../docs/DESIGN.en.md). For setting up the development environment, see [docs/DEVELOPMENT.en.md](../docs/DEVELOPMENT.en.md).

## Harness Roles

| Script | How to run | Role |
| --- | --- | --- |
| `regression.sh` | `npm run test:regression` | Feeds fixtures to both scripts and compares the output against assertions |
| `git-fetch-behavior.sh` | `npm run test:fetch` | Verifies the behavior of the background fetch with `GIT_FETCH=1` |
| `pr-status-behavior.sh` | `npm run test:pr` | Verifies the behavior of the background retrieval of the PR status display, and the transformation done by `--jq` |
| `rate-history-behavior.sh` | `npm run test:history` | Verifies writes to the rate history file (initial fill, throttling, number of saved entries) and the clamping of the throttling interval |
| `e2e-preview.sh` | `npm run preview` | Prints the actual ANSI-colored output to the terminal for visual inspection |
| `script-parity.sh` | `npm run test:parity` | Statically checks that the shared blocks of both scripts match and that required code is still present |
| `translation-parity.sh` | `npm run test:translation` | Statically checks that the structure of each Japanese document and its English version (`*.en.md`) has not drifted apart |

`npm test` runs `test:regression`, `test:fetch`, `test:pr`, `test:history`, `test:parity`, and `test:translation` in order. `e2e-preview.sh` does not judge pass or fail, so it is not part of `npm test`.

### regression.sh

- Passes each file in `fixtures/*.json` to the standard input of both scripts and checks the output against the assertion file of the same name in `assertions/*.txt`. A fixture without an assertion file counts as a failure.
- The output is compared after `lib/escape-ansi.sh` replaces ESC (0x1b) with the string `\e` and BEL (0x07, the terminator of OSC 8) with the string `\a`.
- It runs with `TZ=UTC`, so the reset time (`HH:MM`) is determined in UTC.
- Besides the fixtures, there is one check (`bash-4.1-gate`) that statically verifies that the bash 4.1+ gate code remains verbatim in the first 20 lines of the Linux version.

### git-fetch-behavior.sh

A fetch is fire-and-forget asynchronous work and does not appear in the rendered output, so this script uses a fake git hook (described later) to check invariants other than the output.
The input is fixed to `fixtures/67-git-fetch-ahead.json` (with an upstream). There are 6 cases, each run for both versions.

| Case name | What it verifies |
| --- | --- |
| `fetch-invoked` | The fetch is actually started |
| `non-blocking` | Rendering returns in under 3 seconds even if the fetch takes 5 seconds |
| `throttle` | A second render within the throttling interval does not start a fetch |
| `lock-released` | No lock remains while the fetch is running (checked with `flock -n` on the Linux version, and by the presence of the lock dir on the macOS version) |
| `marker-unwritable` | No fetch is started when the throttling marker cannot be written |
| `clamp-zero-interval` | Even if the conf sets `GIT_FETCH_INTERVAL_SEC=0`, it is clamped to the lower bound and throttling still works |

`marker-unwritable` reproduces the write failure by first creating a directory with the same name as the marker. Disabling writes with `chmod` is not used, because the write would succeed on CI running as root.

### pr-status-behavior.sh

The retrieval of the PR status display is also fire-and-forget asynchronous work, so this script uses a fake gh hook (described later) to check invariants other than the output.
Each case creates, inside a temporary directory, a real directory whose name embeds the fake git conventions, and passes it as `workspace.current_dir`.
The child process runs `cd` to the cwd and then calls `gh`, so it does not get as far as the retrieval if the cwd does not exist. The cases are as follows, each run for both versions.

| Case name | What it verifies |
| --- | --- |
| `invoked` | `gh` is started when `PR_STATUS=1`, and the PR appears in the next render |
| `not-invoked-when-disabled` | `gh` is not started, and no `pr-*` files are created, when `PR_STATUS=0`, or when `PR_STATUS=1` but the branch column is not rendered |
| `non-blocking` | Rendering returns in under 3 seconds even if `gh` takes 5 seconds |
| `throttle` | A second render within the interval does not start `gh` |
| `single-flight` | While a retrieval is running (`.inflight` exists), the next `gh` is not started even after the interval has passed |
| `stale-inflight` | A `.inflight` older than 90 seconds is removed and retrieval resumes |
| `timeout` | `gh` is cut off even if it never finishes, and `.inflight` is removed (`CLAUDE_STATUSLINE_TEST_PR_TIMEOUT_SEC=1` sets it to 1 second) |
| `no-overwrite-by-older` | A cache whose `fetched_at` is newer than the retrieval's own start time is not overwritten |
| `branch-switch` | Switching branches in the same cwd gives a different cache key, so the previous branch's PR is not shown |
| `push-branch-name` | When the local name differs from the push target name, the query uses the push target's name and owner (the 3 URL forms) |
| `marker-unwritable` | `gh` is not started when the marker cannot be written |
| `gh-failure-keeps-cache` | When `gh` exits non-zero, the cache is not rewritten and the previous display is kept |
| `env-sanitized` | `GH_REPO` / `GH_FORCE_TTY` / `CLICOLOR_FORCE` are not passed to `gh`, the 3 variables for gh and the 4 variables for git are set, and `GH_TOKEN` is kept |
| `no-gh` | When `gh` is not on PATH, nothing is started and the column is omitted |
| `refresh-interval` | It starts at intervals of 30 / 300 / 900 seconds, based on the cache state and the time elapsed since the marker (300 seconds when the previous attempt failed) |
| `not-invoked-without-prerequisites` | `gh` is not started with a detached HEAD or a symlinked history directory (which disables the feature) |
| `future-fetched-at` | A cache whose `fetched_at` is in the future is not displayed and is replaced by the retrieval result |
| `comment-count` | The cached comment count is shown only if it is a positive integer of at most 9 digits with no leading 0 (`0`, `012`, 10 digits, and `-1` are not shown) |
| `early-on-change` | On a render where the signature of the stdin `pr` differs from the previous one, exactly one fetch starts without waiting for the interval (including a change in `review_state` alone) |
| `early-seen-missing` | When `.seen` does not exist, one fetch starts if `pr` is present; otherwise none starts and `.seen` is not created |
| `early-mismatch-persists` | Fetches do not keep starting while the stdin `pr` and the cache disagree (even after the minimum interval has passed) |
| `early-branch-switch` | Switching branches starts no fetch while the signature stays the same. When the signature changes, it starts on the new branch's key |
| `early-save-failure` | When `.seen` cannot be written, no early fetch starts and the marker is not rewritten. Once the interval passes, a regular fetch still starts. Nothing starts when the marker cannot be written either |
| `early-waits-inflight` | While a fetch is running, no early fetch starts and `.seen` is not written. It starts on the render after the fetch finishes |
| `early-inflight-during-lock` | When a fetch starts running while the render waits for the lock, no early fetch starts and `.seen` is not written (the lock is held from outside, and `.inflight` is created while the render waits). It starts on the render after the fetch finishes |
| `early-min-interval` | Within 30 seconds of the last early fetch, no early fetch starts and `.seen` is not written. It starts after that. It also starts right after a regular fetch |
| `early-seen-bad-time` | When the time in `.seen` is not a number (empty, `abc`, `0123`) or is in the future, the minimum interval is treated as having passed |
| `early-alternating` | Even when the signature alternates under the same `session_id`, fetches do not start more than once per 30 seconds |
| `early-two-sessions` | Even when two sessions on the same branch disagree on the signature, it stops after the first fetch of each |
| `early-mr` | When `pr.kind` is `mr`, nothing starts and `.seen` is not created |
| `early-session-id` | When `session_id` is empty, contains a disallowed character (`/`, `.`, a space, non-ASCII), or is 129 characters or longer, no early fetch starts and `.seen` is not created. A value starting with `served:`, a number, and exactly 128 characters do start an early fetch |
| `early-stdin-robust` | Even with a `pr` or `session_id` containing newlines or control characters, or a `pr` that is not an object (a string, number, array, boolean), the render matches the one with neither `pr` nor `session_id`, and `.seen` stays two lines. A `pr` without `review_state` starts an early fetch with an empty value in the signature |
| `early-no-extra-commands` | On a render whose signature has not changed, and on a render skipped by the minimum interval, the number of external command launches stays the same as on a render with neither `pr` nor `session_id` |
| `jq-fork-same-name` | Picks your own MERGED PR (HEAD matches) over an OPEN PR from someone else's fork with the same branch name |
| `jq-review-null-approved` | Even when `reviewDecision` is `null`, an `APPROVED` in `latestReviews` makes it approved |
| `jq-nullable-fields` | CI is empty when `statusCheckRollup` is `null`, and the count is 0 when `totalCommentsCount` is `null` |
| `jq-merged-head-mismatch` | A MERGED PR whose `headRefOid` differs from the local HEAD yields no PR |
| `jq-base-owner` | When there is no push target, candidates are narrowed by the owner of the base repository |
| `jq-other-owner` | A PR whose owner differs from the push target's owner is not picked up |
| `jq-open-changes-requested` | When `reviewDecision` is `null`, `CHANGES_REQUESTED` in `latestReviews` takes priority. `totalCommentsCount` (2 digits) is used as the count as is. `FAILURE` is fail |
| `jq-open-review-required` | `REVIEW_REQUIRED` is pending even if `latestReviews` contains `APPROVED` |
| `jq-closed-error` | CLOSED (HEAD matches) is closed with an empty review state. `ERROR` is fail |

- `jq-*` makes the fake gh return the GraphQL responses in `pr-responses/`, and checks the cache produced by evaluating the real `--jq` expression with a real `jq`.
  The `--jq` built into `gh` is gojq, so using a function that exists only in jq would not be detected.
- `no-gh` sets `PATH` to a directory containing only symlinks to the commands used by the main script and the fake git.
  The real `gh` is often in the same directory as `jq` (`/usr/bin` or `/opt/homebrew/bin`), so the whole directory cannot be dropped.
- `early-*` renders an input that contains `session_id` and `pr`, and checks the number of `gh` calls and the contents of `.seen`.
  Each case starts after placing a cache and a marker that keep the interval from starting a fetch. The time in `.seen` is written in its contents, so the minimum interval is reproduced by rewriting `.seen`.
- `early-no-extra-commands` hides the main external commands behind wrappers that record the called name and then `exec` the real command, and counts them. A fork of a subshell without an external command (a `$(...)` with only built-ins) cannot be detected.

### rate-history-behavior.sh

The latest saved value is hidden behind the current value at the right end of the chart, so whether anything was appended to the history does not show in the rendered output.
This script inspects the contents of the history file (`<history directory>/rate`) directly after rendering.
The old seeded value (`50`) and the current remaining value passed at render time (`90`) are set to differ, and whether an append happened is judged by whether the last line became the current remaining value.
The mtime is shifted with `lib/age-file.sh`. The cases are as follows, each run for both versions.

| Case name | What it verifies |
| --- | --- |
| `init-fill` | Rendering once with an empty history writes the current value 20 times (`RATE_CHART_LEN_MAX`) |
| `throttle` | Nothing is appended for a render within the interval (updated 10 seconds ago) |
| `append-after-interval` | One line is appended if the mtime is older than the interval (default 300 seconds) |
| `storage-cap` | Appending to a 25-line file truncates it to the last 20 lines |
| `poll-max-follows-chart-len` | With `RATE_CHART_LEN=20` and `POLL_INTERVAL_SEC=3000` in the conf, a line is appended to a history from 1000 seconds ago (the upper bound is clamped to 900) |
| `poll-max-default:*` | With `POLL_INTERVAL_SEC=99999` in the conf, nothing is appended at 1400 seconds ago, and a line is appended at 1600 seconds ago (upper bound 1500 for the default chart length of 12) |
| `poll-clamp-zero` | With `POLL_INTERVAL_SEC=0` in the conf, nothing is appended to a history from 30 seconds ago (lower bound 60) |
| `poll-invalid-default:*` | With `POLL_INTERVAL_SEC=abc` in the conf, nothing is appended at 250 seconds ago, and a line is appended at 350 seconds ago (default 300) |

The conf is written to a temporary file and passed in. `RATE_CHART_LEN` and `POLL_INTERVAL_SEC` have no env override, so the developer's shell environment variables do not change the result.

### e2e-preview.sh

- Shows the input JSON and the actual output side by side for all fixtures.
- So that the rate chart appears as a downward-sloping transition, it builds and seeds a dummy history of 20 entries (the number the main script stores) starting from the fixture's current value.
  The step is 5, and the older side is capped at 100.
- The history is isolated by passing a temporary directory made with `mktemp -d` as `CLAUDE_STATUSLINE_HISTORY_DIR`, and the production `/tmp/claude-statusline-<uid>/` is never touched.
  The temporary directory is deleted after each case is displayed.
- `--macos` / `--linux` shows only one version. Without options it shows the macOS version, and also the Linux version if bash 4.1+ is found.
- This script has its own bash discovery and does not check for `flock`.

### script-parity.sh

`regression.sh` verifies only the version that can run, so on CI (ubuntu) the macOS version is not run, and on a local macOS the Linux version is not run, which means a drift caused by fixing only one of them cannot be detected within the same run.
`script-parity.sh` performs only OS-independent static comparisons, so it can run on any OS. The checks are as follows.

| Check name | What it verifies |
| --- | --- |
| `block:config-load` | The config file loading block is character-for-character identical in both versions |
| `block:settings` | The customization settings block is identical in both versions |
| `block:interval-clamp` | The clamp block for the throttling constants is identical in both versions |
| `block:color-scheme` | The color scheme definition block is identical in both versions |
| `block:pr-constants` | The internal constants of the PR status display are identical in both versions |
| `block:pr-common` | The common part of the PR status display (query, `--jq`, cache read and write, child process spawn and body, rendering) is identical in both versions |
| `block:spark` | The spark and remaining-value calculation (`spark_of` / `round_int` / `set_remaining`) is identical in both versions |
| `block:history-chart` | The history file reading (`history_chart`) is identical in both versions. `history_push`, which acquires the lock differently, is excluded |
| `block:paint` | Coloring, highlighting, trimming, and git aggregation (`paint` / `highlight` / `*_color` / `truncate_label` / `truncate_branch` / `git_diff_stat` / `git_ahead_behind`) are identical in both versions |
| `block:format-layout` | Formatting of rate / ctx and assembly of the layout (`format_limit` / `format_ctx` / `layout_token` / `split_tokens` / `build_layout` / `join_by`) are identical in both versions |
| `block:main-render` | The rendering part of main (building `hl_set`, the rate chart, fetching branch / ab, building model and effort, directory, the `build_layout` call) is identical in both versions. The preceding jq reads are excluded because their comments differ between versions |
| `block:stdin-read` | The part of the jq reads after the comments, the `read` calls and the jq expression (including the signature and `session_id` used for early PR fetches), is identical in both versions |
| `static:locale` | `export LC_ALL=C.UTF-8` is in the first 20 lines |
| `static:no-prompt:<function>:*` | `GIT_TERMINAL_PROMPT=0` / `GIT_ASKPASS=/bin/true` / `SSH_ASKPASS=/bin/true` / `SSH_ASKPASS_REQUIRE=force` remain in each of `maybe_git_fetch` and `pr_spawn_refresh` |
| `static:fetch-fd-redirect` | `>/dev/null 2>&1 </dev/null` remains in `maybe_git_fetch` |
| `static:pr-gh-env:*` | `GH_PROMPT_DISABLED=1` / `GH_NO_UPDATE_NOTIFIER=1` / `GH_NO_EXTENSION_UPDATE_NOTIFIER=1` and `unset GH_REPO GH_FORCE_TTY CLICOLOR_FORCE` remain in `pr_spawn_refresh` |
| `static:pr-fd-redirect` | `>/dev/null 2>&1 </dev/null` remains in `pr_spawn_refresh` |
| `static:pr-early:*` | `maybe_pr_refresh` calls the early-fetch check (`pr_refresh_wanted`) and the re-check and writes inside the lock (`pr_refresh_claim`) |
| `static:no-echo` | `echo` is not used on any non-comment line |

- `block:*` extracts the text from the start-marker comment line (matched at the beginning of the line) up to just before the end-marker line, and compares it.
  If the marker comment is rewritten, the block cannot be extracted and the check fails. Only `block:stdin-read` uses the first `read` line as its start marker, because the comments just before it differ between versions.
- `static:*` checks that a fixed string is contained in each of the two versions. A check that names a function searches only that function's range (from `<function>() {` to the next `}` at the start of a line).

### translation-parity.sh

The Japanese documents are authoritative and the English versions (`*.en.md`) are synchronized by hand, so this detects an English version left behind after only the Japanese one was updated.
It does not judge translation quality and performs only OS-independent structural comparisons.
The targets are `README.md`, `docs/SPEC.md`, `docs/DESIGN.md`, `docs/DEVELOPMENT.md`, `tests/README.md` and their English versions.

| Check name | What it verifies |
| --- | --- |
| `lang-link:<name>` | The first line links to the other language version |
| `headings:<name>` | The number of headings is the same |
| `tables:<name>` | The number of table rows is the same |
| `spans:<name>` | Every code span (config variable name or command) of the Japanese version is also in the English version. Spans only in the English version arise from translation and are not compared |
| `lists:<name>` | The number and indent (nesting depth) of list items are the same. Losing the indent when wrapping a line breaks the nesting |

- Code blocks are not counted. Code spans that contain Japanese characters or placeholders (such as `<name>`) are not compared, because they change in translation.

## Directory Layout

A case name has the form `NN-description` (for example `30-branch-on`), and the fixture and the assertion correspond through the same case name.
The other directories are "markers" that take effect only for a case that has a file of the same name as the case name.

| Path | Contents |
| --- | --- |
| `fixtures/<case>.json` | The input JSON passed to the statusline |
| `assertions/<case>.txt` | The expected values for the case |
| `seeds/<case>.txt` | Values to seed as the rate history (one value per line, oldest first) |
| `disable-history/<case>` | Empty file. Disables the history directory |
| `show-model-off/<case>` | Empty file. Passes `CLAUDE_STATUSLINE_SHOW_MODEL_NAME=0` |
| `show-cwd-off/<case>` | Empty file. Passes `CLAUDE_STATUSLINE_SHOW_CWD=0` |
| `git-fetch-on/<case>` | Empty file. Passes `CLAUDE_STATUSLINE_GIT_FETCH=1` |
| `config-file/<case>` | Contents to be read as the config file |
| `layout/<case>` | Line 1 = `LAYOUT_LINE1`, line 2 = `LAYOUT_LINE2` |
| `highlight/<case>` | Line 1 = `CLAUDE_STATUSLINE_HIGHLIGHT` |
| `pr-cache/<case>` | The single line to seed as the PR status display cache (`lib/pr-cache.sh`) |
| `hyperlink-off/<case>` | Empty file. Passes `FORCE_HYPERLINK=0` |
| `pr-status-on/<case>` | Empty file. Passes `CLAUDE_STATUSLINE_PR_STATUS=1` |
| `pr-responses/*.json` | GraphQL responses that the fake gh returns in `pr-status-behavior.sh` |
| `lib/` | Helpers shared between harnesses, and the fake git / fake gh |

Notes for each marker follow.

- `seeds/`: A freshly copied history file has a new mtime, so the main script judges it to be within the sampling interval and does not append.
  This lets you verify that the seeded values are used as-is for the left side of the chart, with only the right end being the current value.
- `disable-history/`: Passes a symlink to the history directory as `CLAUDE_STATUSLINE_HISTORY_DIR`, so the main script's symlink check disables the history feature.
  It is used to verify that the current value still appears at the right end of the chart even when history is disabled.
- `git-fetch-on/`: The fetch is received by the fake git, so it never reaches the real network. This verifies that the rendered output does not change when fetch is enabled.
- `config-file/`: Besides regular files, you can also place a directory (reproduces an unreadable conf; `83-config-unreadable`) or a symlink to the distributed template `statusline.conf` (`86-config-template` / `95-config-template-layout`).
  - `86-config-template` / `95-config-template-layout` load the distributed template `statusline.conf` and verify that its values have not drifted from the defaults, by checking that the output matches the output with default values.
    - The template sets only `HIGHLIGHT` to the recommended `branch|pr_number`. Neither fixture displays a PR, so `pr_number` does not show up in the output.
    `86` uses a fixture with no branch / session, so the match of the line 1 order is verified by `95`.
  - Layout values contain `|`, so the template wraps them in quotes.
- `layout/`: An empty line means "not specified".
- `highlight/`: For a case with no marker, an empty value is passed (conf, then the default; the default is `branch`).
  Cases that verify the conf's `HIGHLIGHT` (such as `166-highlight-config`) use `config-file/`, and the fact that env beats conf is verified by placing both markers.
  Line 1 is passed as is, including leading and trailing spaces and tabs (`165-highlight-tokens`).
- `pr-cache/`: Line 1 is written as a single line of the cache. It is expanded with `printf %b`, so a tab can be written as `\t` and ESC as `\033`.
  `fetched_at` depends on the current time, so `@NOW@` (the current time) and `@STALE@` (the current time minus 4000 seconds) are replaced just before seeding. If line 1 is empty, no cache is placed.
  In every case a new marker is placed, so rendering does not start a retrieval and the seeded cache is read as is
- `hyperlink-off/`: For a case with no marker, `FORCE_HYPERLINK` is passed empty so that the value in the developer's shell does not leak in
- `pr-status-on/`: For a case with no marker, `CLAUDE_STATUSLINE_PR_STATUS` is passed empty. The PR is received by the fake gh, and this is used for cases that show the cache seeded via `pr-cache/` in the branch column

The contents of `lib/` are as follows.

| File | Role |
| --- | --- |
| `lib/escape-ansi.sh` | Replaces ESC with `\e` and BEL with `\a` (uses `perl`) |
| `lib/config-file.sh` | Resolves the conf path with `config_for_case`. If there is no marker, it returns a nonexistent path (`NO_CONFIG`) |
| `lib/layout.sh` | Resolves the layout string with `layout_for_case` |
| `lib/highlight.sh` | Resolves the highlight setting with `highlight_for_case` |
| `lib/find-debian-bash.sh` | Finds a bash that can run the Linux version. Also has the check that makes it mandatory on CI |
| `lib/is-macos-host.sh` | Determines whether the host is macOS |
| `lib/git-shim/git` | The fake git for tests |
| `lib/gh-shim/gh` | The fake gh for tests |
| `lib/pr-cache.sh` | Seeds the PR status display cache and marker with `seed_pr_cache_for_case` |
| `lib/age-file.sh` | Sets a file's mtime to N seconds ago with `age_file` (supports `touch -t` and both BSD and GNU `date`) |

## How to Write Assertion Files

Write one assertion per line, in the form `type: expected value`. Blank lines and lines starting with `#` are ignored.

- The separator is `:` (a colon and a single space). A line without a separator fails as a typo.
- An ESC in an expected value is written as the readable string `\e`. In fixed strings such as `contains` it is written as `\e` as is, and in regular expressions (`matches*`) as `\\e`.
- A case passes when all assertions in the file pass.

### Assertion Types

| Type | Target | Check |
| --- | --- | --- |
| `equals` | Entire output | Exact match |
| `contains` | Entire output | Contains the fixed string |
| `not_contains` | Entire output | Does not contain the fixed string |
| `matches` | Entire output | Matches the ERE |
| `matches_line1` | Line 1 | Matches the ERE |
| `matches_line2` | Line 2 | Matches the ERE. Fails if there is no line 2 |
| `not_contains_line1` | Line 1 | Does not contain the fixed string |
| `not_contains_line2` | Line 2 | Does not contain the fixed string. Succeeds if there is no line 2 |
| `no_line2` | Entire output | The output is only 1 line (by convention the expected value is `true`) |
| `fetch_marker` | History directory | Presence of the throttling marker (`present` / `absent`) |
| `exit_code` | Exit code | Match |

Any type name other than the above is treated as a failure.

### Why Line-Specific Types Exist

The output has a 2-line structure, so there are types that verify each line separately.

- `matches` evaluates the entire output as a single string. `.` also matches a newline, and `^…$` does not work per line, so use `matches_line1` / `matches_line2` when you want to pin down the shape of a line exactly.
- Not writing `matches_line2` does not verify that "there is no line 2".
  For a case where line 1 (directory / branch / commit / session_name) is omitted and only one line remains, add `no_line2` and verify the only remaining line (the model line) with `matches_line1`.
- `no_line2` is judged on the output with its trailing newlines preserved (`output_raw`). Command substitution strips all trailing newlines, so as is it could not detect a regression that prints only a blank line after line 1.
  The harness captures the output with a sentinel character appended, which keeps the trailing newlines.
- `not_contains_line1` / `not_contains_line2` verify that something does not appear on a specific line.
  For example, `not_contains_line2` lets you verify that something does not appear on the model line without falsely matching characters that may be in the directory column on line 1 (hyphens or color sequences).

### Regex Notes

The glibc regex does not interpret range specifications over UTF-8 multibyte characters (for example `[▁-█]`), so list the spark characters explicitly, as in `[▁▂▃▄▅▆▇█]`.

### Example

```text
# git repository with branch=main. session_name is empty, so the session column on line 1 is omitted
matches_line2: ^✻ Sonnet 4\.6 [▁▂▃▄▅▆▇█] \| [▁▂▃▄▅▆▇█]{12} 22:13 \| · --$
matches_line1: ^sl-repo#branch=main;ab=0… \| main \| a1b2c3d$
contains: | main
```

## fake git (`lib/git-shim/git`)

To verify the paths for branch, commit hash, changed line counts, and ahead/behind without creating a real git repository, the harness puts `lib/git-shim/` at the front of `PATH` to hide the real git.
The fake git implements only the subcommands the statusline uses (`branch --show-current` / `rev-parse --short HEAD` / `diff HEAD --numstat` / `status -z` / `diff --no-index --numstat` / `rev-list --left-right --count` / `fetch`).
It also implements `rev-parse HEAD` / `rev-parse --abbrev-ref '@{push}'` / `remote get-url`, which the PR status display's child process uses.

The repository state is written after the `#` in the fixture's `workspace.current_dir`. Multiple settings are separated by `;`.

```text
/tmp/sl-repo#branch=main;diff=12,3;untracked=new.txt:5;ab=2,3
```

| Convention | Meaning |
| --- | --- |
| `branch=<name>` | `branch --show-current` returns `<name>` |
| `detached` | Detached HEAD. `rev-parse` returns a short sha, and `rev-list` always fails |
| `unborn` | No commits yet (use together with `branch=<name>`). `rev-parse --short HEAD` / `rev-parse HEAD` / `diff HEAD --numstat` / `rev-list` fail (they fail even if `ab` is given). `status -z` works |
| `short=<hex>` | The value `rev-parse --short HEAD` returns (default `a1b2c3d`). Reproduces the long hash seen when `core.abbrev` is raised |
| `diff=<add>,<del>` | Changed line counts of tracked files |
| `diff=bin` | One binary change |
| `diff=<add>,<del>+bin` | Both a numeric change and a binary change |
| `untracked=<file>:<n>,...` | Untracked files and their line counts (`bin` for `<n>` means binary) |
| `ab=<ahead>,<behind>` | Difference from the upstream. `ab=0,0` means in sync |
| `head=<sha>` | The local HEAD that `rev-parse HEAD` returns (default `0123456789abcdef0123456789abcdef01234567`) |
| `push=<remote>~<branch>` | The value `rev-parse --abbrev-ref '@{push}'` returns. `~` is returned as `/` (for example `push=origin~feature~fix`) |
| `owner=<login>` | The owner in the URL that `remote get-url` returns |
| `urlform=https\|scp\|ssh` | The form of that URL (default `https`) |

- Without `ab`, the repository is treated as having no upstream configured (`rev-list` fails).
- Without `push`, the branch is treated as not yet pushed (`@{push}` fails). `pr-status-behavior.sh` makes the cwd a real directory, so `/` cannot be written in the path and `~` is used instead.
  For the same reason, `owner` is built from the convention rather than being the URL itself.
- The environment variable `STATUSLINE_TEST_BRANCH=<name>` overrides the `branch` convention. It is used for verification that switches only the branch without changing the cwd (`branch-switch`).
- A path with no `#` is treated as being outside git.
- `fetch` exits without doing anything. `git-fetch-behavior.sh` observes the fetch behavior with the following environment variables.
  - `STATUSLINE_TEST_FETCH_SLEEP=<seconds>`: Delays the fetch by the given number of seconds
  - `STATUSLINE_TEST_FETCH_SENTINEL=<path>`: Appends one line to the file for each fetch

The directory column is built from the basename of `current_dir`, so the convention string is also displayed as part of it (`sl-repo#branch=main;ab=0…` in the example above).

## fake gh (`lib/gh-shim/gh`)

This is a fake that accepts only `gh api graphql ... --jq <expression>`, which the PR status display's child process calls.
`regression.sh` / `pr-status-behavior.sh` / `e2e-preview.sh` put `lib/gh-shim/` on `PATH` so that the real gh (and the network) is never reached.

- By default it does nothing and fails (exit code 1). `regression.sh` and `e2e-preview.sh` seed a cache and a new marker, so normally the retrieval itself is not started
- It fails when `head` is passed with `-F`. The real `gh`'s `-F` converts the value's type (`123` or `true` becomes a number or a boolean) and reads a value starting with `@` as a file
- `pr-status-behavior.sh` controls the behavior with the following environment variables
  - `STATUSLINE_TEST_GH_SENTINEL=<path>`: Appends one line per call containing the `head` variable and the values of the environment variables the child process sets and removes (for gh and for git)
  - `STATUSLINE_TEST_GH_SLEEP=<seconds>`: Delays the response by the given number of seconds
  - `STATUSLINE_TEST_GH_EXIT=<code>`: Exits with the given exit code instead of responding
  - `STATUSLINE_TEST_GH_RESPONSE=<path>`: The GraphQL response JSON. Evaluates the `--jq` expression with a real `jq -r` and outputs the result

## Isolating the Execution Environment

So that case results do not depend on the developer's environment, the harness starts the statusline with the following preamble for every case.

- History directory: `regression.sh` / `git-fetch-behavior.sh` / `pr-status-behavior.sh` / `e2e-preview.sh` all pass a temporary directory made per case with `mktemp -d` as `CLAUDE_STATUSLINE_HISTORY_DIR` and delete it on exit.
  The production `/tmp/claude-statusline-<uid>/` is never touched. The directory is created with the real uid, so it passes the main script's owner check, and the history write on first startup actually runs.
- Config file: `CLAUDE_STATUSLINE_CONFIG` is fixed to a nonexistent path, except for cases that have a marker in `config-file/`. The developer's `~/.claude/statusline.conf` is never read.
  All harnesses follow this rule through `lib/config-file.sh`.
- `CLAUDE_STATUSLINE_*` environment variables: When there is no marker, they are passed as empty strings. The main script treats empty the same as unset, so it falls back in the order conf, then default.
  Passing the default directly would make the environment variable always beat the conf value, and the conf could not be verified.
  `CLAUDE_STATUSLINE_COLOR_SCHEME` is also passed empty so that the value in the developer's shell does not leak in.
  - `CLAUDE_STATUSLINE_HIGHLIGHT` is always passed by `regression.sh` / `pr-status-behavior.sh` / `e2e-preview.sh`.
    If it is not passed, cases that include the branch and so on would fail only on the machine of a developer who exports a highlight setting.
- Short-name variables: `regression.sh` passes 11 short-name variables such as `SHOW_MODEL_NAME` and `LAYOUT_LINE1` with values different from the defaults in every case (`HIGHLIGHT` is set to a value that specifies all tokens).
  The main script `unset`s these before reading the conf, so they do not affect the output. If that `unset` disappears, every case fails, so this also serves as a regression guard for it.
- git / gh: The fake git and fake gh described above are placed at the front of `PATH`.
- `FORCE_HYPERLINK`: `regression.sh` and `e2e-preview.sh` pass it empty, except for cases that have a marker in `hyperlink-off/`.

## Execution Environment and Skips

| Version | Run condition | When the condition is not met |
| --- | --- | --- |
| macOS version | macOS host (`uname -s` is `Darwin`) | Skipped (because it assumes BSD commands) |
| Linux version | bash 4.1 or later and `flock` | Skipped |

- `jq` is required for both versions. `regression.sh` also uses `perl`.
- For the Linux version, bash is searched for in the order `bash` (on `PATH`), `/opt/homebrew/bin/bash`, `/usr/local/bin/bash`. macOS's `/bin/bash` is version 3.2 and is not eligible.
- If you install bash 4.1+ and `flock` on macOS, the Linux version's cases also become eligible to run, but the Linux version uses GNU coreutils' `stat -c` / `date -d`, so it fails on macOS. The Linux version is verified on CI (ubuntu).
- The occurrence of skips is shown at the end of the results (`regression.sh` also shows the number of skipped cases).
- CI runs only the Linux version on ubuntu and sets `STATUSLINE_TEST_REQUIRE_DEBIAN=1`. When this variable is `1`, an environment that cannot run the Linux version exits with an error instead of skipping.
  This prevents everything being skipped and still counting as success. The macOS version is not run on CI, so changes that involve the macOS version are verified by running `npm test` locally.

## Adding a Case

1. Put the input in `fixtures/<NN-name>.json` and the expected values in `assertions/<NN-name>.txt`. Existing cases are numbered sequentially.
2. To change environment variables or settings, put a file of the same name in the relevant marker directory.
3. Confirm that both versions pass with `npm test`, and visually check the actual colors with `npm run preview`.

Do not rewrite existing assertions in a refactoring that does not change the output. For a change that alters the output, update [docs/SPEC.en.md](../docs/SPEC.en.md) and the assertions together.
