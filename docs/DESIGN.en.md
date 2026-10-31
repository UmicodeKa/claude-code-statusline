English | [🗾 日本語はこちら](./DESIGN.md)

# Design Notes

> This is an English translation. If it differs from [DESIGN.md](DESIGN.md) (Japanese), the Japanese version is authoritative.

This document covers how the statusline scripts work internally, where they are fragile, and which alternatives were rejected. What gets displayed (what appears, in what order, in what color) is defined in [SPEC.en.md](SPEC.en.md). This
document covers why the implementation looks the way it does and what happens if you change it. For writing tests, see [tests/README.en.md](../tests/README.en.md). For how to work on the project, see [DEVELOPMENT.en.md](DEVELOPMENT.en.md).

## Table of Contents

- [Overall Structure](#overall-structure)
- [Differences Between the macOS and Linux Versions](#differences-between-the-macos-and-linux-versions)
- [Implementation Mechanisms](#implementation-mechanisms)
- [Fragile Spots and the Tests That Guard Them](#fragile-spots-and-the-tests-that-guard-them)
- [Rejected Alternatives and Background](#rejected-alternatives-and-background)
- [Spots the Tests Do Not Cover](#spots-the-tests-do-not-cover)

## Overall Structure

The macOS version (`statusline-macos.sh`) and the Linux version (`statusline-linux.sh`) proceed in the same order.

1. Pin the locale with `export LC_ALL=C.UTF-8`
2. Load the config file (`~/.claude/statusline.conf`)
3. Resolve the customization settings in the order env > conf > default
4. Define the internal constants (`SPARKS` / `UNTRACKED_DIFF_LIMIT` and so on) and clamp the numeric settings (`RATE_CHART_LEN` and the throttle intervals)
5. Define the color scheme (`COLOR_*`)
6. Check the required commands and set up the history directory safely
7. Read the input JSON with a single `jq` call and collect the `HIGHLIGHT` tokens into `hl_set` for matching
8. Update the rate history, build the chart, and compute the single-character weekly spark
9. Get the git branch and ahead/behind (when `GIT_FETCH=1`, the background fetch is launched here)
10. Color each field, assemble line 1 and line 2 according to the layout, and print them (only when building the branch column with `PR_STATUS=1`, read the PR cache and, if needed, launch a background fetch. The commit hash and changed-line
    counts are fetched only when building the commit column)

The Linux version places a bash 4.1+ gate before step 1. In step 6 it prepares the history directory first and then checks `jq` / `flock` (the macOS version checks `jq` first). Also, `LOCK_TIMEOUT_SEC` lives in the internal-constants block
in the Linux version, and right before the lock acquisition function (`acquire_lock`) in the macOS version.

Rendering runs every time the statusline refreshes, so three points take priority throughout: do not add forks (external command launches), keep network I/O out of the render path, and keep displaying even when something goes wrong.

## Differences Between the macOS and Linux Versions

The two versions differ only in platform-dependent parts.

| Item | macOS version | Linux version |
| --- | --- | --- |
| Expected bash | `/bin/bash` 3.2 or later | bash 4.1 or later (version checked at the top) |
| Mutual exclusion | Atomic `mkdir` + stale-lock removal | `flock(1)` + named fd (`exec {fd}>...`) |
| Lock object | `<target>.lockd` directory | `<target>.lock` file |
| `date` / `stat` | Switches between BSD and GNU variants via `uname -s` | GNU variants (`date -d "@.."`, `stat -c`) |
| Dependency check | `jq` | `jq` and `flock` |

The macOS version avoids `flock` because it is not installed on macOS by default and fails silently where it is missing. Instead it takes the lock with `mkdir`, whose atomicity POSIX guarantees, and treats a lock directory older than
`LOCK_TIMEOUT_SEC` × 5 seconds (10 seconds by default) as stale and deletes it. The Linux `flock` is released automatically when the process exits, so it has no stale handling.

All other blocks (config loading, customization settings, clamping, color scheme, the constants and shared parts of the PR status display, spark and remaining-value computation, history reading, coloring and formatting, layout assembly, and
the render part of main) are kept character-for-character identical in both versions. In the history code, the only difference is `history_push`, which takes the lock. In the PR status display, the only difference is `maybe_pr_refresh`,
which takes the lock. `tests/script-parity.sh` extracts these blocks and compares them.

## Implementation Mechanisms

### Three-Layer Coloring

All coloring (model / effort / ctx / rate / weekly / diff / ahead-behind) goes through `paint <text> <effect> [arg]`.

- `paint` is only a dispatcher that routes to `static` or `rainbow` based on the effect name
- `static <text> <color>` wraps the text in a single color and appends `\033[0m`. When color is empty, it passes the string through with a trailing newline
- The color-deciding functions (`model_color` / `effort_color` / `ctx_color` / `limit_color`) store an effect string (`"static <ansi>"` / `"static"` / `"rainbow"`) into the variable named by the first argument with `printf -v`, and the
  caller expands it unquoted and passes it to `paint`
  - It is not captured with `$(...)`, so there is no fork
  - No color is just `"static"`, so whether a color applies is decided by comparing against `"static"`

To add a new effect, adding one branch to `paint` is enough. Going back to calling `static` directly from individual paths would scatter the places where effects are added.

The exception is the `HIGHLIGHT` painting (`highlight`). The color is fixed to `COLOR_text`, so there is no effect to choose, and every element passes through even when nothing is specified, so it avoids `paint` and does not fork
([Highlighting (`HIGHLIGHT`)](#highlighting-highlight)).

An uncolored `static` appends a trailing newline, so its result is captured with `$(...)` to drop the newline before concatenation (uncolored `*` takes this path). A colored `static` appends no trailing newline, so concatenating it directly
does not break the output.

### rainbow

When effort is `max`, `effort_color` returns `rainbow`, and the word is painted one character at a time in different colors.

- Colors come from `RAINBOW_PALETTE` (seven truecolor `R;G;B` entries), assigned to the i-th character as `palette[i % 7]`. There is no interpolation
- The trailing `\033[0m` is appended only once, at the end
- A single character is extracted with `${text:i:1}`, and no characters are passed to external commands. This avoids breaking multibyte characters, and it assumes that `LC_ALL=C.UTF-8` makes lengths count in characters

### Joining effort and Its Separator

effort is painted by a `paint` call separate from model, and its color sequence is not mixed with that of `✻ <model>`.

- When `SHOW_MODEL_NAME=1`: an uncolored `∙` goes between `model_field` and effort, with no spaces on either side. `∙` does not pass through `paint`, so it does not enter the `max` rainbow cycle
- When `SHOW_MODEL_NAME=0`: no `∙` is used, and the two are joined with a single space
- When effort is empty (an unsupported model), the whole branch is skipped by `[ -n "$effort" ]`, and neither the separator nor effort is printed. The output is the same as before effort was introduced

### Always Showing the `✻` Symbol

Even with `SHOW_MODEL_NAME=0`, only the model name is removed, and `✻` stays in the `model_color` color. This lets you tell models apart by the symbol's color. The color is decided from the whole model name before trimming, so it does not
change after the name is cut to 13 characters.

### Color Scheme Constants Block

`COLOR_*` is a palette matched to Claude Code's light/dark themes, and a `case` on `COLOR_SCHEME` switches between the two sets.

- `_fg` is a helper that expands `R;G;B` into `\033[38;2;R;G;Bm`, and is used only at definition time. Each `COLOR_*` is a string containing a real ESC, so the user side passes it to `static` without wrapping it in `printf`
- Semantic names (`success` / `error` and so on) name a purpose, and keys that are currently unused are kept
- `COLOR_subagent_*` corresponds to the colors used for Claude Code's subagent display

Going back to writing color values directly in each function would make the light/dark switch and the cross-version consistency check harder.

### Three Severity Tiers and Blinking for rate, weekly, and ctx

The theme palette has only two warning colors, `warning` (yellow) and `error` (red). rate / weekly and ctx insert `claude` (orange) between them to make three tiers: caution, danger, critical. The critical tier layers the blink attribute
`\033[5m` on top of `error`. Blink is an attribute, not a color, so it distinguishes the critical tier from the danger tier without adding colors. If you drop the blink and use plain `error`, the only difference between the critical and
danger tiers is the color, and it is easy to confuse with the adjacent tier.

### Building Line 1

Line 1 is built in a separate array, `line1_parts`, distinct from the line 2 `parts`.

- Only when it has at least one element, the `join_by` result is printed with a newline appended
- The newline goes at the end of line 1. If it were put at the start of line 2 (`printf '\n%s'`), a blank line would appear at the top whenever line 1 is omitted
- When directory, branch, commit, and session are all empty, no newline is printed either. Even a blank line occupies one line of statusline height

### Layout Token Design

`LAYOUT_LINE1` / `LAYOUT_LINE2` are scanned by `build_layout`, and each token's value is looked up with `layout_token`.

- The separator between tokens is always ` | `. Elements that use a different separator inside themselves are bundled into one token
  - `model_ctx` is `✻ <model>∙<effort> <ctx>` (containing `∙` and a single space)
  - `branch` is the name trimmed by `truncate_branch 25` (only the last segment is passed through `highlight`), followed by `${ab_str:+ $ab_str}${pr_str:+ $pr_str}` (the `:+` makes the concatenation conditional so no stray space is left when
    ab / PR are empty)
    - `pr_str` is set by `pr_token`, which is called just before in the same case clause. If the concatenation is moved before `pr_token`, the PR no longer appears
  - `commit` is the hash passed through `highlight commit`, followed by `${hl_out:+ }` and `diff_str` (so no leading space is left when the hash is empty on an unborn branch. diff returns `·` even for a clean working tree, so it always
    appears when there is a branch)
    - The hash and `diff_str` are obtained inside this case clause. As with `pr_token`, git is called only when the column is built, so if `LAYOUT_LINE1` has no `commit`, neither `rev-parse` nor the changed-line aggregation runs
    - The display condition is the same `[ -n "$branch" ]` as branch. There is no separate check for being inside a git repository
- `model` and `ctx` are not split into separate tokens, because the separator between tokens would vary by combination, complicating both the implementation and the tests
- The third argument of `build_layout` switches whether empty values are pushed. Line 1 uses `0` (an empty value omits the whole column), line 2 uses `1` (empty values are still pushed)
- For line 2, the default full token set (`LAYOUT_LINE2_TOKENS`, `model_ctx|rate|weekly`) is appended to the end of the scan input, and tokens that were not written are filled in in the default order. This means `model_ctx`, which contains
  `✻`, cannot be removed, and `weekly` is still appended at the end even for a conf that does not mention `weekly`
- The per-line token lists (`LAYOUT_LINE1_TOKENS` / `LAYOUT_LINE2_TOKENS`) are shared by the defaults, the completion, and the valid-token check. When adding a token, fix both this list and the `case` in `layout_token` (adding it to the
  list only produces an empty column on line 2)
- Unknown tokens are silently ignored, and duplicates are taken only the first time. Splitting on `|` and trimming surrounding whitespace (including tabs) is done by `split_tokens` using only parameter expansion, with no `tr` or `awk`.
  `split_tokens` is shared with the `HIGHLIGHT` parsing, because writing the same rule loop in two places would let the interpretation of the same string drift apart when only one is fixed
- The mapping from token to value uses a `case` rather than an associative array, and the value is returned through the global variable `token_value`. The macOS `/bin/bash` 3.2 has no associative arrays, and capturing with `$(...)` would
  add forks
  - As exceptions, trimming branch / session involves command substitution through `truncate_branch` / `truncate_label`. commit also involves command substitution for `rev-parse` and `git_diff_stat`
  - With `PR_STATUS=1`, `pr_token`, called from branch, also forks to read the cache ([Fetching and Caching PR Status](#fetching-and-caching-pr-status))
- `SHOW_CWD=0` is implemented by having the `directory` token return empty. This avoids having a double check in both the flag and the layout

### Highlighting (`HIGHLIGHT`)

The processing that paints uncolored elements with `COLOR_text` is collected in a single helper, `highlight <token> <string>`.

- In main, right after the jq read, `hl_set` is built exactly once by joining the result of `split_tokens "$HIGHLIGHT"` into the form `|a|b|` (the same shape as `seen` / `allowed` in `build_layout`). `highlight` matches against it with
  `case` using `*"|<token>|"*`
- The result is returned in the global variable `hl_out` rather than captured with `$(...)`, so there is no fork. For a token that is not specified, the original string is returned as-is, so places that emit an uncolored element always go
  through `highlight` without branching. The number of forks does not change whether or not highlighting is on
- `hl_out` is a single global variable, so successive calls overwrite it. In the uncolored branch of `format_limit`, the chart result is moved into `chart_out` before the time is passed through
- Empty strings are not painted. Painting would turn an empty column into a non-empty value consisting of only ESC, breaking the rule on line 1 that "columns with empty values are omitted". It also returns exit status 0 for empty input, so
  that a caller chaining with `&&` / `||` does not mistake it for a failure
- Trim first, then paint. This keeps ANSI escapes out of the character count for `truncate_label` / `truncate_branch`
- The line 1 elements (directory / branch / commit / session) are painted in `layout_token`. `layout_token` is called only from `build_layout` at the end of main, so painting is guaranteed to happen after `hl_set` is built. directory is
  also not painted where `dir_field` is built, which keeps the line 1 painting in one place
- branch is split at the last `/` of the displayed name, and only the part after it is painted. For a name without `/`, `${label%/*}` would return the whole name and produce an overlap like `main/main`, so a `case` does the split. The
  painted range is decided from the displayed name, so this rule does not change when the trimming rules change
- commit passes only the hash through `highlight`, not `<diff>`, because `git_diff_stat` paints `<diff>` in its own colors
- ctx / rate / weekly call it only in the uncolored branch (and the missing-value branch) of `format_ctx` / `format_limit`. `format_limit` builds the `<column name>_chart` / `<column name>_reset` tokens from the column name passed as the
  fifth argument (`rate` / `weekly`), so rate and weekly share the same code
- model passes through `highlight` only when `model_effect` is uncolored (`static`), and is painted with `paint` when colored. An uncolored model does not go through the `$(...)` in `paint`, so that fork is avoided
- The PR comment count is passed through as `pr_comments` in `format_pr`. The PR number is an exception: it does not go through `highlight` and is checked with `hl_has pr_number` instead.
  The underline must come before the color, and going through `highlight` would double the `\e[0m` ([PR Number Colors](#pr-number-colors))
- `hl_has <token>` is a predicate that only matches against `hl_set`, and `highlight` uses it too. This keeps the matching logic in one place, so that `format_pr` does not depend on the shape of `highlight`'s output

### rate Chart Base and the Rightmost Current Value

The rate chart is `RATE_CHART_LEN` characters long (default 12): the left `RATE_CHART_LEN − 1` characters are history, and the rightmost character is the current value.

- `rate_chart` is first initialized with `history_chart /dev/null` (history-less padding: `RATE_CHART_LEN` copies of `·`), and overwritten with the actual history only when `HISTORY_DIR` is valid
- Then, if the remaining amount (`rate_remaining`) exists, the rightmost character is replaced with the current value from `spark_of`. Thanks to the base, `rate_chart` is never empty, so the only branch condition is whether `rate_remaining`
  exists
- History appends are throttled by `POLL_INTERVAL_SEC` (default 300 seconds), so without the replacement the rightmost character would keep an old value even right after a reset
- The slice `${rate_chart:0:$((RATE_CHART_LEN - 1))}` assumes that `LC_ALL=C.UTF-8` makes lengths count in characters (a spark character is 3 bytes)

### Computing Sparks and Remaining Values Without Forking

The spark character (`spark_of`), the usage rounding (`round_int`), the remaining-value computation (`set_remaining`), and the color decisions (`*_color`) write their results into the caller's variable with `printf -v`. Capturing with
`$(...)` would add one fork per call, and the rate chart calls these once per character.

- `spark_of` converts an integer value to a level with the bash arithmetic expression `(8p + 50) / 100` and does not start `awk`. `awk` is used only for decimals (ctx usage) and values of 9 or more digits. rate history and remaining values
  are always integers, so regardless of chart length the only `awk` for sparks is the one for ctx
- For an integer p, `awk`'s `int(p / 100 × 8 + 0.5)` and the arithmetic expression `(8p + 50) / 100` agree. Both truncate toward 0, so they agree for negative values as well, and `8p + 50` is never a multiple of 100 (it leaves remainder 2
  when divided by 4), so there are no boundaries where floating-point error could change the level
- A leading 0 is converted to decimal with `10#`, because the arithmetic expression would try to read `08` as octal and fail
- Local variables in functions that receive the name of the destination variable get a per-function prefix (`_so_` / `_sr_` / `_ci_`). bash variables have dynamic scope, so if a local variable has the same name as the caller's, `printf -v`
  writes to the local instead of the caller's
- `eval` is not used. With `printf -v`, symbols in the value are never executed as code

### History Files and Locking

- Only rate keeps history. rate is an account-level value over a 5-hour window shared by all sessions, so it is aggregated into the single file `${HISTORY_DIR}/rate`. ctx and weekly draw only one character for the current value, so they
  keep no history
- The number of stored entries is fixed at `RATE_CHART_LEN_MAX` (20), the upper limit, rather than the display length (`RATE_CHART_LEN`)
  - When the chart length is increased, the stored history shows up immediately. Truncating to the display length would leave a row of `·` right after the increase
  - The history file is shared by all sessions, so even if some session reads a different conf via `CLAUDE_STATUSLINE_CONFIG`, a session with a short chart does not truncate the history of a session with a long chart
  - A history file with fewer entries than the stored count can be read as-is, so no migration is needed
- On the first append to an empty history file, the current value is written `RATE_CHART_LEN_MAX` times. This avoids showing a row of `·` on first display
- After appending, `tail -n RATE_CHART_LEN_MAX` is written to a temp file and swapped in with `mv`. The reader reads only the tail with `tail -n RATE_CHART_LEN`, so even if truncation fails and the file grows, the display width does not
  break
- Multiple statuslines may write at the same time, so appends happen inside a lock. The lock wait is at most `LOCK_TIMEOUT_SEC` (2 seconds); if the lock cannot be taken, that append is skipped. The statusline is called frequently, so the
  next call picks it up

### weekly (Weekly Limit)

- The remaining 7-day rate limit is drawn as a single-character spark, like ctx. It keeps no history, because recording a 7-day window at the 5-hour throttle interval would not show a trend
- Formatting uses the same `format_limit` as rate, passing a single `spark_of` character instead of the chart and `%a` (weekday) instead of the time format. This avoids writing the color thresholds (`limit_color`), the condition for showing
  the number, and the ` - ` separator in two places
- `%a` is evaluated under `LC_ALL=C.UTF-8`, so it is always the English abbreviation `Sun` to `Sat`, regardless of the user's locale
- Even when the usage value is missing, the column remains as `· --`. As with ctx (`· --`) and rate (`<chart> --`), this keeps "line 2 pushes even empty values"
- Rendering cost
  - Increases: for weekly, two command substitutions per render (`format_limit` and the `format_reset_time` inside it) and one `date` launch. When there is no `resets_at`, `format_reset_time` is not called
  - Decreases: returning `round_int` / `spark_of` / `*_color` through `printf -v` removes the following
    - 3 `$(printf ...)` calls
    - the command substitutions and `awk` for the rate chart (`RATE_CHART_LEN` characters) and the rightmost current value
    - 1 command substitution wrapping the ctx spark
    - 4 command substitutions for color decisions (`model_color` / `effort_color` / `ctx_color` / rate's `limit_color`)
  - Regardless of chart length, the decrease outweighs the increase

### Reading the Input JSON

`jq` takes tens of milliseconds per launch, so the 9 required fields are emitted one per line in a single call and received with 9 `read` calls.

- String fields have newlines, tabs, and CRs replaced with spaces inside `jq`, because a newline in a value would throw off the line correspondence
- Combining them into one line with `@tsv` is not used. In bash 3.2, when IFS is non-whitespace, `read` collapses consecutive delimiters into one and loses empty fields
- New fields are added at the end. Inserting one in the middle would throw off the correspondence between existing variables and lines (this is why weekly's two fields come after `effort`)

### Counting Changed Lines

- Tracked files are totaled for staged and unstaged changes together with a single `git diff HEAD --numstat`
- Untracked files are enumerated NUL-separated with `git status -z`. Paths are not quoted, so paths containing spaces or newlines are handled
- `git diff --no-index --numstat -- /dev/null <path>` is called per untracked file, so forks grow in proportion to the count. Beyond `UNTRACKED_DIFF_LIMIT` (50) files, line counts are not taken and only the number of files is counted
- The aggregation runs only when building the commit column (`commit` in `layout_token`). If `LAYOUT_LINE1` has no `commit`, none of the git calls above happen

### ahead/behind and the `*` Decision

- ahead/behind is obtained with a single `git rev-list --left-right --count '@{upstream}...HEAD'`. It compares against the local remote-tracking branch, so it never touches the network
- When rev-list fails, `*` is printed. Whether HEAD is detached is received as an argument (`is_detached`), already decided by main when it got the branch, and the function does not call git again
- On a detached HEAD, `branch` holds `HEAD` and `<ab>` is an uncolored `*` (`HEAD *`). `maybe_git_fetch` / `pr_token` / `git_ahead_behind`, which receive `branch`, tell detached apart through `branch_detached`, so the literal string `HEAD`
  is not used for the decision
- "No upstream configured" and "an in-repo anomaly where the branch is available but only rev-list fails" cannot be told apart by exit code. Adding git calls just to distinguish them is not done, and both are treated as a blue `*`
- ahead does not use `success` (green) because the change count `+N` in the adjacent column on the same line 1 is green, and the two would be hard to tell apart. The `*` for no upstream is also colored blue like ahead, as a kind of "local
  is ahead" state

### directory Column

- This column lets you tell which project you are working in when running multiple sessions in parallel
- The basename of `workspace.current_dir` is extracted with parameter expansion alone (`${path##*/}`), without adding calls to `basename` or git
- Trailing slashes are removed first. For a value like `/tmp/project/`, `${cwd##*/}` would be empty and the column would vanish even though the directory exists. For `/` alone, removal leaves an empty string, with the same result as "the
  root omits the column"

### Trimming Branch Names While Keeping the Tail

- In names like `feature/xxx/yyy`, the trailing `yyy` usually describes the work, so `truncate_branch` keeps the part after the last `/` and abbreviates the middle with `…`. Cutting from the start would remove the part you want to
  recognize, more so for longer names
- The tail limit of 22 characters is the maximum that fits in 25 characters together with the first character + `…` + `/` + the tail. A tail longer than this, or a name without `/`, does not fit with middle elision (or has no separator), so
  it is delegated to `truncate_label`, which gives the first 24 characters + `…`. This avoids writing the head-first rule in two places
- It is built with parameter expansion alone (`${text##*/}` / `${#tail}` / `${text:0:N}`) and uses no external commands. The caller's command substitution is the same single one as for `truncate_label`, so forks do not increase
- Tests that guard it
  - Middle elision: `117-branch-trim-keep-tail`, `118-branch-trim-tail-22` / `119-branch-trim-tail-23` on either side of the threshold, `121-branch-trim-keep-tail-ab-diff`
  - Boundaries of middle elision: `122-branch-trim-keep-tail-cjk` for CJK, `123-branch-trim-slash-25` for exactly 25 characters, `124-branch-trim-cut-after-slash` for cutting right after `/`
  - Still head-first: `120-branch-trim-no-slash`, and `31-branch-trim` / `41-diff-trim-keeps-stat` with a long tail
  - Drift between versions: `block:paint` / `block:format-layout` in `tests/script-parity.sh`

### Fetching and Caching PR Status

PR status is obtained with `gh api graphql`, but it takes close to a second per call, so it is not called in the render path. The structure is the same as `maybe_git_fetch`: rendering only reads the cache, and fetching is done by a
fire-and-forget child process.

| File | Written by | Contents |
| --- | --- | --- |
| `${HISTORY_DIR}/pr-<key>` | Child process | Cache (one tab-separated line). Replaced only when a fetch succeeds |
| `${HISTORY_DIR}/pr-<key>.marker` | Parent (render side) | Empty file. Its mtime is the time of the last fetch attempt |
| `${HISTORY_DIR}/pr-<key>.inflight` | Child process | Directory. Exists only while a fetch is running |

- The entry point is `pr_token`, called from `branch` in `layout_token`. As in `maybe_git_fetch`, the `PR_STATUS` check happens inside the function. It runs only when building the branch column, so there is no need to scan the layout
  separately to see whether `branch` is present, and splitting and whitespace handling cannot drift from `build_layout`
- `<key>` is the `cksum` of `cwd + newline + local branch name`. The key is built from the current branch on every render, so the previous PR does not linger after switching branches or running `/clear`
- The cache and the marker are separate files because the way the marker is written (`true > "$marker"`) empties the file. If they were combined, the cache would be erased on every attempt
- The refetch interval is decided from the state recorded in the cache (30 seconds while CI is running or around a push, 900 seconds for merged / closed, and so on). If the cache's `fetched_at` is older than the marker's mtime, the last
  attempt is considered to have failed
- The child fetches only when it can create `.inflight` with `mkdir`. The render side also does not launch a fetch while `.inflight` exists, so `gh` processes do not pile up even if the network is stuck
- `gh` is launched in the background inside the child, which checks it is alive with `kill -0` every 0.2 seconds and issues `kill` after 60 seconds (and KILL one second later if TERM does not finish it). This is because macOS has no
  `timeout(1)`
  - Elapsed time is measured by the wall-clock `SECONDS` in addition to the number of sleeps. The sleep count does not advance while the machine is asleep, so it can keep running longer than the 90 seconds (wall clock) of `.inflight`
  - Tests shorten it with `CLAUDE_STATUSLINE_TEST_PR_TIMEOUT_SEC`
- The result is written to a temp file and swapped in with `mv`, so rendering never reads a half-written file. Before the swap, it checks that the existing cache's `fetched_at` is not newer than its own start time, so an old result does not
  overwrite a new one. A `fetched_at` in the future (for example after the clock moved backward) did not come from a later-started fetch, so it is overwritten, and the render side does not display it either. Otherwise the stale display
  would stay and not update until the clock catches up
- Candidate selection and state determination are done inside `gh`'s `--jq` (the jq built into gh), and converted into the single cache line. `--jq` does not accept `--arg`, so the local HEAD and the head owner are passed through
  environment variables and read via `$ENV`. Embedding values into the expression as strings would break the expression on symbols in branch names and the like
- The `git` calls that get the local HEAD and the push target are made inside the child process. Putting them in the render path would add forks on every render
- The render side reads the cache with the built-in `read` and splits by tab with parameter expansion. Tab is IFS whitespace, so splitting with `IFS=$'\t' read` would collapse empty fields and shift the columns
- Rendering cost: with `PR_STATUS=1`, even the normal within-interval path adds `cksum` / `date` / `stat` forks on every render. With `PR_STATUS=0`, nothing is added

The head branch name and owner are decided from the push target (`@{push}`) because searching by the local branch name alone causes the following mistakes.

- When on `main` of a public repository, it picks up a PR that someone else opened from `main` of their own fork (the same happens with common names such as `patch-1`)
- When the local `fix` tracks `origin/feature/fix`, or when `gh pr checkout` created a branch named `<owner>-<branch>`, the PR is not found

`MERGED` / `CLOSED` is selected only when `headRefOid` matches the local HEAD. This avoids showing an old PR when a branch with the same name as a merged PR is reused with new commits.

`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is not checked. This keeps the PR status display usable for people who set that variable to hide Claude Code's built-in PR badge. Setting `PR_STATUS=1` is itself an explicit opt-in.

### PR Number Colors

pending (an open PR with no review yet) and draft are both "an open PR with no activity". The color difference between these two is kept small, so that only approved / changes requested / merged stand out by color.

- pending is uncolored, and is painted with `text` only when `HIGHLIGHT` has `pr_number`. `text` is the color that means "an element chosen with `HIGHLIGHT`", so using it as the fixed state color of pending would give one color two meanings.
  Making it a highlight target keeps `text` to a single meaning
- draft is painted with the theme-dependent gray `COLOR_prDraft` (`subtle` in dark, `inactive` in light).
  `subtle` and `inactive` each have the same value in both themes, so picking one color makes it hard to read in one of the themes
  (`inactive` is about 2.9:1 on a black background, `subtle` is about 2.2:1 on a white background). A small difference from pending is preferred over contrast against the background, so dark uses `subtle`, which is close to white
- Theme-dependent color decisions are gathered in the color definition block (`case "$COLOR_SCHEME"`), and `format_pr` does not look at `COLOR_SCHEME`. Drift between the two versions is detected by `tests/script-parity.sh`
- closed stays uncolored and is not painted even when `pr_number` is specified. Being uncolored distinguishes it from the gray of draft and the purple of merged
- `format_pr` does not pass the PR number through `highlight`; it checks `hl_has pr_number` and puts `COLOR_text` into `color`.
  The underline (`\e[4m`) must come before the color, and the `\e[0m` added by `highlight` would be doubled with the `\e[0m` at the end of the number. Putting it into `color` keeps the ESC sequence in the same form as the other states

## Fragile Spots and the Tests That Guard Them

Each item is written in the order "location / what it does / what happens if removed / tests that guard it". Test names are case names under `tests/assertions/`, case names in `tests/git-fetch-behavior.sh` and `tests/pr-status-behavior.sh`,
check names in `tests/script-parity.sh`, and static-check names in `tests/regression.sh`.

`tests/script-parity.sh` is part of `npm test` and is OS-independent, so it also runs in CI (ubuntu).

### Locale Pinning

- Location: `export LC_ALL=C.UTF-8` at the top of both versions
- What it does: displays UTF-8 symbols (`✻` `▁..█` `…` `↑` `↓` `∙`) and makes `${#var}` / `${var:0:N}` count in characters
- What happens if removed: when the runtime locale is C or similar, trimming and slicing count in bytes. The rate chart's rightmost replacement and rainbow's single-character slicing cut in the middle of multibyte characters, and the
  display breaks. The output of the two versions also diverges depending on the environment
- Tests that guard it: `static:locale` in `tests/script-parity.sh` (a static check that the line is present within the first 20 lines). Output-comparison cases depend on the runtime locale, so deleting the line may not fail them if the
  development environment is UTF-8

### The bash 4.1+ Gate in the Linux Version

- Location: the `BASH_VERSINFO` check at the top of the Linux version
- What it does: with bash older than 4.1, prints `✻ -- (bash 4.1+ required)` and exits
- What happens if removed: the Linux version uses named fds (`exec {fd}>...`), so older bash gives a parse error, and the statusline shows an error message or nothing at all
- Tests that guard it: `bash-4.1-gate` in `tests/regression.sh` (a static check that the guard code snippet remains verbatim within the first 20 lines)

### Dependency Command Checks

- Location: the `jq` check in the macOS version, the `jq` and `flock` checks in the Linux version
- What it does: when something is missing, prints a one-line message and exits (for the wording, see [SPEC.en.md](SPEC.en.md#startup-checks-and-fallback-output))
- What happens if removed: command-not-found errors flow into the statusline, making the cause hard to see
- Tests that guard it: none

### Using `printf '%s'` Everywhere

- Location: all output in both versions
- What it does: uses `printf '%s'` instead of `echo` to output values
- What happens if removed: when a value such as a session name starts with `-n` / `-e` or contains backslashes, `echo` interprets it as an option or escape and the value is lost
- Tests that guard it: `14-session-name-dash-n`, and `static:no-echo` in `tests/script-parity.sh`

### The Config File Loading Block

- Location: the "load user config file" block at the top
- What it does:
  - Reads the conf before the internal constants and the clamp, right before the customization settings
  - Before loading, `unset`s the 11 short-name variables (`SHOW_MODEL_NAME` / `COLOR_SCHEME` / `GIT_FETCH` / `PR_STATUS` / `SHOW_CWD` / `RATE_CHART_LEN` / `POLL_INTERVAL_SEC` / `GIT_FETCH_INTERVAL_SEC` / `LAYOUT_LINE1` / `LAYOUT_LINE2` /
    `HIGHLIGHT`)
  - Keeps the list of the 11 variables in one place, the array `STATUSLINE_CONF_VARS`, and uses it for both the `unset` and the `\r` stripping
  - Sources it with `.` only when `[ -f ] && [ -r ]` holds, and if it is unreadable, silently continues with defaults
  - Prepends `./` to paths that do not contain `/`
  - Right after loading, strips a trailing `\r` from the 11 variables (written back with `printf -v` and the indirect expansion `${!name%$'\r'}`)
  - Reads each setting as `${CLAUDE_STATUSLINE_X:-${X:-default}}`, in the order env > conf > default. For numeric settings without an env entry (`RATE_CHART_LEN` and the throttle intervals), the default is held only as an argument to
    `clamp_int`, and an empty value also falls back to the default
- What happens if removed:
  - Moving the load after the clamp leaves invalid throttle intervals in the conf unrounded, which disables throttling
  - Moving it after the internal constants lets the conf change internal constants such as `RATE_CHART_LEN_MAX`, breaking the stored count and the range guard
  - Removing the `unset` lets a same-named variable from the outer environment take effect in place of the conf
  - Checking only with `-r` makes `.` on a directory produce an error
  - Without `./`, `.` searches `$PATH` for the file and may read a different file from the one checked with `[ -f ]`
  - Without stripping `\r`, a conf value saved with CRLF becomes something like `light\r` and is silently treated as the default
  - Making a setting an unconditional assignment such as `X=300` overrides the conf value
- Tests that guard it:
  - `79-config-show-model-off` to `86-config-template`, `94-config-layout` to `96-config-layout-crlf`, `166-highlight-config` to `169-highlight-env-none`
  - `block:config-load` / `block:settings` in `tests/script-parity.sh`
  - For `unset`, the regression harness passes the short names with non-default values in every case, so removing it fails every case
  - The `./` prefix has no test

The conf is loaded as a shell script. JSON or YAML is not used because launching a parser such as `jq` on every render would add forks. Permissions and ownership are not checked (because `~/.claude/` is the user's own area).

### Clamping the Throttle Intervals

- Location: `RATE_CHART_LEN_MIN/MAX` / `RATE_WINDOW_SEC` / `POLL_INTERVAL_MIN_SEC` / `GIT_FETCH_INTERVAL_MIN/MAX_SEC`, the `clamp_int` right after them (`clamp_int <variable name> <default> <min> <max>`), and its calls
- What it does:
  - Rounds `RATE_CHART_LEN` to 2–20, `POLL_INTERVAL_SEC` to 60–(18000 ÷ `RATE_CHART_LEN`), and `GIT_FETCH_INTERVAL_SEC` to 60–1800
  - The upper bound `POLL_INTERVAL_MAX_SEC` for `POLL_INTERVAL_SEC` is computed from the rounded `RATE_CHART_LEN` as `RATE_WINDOW_SEC / RATE_CHART_LEN`. It is the interval at which the whole chart covers the 5-hour window, 1500 for the
    default chart length of 12. Even at the maximum of 20 it is 900, which does not fall below the minimum of 60 (the range never inverts)
  - The calls are placed in the order `RATE_CHART_LEN` → the `POLL_INTERVAL_MAX_SEC` computation → `POLL_INTERVAL_SEC`
  - Non-numeric, empty, and negative values revert to the defaults (12 / 300 / 900). The defaults appear only as arguments to these calls
  - Values of 9 or more digits are rounded to the maximum without comparison
  - A leading 0 is converted to decimal with `10#` (`08` → `8`)
  - Writes back directly to the variable with `printf -v`, without command substitution
- What happens if removed:
  - The throttle comparisons are arithmetic expressions, so `0` or a negative value causes no syntax error and disables throttling. With `GIT_FETCH=1`, `git fetch` is launched on every render, and the rate history is updated every time, so
    the chart stops showing a trend
  - Without the 9-or-more-digits check, `[ -lt ]` exits with an error (status 2) on a value beyond the integer range and slips past the rounding
  - Replacing the comparison with `[[ ]]` makes `[[ ]]` evaluate the value as an arithmetic expression, which can execute a command inside a conf value such as `a[$(cmd)]`. `[ ]` merely ends with an error if the value is not an integer, so
    `[ ]` is used even after the validation (`case`)
  - Writing the default in two places, here and in the settings block's `${X:-default}`, makes the fallback targets for empty and invalid values diverge when only one is changed
  - Without the `10#` normalization, `RATE_CHART_LEN=08` gives a `value too great for base` error in `$(( ))` or `for (( ))` (`POLL_INTERVAL_SEC` and the like are only compared with `[ ]`, so the output does not change without normalization)
  - If the order is swapped and the upper bound is computed before the `RATE_CHART_LEN` clamp, the division by the unrounded value (`0` or `abc`) errors out, or the bound is computed for an out-of-range chart length
- Tests that guard it:
  - Behavior: `clamp-zero-interval` (git-fetch-behavior), `poll-max-follows-chart-len` / `poll-max-default` / `poll-clamp-zero` / `poll-invalid-default` (rate-history-behavior)
  - Output: `82-config-invalid-values`, `85-config-huge-interval`, `128-rate-chart-len-clamp-zero` to `134-rate-chart-len-crlf`
  - Consistency between versions: `block:interval-clamp` in `tests/script-parity.sh`

The defaults are within the range, so the clamp does not change the default output. Rounding is done without warnings and rendering continues (the same "fall back on an invalid value and keep displaying" policy as the history directory
safety checks).

### Safety Checks for the History Directory

- Location: the "history directory" section (`HISTORY_DIR`)
- What it does:
  - Creates the default `/tmp/claude-statusline-<uid>/` and sets mode 700
  - Before mkdir / chmod, disables history if the existing path is a symlink
  - After creation, verifies "not a symlink", "is a directory", "owned by my uid", and "mode is 700", and empties `HISTORY_DIR` if any fails
  - Even when disabled, statusline rendering continues (the rate chart is shown without history)
- What happens if removed: `/tmp` is writable by other users, so a directory or symlink that someone else prepared in advance could be adopted, letting them hijack reads and writes of history and markers. If a symlink is passed via
  `CLAUDE_STATUSLINE_HISTORY_DIR`, chmod changes the permissions of the link target
- Tests that guard it: `48-rate-rightmost-no-history` (passes a symlink to exercise the disabling path). The uid and mode checks have no test

### Empty `cwd` Guard for Branch Lookup

- Location: main's branch lookup (`[ -n "$cwd" ]`)
- What it does: does not call git when `cwd` is empty or when git is absent
- What happens if removed: `git -C ""` targets the current directory, so an unrelated branch from the directory where the statusline was launched is displayed
- Tests that guard it: none. `73-cwd-empty-no-dir` handles an empty `cwd`, but the test's fake git treats paths that do not follow its convention as outside git, so removing the guard would not be detected

### Keep Network I/O and Extra git Calls Out of the Render Path

- Location: `git_ahead_behind`, main's git calls, `commit` in `layout_token`
- What it does: ahead/behind is computed with `rev-list` alone and never calls a synchronous `git fetch`. No extra git calls are made for detached detection or for getting the directory name. The hash and changed-line counts are fetched
  only when building the commit column. On a branch, `rev-parse --short HEAD` is called once for the hash, but for detached, the value main already obtained is used and not re-fetched. No other git calls are added
- What happens if removed: a synchronous fetch can take seconds to minutes, during which the statusline does not update. Each added git call adds one fork per render
- Tests that guard it: none (the fake git returns from fetch immediately, so adding a synchronous fetch would not change the output). That the rendered result does not change with `GIT_FETCH=1` is confirmed by `67-git-fetch-ahead` /
  `68-git-fetch-detached` / `69-git-fetch-no-upstream`

### The `*` Branch of `git_ahead_behind`

- Location: the branch taken when rev-list fails in `git_ahead_behind`, and the second argument `is_detached`
- What it does: when rev-list fails, returns an uncolored `*` if detached and a blue `*` otherwise. Returns empty only when both ahead and behind are 0
- What happens if removed: deleting the branch makes a branch without an upstream look the same as an in-sync branch. Emitting the uncolored `*` without capturing it with `$(...)` mixes in `static`'s trailing newline and breaks line 1
- Tests that guard it: `32-branch-detached`, `38-diff-detached`, `60-ab-ahead`, `61-ab-behind`, `62-ab-diverged`, `63-ab-synced`, `64-ab-no-upstream`, `65-ab-with-diff`, `66-ab-no-upstream-blue-star`

### Entry Guard of `maybe_git_fetch`

- Location: `[ "$GIT_FETCH" = "1" ] || return` at the top of `maybe_git_fetch`, and the repo / branch / detached / `HISTORY_DIR` checks
- What it does: with the default `GIT_FETCH=0`, returns without doing anything. Does not launch a fetch for a detached HEAD or for a branch with no upstream
- What happens if removed: network access occurs in the environments of users who did not opt in
- Rendering cost: with `GIT_FETCH=1`, even the normal path that does not launch a throttled fetch adds 3 forks (`cksum` / `date` / `stat`) per render. With `GIT_FETCH=0` (the default), it returns at the entry, so nothing is added
- Tests that guard it: `60-ab-ahead` (`fetch_marker: absent`), `67-git-fetch-ahead` (`present`), `68-git-fetch-detached` / `69-git-fetch-no-upstream` (`absent`)

### File Descriptor Redirection for the fetch Child Process

- Location: `( ... git fetch --quiet >/dev/null 2>&1 </dev/null & )` in `maybe_git_fetch`
- What it does: launches fetch in a fire-and-forget subshell and redirects stdout, stderr, and stdin all to `/dev/null`
- What happens if removed: the parent's command substitution, or whatever invoked the statusline, waits for EOF on the child's pipes (that is, for the fetch to finish). Rendering does not return until fetch completes, stalling for seconds
  to minutes
- Tests that guard it: `non-blocking` / `fetch-invoked` (git-fetch-behavior), and `static:fetch-fd-redirect` in `tests/script-parity.sh`

### The Four Environment Variables That Suppress Auth Prompts

- Location: `GIT_TERMINAL_PROMPT=0` / `GIT_ASKPASS=/bin/true` / `SSH_ASKPASS=/bin/true` / `SSH_ASKPASS_REQUIRE=force`, passed to the fetch child process
- What it does: when fetch asks for authentication, makes it give up immediately without touching the terminal
- What happens if removed:
  - Even after redirecting fds 0/1/2, the controlling terminal (`/dev/tty`) remains available to the child process
  - When a terminal exists, OpenSSH does not use `SSH_ASKPASS` and opens `/dev/tty` directly, so without `SSH_ASKPASS_REQUIRE=force`, passphrase or host-key prompts interrupt the Claude Code screen and steal key input
  - `GIT_TERMINAL_PROMPT=0` suppresses only git's own HTTPS prompt and has no effect on ssh
  - If any one is missing, a prompt appears through some path
- Tests that guard it: `static:no-prompt:maybe_git_fetch:*` in `tests/script-parity.sh` (a static check that the lines remain in `maybe_git_fetch`). There is no behavioral test that prompts really do not appear

In environments where ssh-agent has no key, fetch fails silently and `↓behind` is not updated. This is intended behavior, a result of prioritizing protecting the screen.

### Not Fetching When the Marker Write Fails

- Location: `if ! { true > "$marker"; } 2>/dev/null; then` in `maybe_git_fetch`
- What it does: if the throttle marker `${HISTORY_DIR}/fetch-<cksum of cwd>` cannot be written, releases the lock and returns without launching fetch
- What happens if removed: launching fetch without being able to write leaves no reference time for throttling, and the next render takes the same path. The statusline is called every few seconds, so fetch would be launched on every render.
  This happens when an unwritable marker with an old mtime remains, or when a directory with the same name exists (the mtime check passes, and `HISTORY_DIR` itself is writable, so the lock can still be taken)
- Tests that guard it: `marker-unwritable` (git-fetch-behavior)

`true` is used for the write, not `:`. `:` is a POSIX special built-in, and in sh-compatible mode a redirect failure terminates the whole shell. Error output is suppressed by enclosing the whole block as `{ ...; } 2>/dev/null`. Redirects
are processed left to right, so writing it afterward as `true > "$marker" 2>/dev/null` fails before fd 2 is swapped and prints `Permission denied` to the terminal.

Tests create the unwritable state with a directory named like the marker, because a `chmod 400` file is still writable in CI that runs as root.

### marker → unlock → spawn Order

- Location: the second half of `maybe_git_fetch`
- What it does: writes the marker, releases the lock, then launches fetch. Once the marker is written, other processes are rejected by the mtime check, so the lock has done its job at that point
- What happens if removed: with the order `spawn → unlock` in the Linux version, the named fd is not close-on-exec, so a copy is passed to the `( ... & )` child and the flock is held until fetch finishes. During that time, other statuslines
  wait on the lock. If it is closed first, the child does not receive the fd
- Tests that guard it: `lock-released` (git-fetch-behavior). Only the Linux version can actually verify fd inheritance; the macOS version detects a forgotten removal of the lock directory

Using the same order in both versions confines the implementation difference to the locking mechanism (flock / mkdir).

### File Descriptor Redirection and Environment Variables for the pr Child Process

- Location: `( ... pr_refresh_child ... >/dev/null 2>&1 </dev/null & )` in `pr_spawn_refresh`, and the `unset` / `export` just before it
- What it does: launches the child process fire-and-forget with fds 0/1/2 redirected to `/dev/null`, and prepares the following environment variables for `gh`
  - Set: `GH_PROMPT_DISABLED=1`, `GH_NO_UPDATE_NOTIFIER=1`, `GH_NO_EXTENSION_UPDATE_NOTIFIER=1`. `gh` sometimes calls git internally, so the same four git variables as fetch are set too
  - Remove: `GH_REPO` (it would query that repository instead of cwd), `GH_FORCE_TTY` and `CLICOLOR_FORCE` (output would use terminal-oriented formatting and colors, breaking the cache format)
  - Keep: `GH_TOKEN` / `GITHUB_TOKEN` / `GH_HOST` / `GH_ENTERPRISE_TOKEN` (the authentication method and host the user chose)
- What happens if removed: without the fd redirection, rendering stalls waiting for `gh` to finish (same as [File Descriptor Redirection for the fetch Child Process](#file-descriptor-redirection-for-the-fetch-child-process)). Without the
  environment variables, authentication or update-notice output interrupts the Claude Code screen, or the PR of a different repository is displayed
- Tests that guard it: `non-blocking` / `env-sanitized` (pr-status-behavior), and `static:pr-gh-env:*` / `static:no-prompt:pr_spawn_refresh:*` / `static:pr-fd-redirect` in `tests/script-parity.sh` (a change in only one version is caught by
  `block:pr-common`)

### pr marker → unlock → spawn Order and Marker Write Failure

- Location: the second half of `maybe_pr_refresh`
- What it does: proceeds in the order lock acquisition → re-check of the interval → marker mtime update → lock release → child launch. If the marker cannot be written, the child is not launched
- What happens if removed: the same as [marker → unlock → spawn Order](#marker--unlock--spawn-order) and [Not Fetching When the Marker Write Fails](#not-fetching-when-the-marker-write-fails). In the Linux version the flock remains until the
  fetch finishes, and launching without being able to write the marker launches `gh` on every render
- Tests that guard it: `marker-unwritable` / `throttle` (pr-status-behavior). That flock is not passed to the child has the same structure as fetch's `lock-released`, and the pr side has no dedicated test

### Do Not Move the pr `.inflight` Cleanup into a trap

- Location: `mkdir` → `pr_refresh_run` → `rmdir` in `pr_refresh_child`
- What it does: fetches only when it can create `.inflight`, and runs `rmdir` when done. The cleanup is not made an EXIT `trap`
- What happens if removed: in macOS `/bin/bash` 3.2, an EXIT `trap` set in a subshell launched with `&` does not run. If left to a `trap`, `.inflight` remains and the next fetch is not launched until `PR_INFLIGHT_STALE_SEC` (90 seconds)
  passes. A marker left because a kill or similar prevented reaching `rmdir` also disappears after the same 90 seconds
- It runs `rmdir` only when the mtime of `.inflight` is the same as when it was created (its own marker). If, while stopped, the parent removed it as stale and the next child recreated it, removing that marker would cause overlapping
  fetches
- Tests that guard it: cases that wait for fetch completion by the disappearance of `.inflight`, such as `throttle` / `branch-switch` / `no-overwrite-by-older` (pr-status-behavior), as well as `single-flight` / `stale-inflight`

### Reading the pr Cache and Validating Values

- Location: `pr_cache_load`, `pr_is_positive_int`, `format_pr`
- What it does: does not trust the cache. If the number or state is invalid, the whole column is omitted, and for other fields unexpected values are treated as absent. The URL is embedded in OSC 8 only when it starts with `https://` and the
  rest consists only of ASCII alphanumerics and symbols usable in URLs. The allowed characters are enumerated without using `[[:cntrl:]]` or `A-Z`, because which characters a character class or range includes differs by OS locale
  implementation (on macOS, U+202E also falls under `[[:cntrl:]]`) and can make the output of the two versions diverge
  - The number and the comment count are checked with the same `pr_is_positive_int` (a positive integer of at most 9 digits with no leading 0). If the count is 0 or invalid, the count is not shown
- What happens if removed: the cache is a file under `/tmp`, which can be corrupted, and `gh` output can differ from expectations. If ESC or BEL gets mixed into the URL, OSC 8 closes midway and the display of the following columns breaks
- Tests that guard it: `108-pr-stale` to `112-pr-invalid-optional-fields`, `115-pr-url-non-ascii`, `future-fetched-at` / `comment-count` (pr-status-behavior)

### Hyphen Separator in rate

- Location: `format_limit`
- What it does: for a colored remaining amount, separates with space-hyphen-space as `chart NN% - HH:MM`. Parentheses are not used. weekly is separated the same way by the same function, as `spark NN% - Mon`
- What happens if removed: the format diverges from SPEC (` - ` separator, no parentheses), and checks such as `not_contains: (22:13)` in `02-rate-warning-with-reset` fail
- Tests that guard it: `02-rate-warning-with-reset` (`not_contains: (22:13)`), `03-rate-warning-no-reset`, `05-rate-danger`, `06-rate-critical`, the boundary cases `24` to `29`, `137-weekly-warning-with-reset` (`not_contains: (Tue)`),
  `138-weekly-warning-no-reset`

### Second-Line Tokens Are Pushed Even When Empty

- Location: `build_layout "${LAYOUT_LINE2}|${LAYOUT_LINE2_TOKENS}" "|${LAYOUT_LINE2_TOKENS}|" 1`
- What it does: line 2 does not drop a column even when its value is empty. Tokens that were not written are appended at the end
- What happens if removed: setting the third argument to `0` breaks "line 2 is always printed". However, `format_limit` and `model_ctx` always return non-empty values (`<chart> --` / `· --` even when usage is missing), so the current tests
  keep passing while only the invariant is lost
- Tests that guard it: completion is covered by `89-layout-line2-reorder`, `93-layout-line2-partial`, `91-layout-unknown-token`, `145-layout-line2-weekly-first`. That a column remains when weekly is missing is covered by
  `143-weekly-missing`. Pushing even when empty has no test of its own

### Line 1 Omission and Newline Placement

- Location: `if [ ${#line1_parts[@]} -gt 0 ]` and `printf '%s\n'` at the end of main
- What it does: prints "joined result + newline" only when line 1 has elements
- What happens if removed: printing a newline with no elements makes a blank line occupy one line of statusline height. Moving the newline to the start of line 2 puts a blank line at the top when line 1 is absent. Calling `join_by` twice
  unconditionally gives the same result
- Tests that guard it: `72-cwd-root-no-dir`, `73-cwd-empty-no-dir`, `74-show-cwd-off-git-outside`, `77-show-cwd-off-drops-line1`, `90-layout-line1-none` (all `no_line2`)

### rate Chart Base and Rightmost Replacement

- Location: `rate_chart=$(history_chart /dev/null)`, `spark_of rate_now_spark "$rate_remaining"`, and `rate_chart="${rate_chart:0:$((RATE_CHART_LEN - 1))}${rate_now_spark}"` in main
- What it does: see [rate Chart Base and the Rightmost Current Value](#rate-chart-base-and-the-rightmost-current-value)
- What happens if removed: without the replacement, the rightmost character is also a throttled old value, and the remaining amount right after a reset is not reflected. Moving the base initialization after the `HISTORY_DIR` branch, or
  removing it, leaves `rate_chart` empty when history is disabled, and the rightmost character is not drawn
- Tests that guard it: `47-rate-rightmost-live` / `126-rate-chart-len-seed-pad` (seed old history), `48-rate-rightmost-no-history` / `127-rate-chart-len-no-history` (disable history)

### Color Definition Blocks Must Match in Both Versions

- Location: the "color scheme" block in both versions (`_fg` and `case "$COLOR_SCHEME"`)
- What it does: defines the same RGB values in the same way in both versions
- What happens if removed: changing the values in only one version makes the colors of the two versions diverge for the same input. The regression tests run only the version that can run (in CI only the Linux version; on macOS the Linux
  version is skipped depending on bash 4.1+ and the presence of `flock`), so output comparison alone cannot notice drift
- Tests that guard it: `block:color-scheme` in `tests/script-parity.sh`. The light values are partly confirmed by `81-config-light-scheme` / `84-config-crlf`

### Blink Attribute

- Location: the critical tier of `limit_color` / `ctx_color` (`printf 'static \033[5m%s' "$COLOR_error"`)
- What it does: see [Three Severity Tiers and Blinking for rate, weekly, and ctx](#three-severity-tiers-and-blinking-for-rate-weekly-and-ctx)
- What happens if removed: the critical and danger tiers are distinguished by color alone, and the visual step between them becomes smaller
- Tests that guard it: `06-rate-critical`, `10-ctx-critical`, `23-ctx-boundary-90`, `29-rate-boundary-remaining-5`, `140-weekly-critical`

### Separate `paint` for effort, and `∙`

- Location: main's effort concatenation (`effort_field=$(paint "$effort" $effort_effect)` and the `SHOW_MODEL_NAME` branch)
- What it does: see [Joining effort and Its Separator](#joining-effort-and-its-separator)
- What happens if removed: painting model and effort in a single `paint` mixes the colors. Including `∙` in `paint` puts `∙` into the rainbow cycle for `max` and shifts the colors of the word. Removing `[ -n "$effort" ]` produces an extra
  separator for models that do not support effort
- Tests that guard it: `51-effort-low` to `55-effort-max-rainbow`, `56-effort-absent`, `57-model-off-effort`, `58-model-off-no-effort`, `59-model-on-effort-opus`

### Trailing Slash Removal for directory

- Location: the `while` loop on `dir_path` in main
- What it does: see [directory Column](#directory-column)
- What happens if removed: with a `cwd` that has a trailing slash, the directory column disappears entirely
- Tests that guard it: `78-cwd-trailing-slash`, `72-cwd-root-no-dir`

### Cap on Line Counts for Untracked Files

- Location: `UNTRACKED_DIFF_LIMIT` in `git_diff_stat`
- What it does: limits line counting for untracked files to 50 and counts only the number of files beyond that
- What happens if removed: in a working tree with a large number of untracked files, a per-file `git diff --no-index` slows rendering
- Tests that guard it: none (the aggregation of untracked files itself is covered by `42-diff-untracked-only` to `45-diff-untracked-subdir`)

### `highlight` Does Not Paint Empty Strings

- Location: `[ -n "$2" ] || return 0` in `highlight`
- What it does: returns an empty string as empty, without wrapping it in `COLOR_text`
- What happens if removed: an empty session or the directory under `SHOW_CWD=0` becomes a non-empty value consisting of only ESC, producing an extra ` | ` on line 1. Line 1 would also be printed when all of its columns are empty. This
  occurs when `directory` or `session` is written in `HIGHLIGHT`
- Tests that guard it: `163-highlight-empty-columns`, `164-highlight-empty-line1`, and `177-commit-highlight-unborn`, which passes an empty hash on an unborn branch

### Trim Before Passing Through `highlight`

- Location: branch / session in `layout_token`, and the model assembly in main
- What it does: passes the string to `highlight` after trimming it with `truncate_branch` / `truncate_label`
- What happens if removed: painting before trimming makes ANSI escapes count as characters and changes the trim position. `\033[0m` may be cut off, leaking the color into the following columns. branch is highlighted by default, so this
  happens even with the default settings
- Tests that guard it: `152-highlight-branch-trim-head`, `153-highlight-branch-trim-middle`, `154-highlight-session-trim`

### Building `HIGHLIGHT` and Painting Order

- Location: the construction of `hl_set` in main, and the `highlight` calls in `format_ctx` / `format_limit` / model / `layout_token`
- What it does: see [Highlighting (`HIGHLIGHT`)](#highlighting-highlight)
- What happens if removed: placing `hl_set` after the element assembly silently disables highlighting for those elements. Passing the time through `format_limit` without moving the chart to `chart_out` prints the time twice instead of the
  chart. Removing branch's `case` turns a name without `/` into `main/main`
- Tests that guard it:
  - `146-highlight-all-dark` to `170-highlight-pr-comments`, `175-commit-highlight` to `177-commit-highlight-unborn`
  - Order: `149-highlight-directory-only`; `chart_out`: `160-highlight-rate-reset-only`; branch's `case`: `150-highlight-branch-no-slash` / `151-highlight-branch-detached`
  - Drift between versions: `block:paint` / `block:pr-common` / `block:format-layout` / `block:main-render` in `tests/script-parity.sh`

## Rejected Alternatives and Background

### A Setting to Return to a One-Line Layout

After the move to the two-line layout, no setting to return to a one-line layout was added, because offering one would mean maintaining the expectations for both in the tests. Removing all line 1 elements with `LAYOUT_LINE1` makes line 1
disappear, but this is the same "line 1 omission" that happens when line 1 is empty, for example outside git, and does not move the line 1 elements onto line 2. Claude Code's statusline renders each line of the output as-is as one line.

### Keeping Only the First Segment of a Branch Name / Cutting from the Left

For middle elision of branch names, two forms were not adopted: keeping only the first segment, as in `feature/…/yyy`, and cutting from the left, as in `…/yyy`. The former leaves less width for the tail when the first segment is long, and
the latter loses cues about the kind of branch, such as `feature/` or `hotfix/`. The head is kept for as many characters as fit in 25 and cut without aligning to a `/` position, so that parameter expansion alone suffices without adding code
to search for segment boundaries.

### Session Name Trim Length (20 → 40 Characters)

Session names used to be trimmed to 20 characters, but moving to two lines and placing them at the end of line 1 freed up horizontal width, so the limit was widened to 40 characters.

### Source of the directory Column

The directory column comes from the basename of `workspace.current_dir`. The following alternatives were not adopted.

- Prefer `repo.name`: it is missing outside git, which adds branches
- Prefer `project_dir`: it is the directory where Claude Code was launched, so the display drifts if you `cd` during the session

### SSH `BatchMode=yes`

Specifying `BatchMode=yes` through `GIT_SSH_COMMAND` to suppress authentication in the background fetch is not used, because it would override the user's own ssh configuration set via `core.sshCommand` and silently break it. The
askpass-family environment variables are used to suppress prompts instead.

### Synchronous fetch in the Render Path

Fetching on every render to keep `↓behind` up to date was not adopted, because rendering would stall on the network. Users who need it opt in with `GIT_FETCH=1`, and the result of a fetch fired and forgotten in a separate process is
reflected in later renders.

### Unit of fetch Throttling

The throttle marker is keyed by the `cksum` of `cwd`. Making it per repo root would require calls such as `git rev-parse --show-toplevel`, so it stays per cwd. As a result, different subdirectories or worktrees of the same repository are
counted separately, and the number of fetches grows in proportion to how many are open. `cksum` is a CRC over the bytes, so it is unaffected by locale or multibyte paths.

### Making PR Status a Standalone Layout Token

Making PR status a standalone token of `LAYOUT_LINE1` was not adopted. A PR is information tied to a branch, so it is placed inside the branch column (to the right of ab), separated by a single half-width space, and enabled by the flag
`PR_STATUS`, which has the same form as `GIT_FETCH`. `gh` is launched only when building the branch column with `PR_STATUS=1`, so removing branch from the layout also stops `gh` from launching.

### The stdin `pr` Field

The `pr` field that Claude Code passes to the statusline is not used. It comes from the same source as the footer's PR badge, and it stays pinned to the first PR even if you switch PRs in the same session. It also exists only when there is
an open PR, and has no CI information. Fetching it ourselves with `gh` displays the correct PR even in the same session.

### Expressing PR State with an Underline Color (SGR 58)

Claude Code's footer PR badge colors the underline, but the PR status display expresses state with the text color of `#<number>`, and the underline (SGR 4) is applied in the same color as the text. This is because it has not been confirmed
whether Claude Code's statusline rendering passes the underline color (SGR 58) through as-is.

### Colors for pending and draft PR Numbers

- Fixing pending to `text`: `text` is the color of elements chosen with `HIGHLIGHT`, and using it as a state color too would give it two meanings
- Using a single color, `subtle` or `inactive`, for draft: each has the same value in both themes, so it is hard to read in one of them
- Using `secondaryText` (dark `153;153;153` / light `102;102;102`) for draft: it is an existing theme-dependent color, but in dark it is farther from white than `subtle`, making the difference from pending larger
- Making draft italic (SGR 3): italics look out of place among the other elements
- Making draft dim (SGR 2): how faint it becomes depends on the terminal, and like gray it can become hard to read

### `gh pr list --json` and Other Ways of Counting Comments

`gh pr list --json` / `gh pr view --json` are not used. For `comments`, both return only conversation-tab comments ([cli/cli#11477](https://github.com/cli/cli/issues/11477)) and do not include line comments or reviews with a body. They are
also heavy, because they fetch bodies when only the count is wanted.

The comment count is taken from GraphQL's `totalCommentsCount`. It returns, as a single value, the count GitHub itself computed (conversation comments, line comments and their replies, and reviews with a body), matching the number on the
speech-bubble icon in the PR list. Together with the other values used to select the PR, it is obtained in a single query (cost 1). The following ways of counting were not adopted.

- `comments` and `review_comments` from REST `GET /repos/{owner}/{repo}/pulls/{number}`: the PR number is needed first, so together with the query that finds the PR from the branch it takes two calls. It also does not count reviews with a
  body
- Summing the per-kind `totalCount` in GraphQL (`comments` + `reviewThreads` + `reviews`): `reviewThreads.totalCount` is the number of threads, not comments, so replies are not counted. Summing the comment count per thread requires fetching
  nodes with `first: N`, and counts are missed beyond the limit. Reviews cannot be filtered by whether they have a body

### Aggregating Each `statusCheckRollup` Check Ourselves

The CI symbol uses `statusCheckRollup.state` (the value aggregated by GitHub) as-is and does not aggregate individual checks itself. Doing so would leave an old failure and keep showing `✗` even after a failed job is rerun and succeeds, and
checks beyond the fetch limit would be dropped.

### rate Chart Length and History Settings

- Publishing `HISTORY_LEN` as-is: `HISTORY_LEN` was guaranteed by SPEC and test `82` as an example of an "internal constant that conf cannot change", so publishing the same name would invert its meaning. The public name is `RATE_CHART_LEN`,
  and `HISTORY_LEN` was removed
- Truncating the history file to the display length: right after lengthening, `·` fills the chart, and a session with a short chart would trim the history of a session with a long chart. The stored count is fixed by `RATE_CHART_LEN_MAX`
  ([History Files and Locking](#history-files-and-locking))
- Making the upper bound of `POLL_INTERVAL_SEC` a fixed value / removing the upper bound: the former loses its rationale (the whole chart covers 5 hours) when the chart length changes, and the latter lets through values that make throttling
  meaningless
- Adding an env override to `POLL_INTERVAL_SEC` or `RATE_CHART_LEN`: the throttle reference for the history file shared by all sessions would vary per session, and the session with the shortest interval would dominate appends. The chart
  length determines the upper bound of `POLL_INTERVAL_SEC`, so it gets no env override for the same reason. Adding env and deriving the upper bound only from values that env does not affect would also break the correspondence between chart
  length and upper bound, leaving the bound without rationale

### weekly Display

- Show weekly only when written: this introduces a per-token exception in `build_layout`, and users whose `LAYOUT_LINE2="model_ctx|rate"` was copied from the distributed template would not get the new column. weekly follows the line 2 rule
  that "tokens that were not written are appended at the end"
- Omit the whole column when usage is missing: existing expectations would not change, but "line 2 pushes even empty values" would break
- Use a history chart like rate: the requirement is only the current remaining amount, and recording a 7-day window at the 5-hour throttle interval would not show a trend
- Attach a time to the weekday: with the weekday alone you cannot tell whether a reset on the same weekday as today is within 24 hours or 6 or more days away, but as required it shows only the weekday, and this is documented in SPEC as a
  limitation

### Highlight Implementation

- Use the uncolored return value of the color-deciding functions (`ctx_color` / `limit_color` / `model_color`) as the highlight color: `format_ctx` and `format_limit` decide whether to show the number `NN%` by whether a color applies
  (whether the effect specification is not `static`), so highlighting alone would make the number appear. The unit of painting also does not match: when uncolored, each element is painted separately (chart and time separately), and when
  colored, the whole is painted in a single color
- Make model's "`highlight` if uncolored, `paint` if colored" a general-purpose helper: there is only one such branch, so adding a helper would not reduce duplication
- Make `HIGHLIGHT` a per-token boolean setting (such as `HIGHLIGHT_BRANCH=1`): the number of settings would grow with the number of tokens, and so would the list in the conf-loading block. It is a single variable in the same format as
  `LAYOUT_LINE*`, and splitting is shared via `split_tokens`
- The uncolored elements that are excluded (the detached `*`, closed PR numbers, `--`, and so on) and the reasons are summarized in [SPEC.en.md](SPEC.en.md#highlight-highlight)

### Other

The following alternatives were also not adopted. The reasons are given at each link.

- Distinguishing no upstream from anomalies, and green for ahead: [ahead/behind and the `*` Decision](#aheadbehind-and-the--decision)
- JSON / YAML for conf: [The Config File Loading Block](#the-config-file-loading-block)
- `flock` in the macOS version: [Differences Between the macOS and Linux Versions](#differences-between-the-macos-and-linux-versions)
- Associative arrays in the layout: [Layout Token Design](#layout-token-design)

## Spots the Tests Do Not Cover

Changing or removing the following items is not detected by the current tests. Check them in review when you change them.

- The message for the dependency command check
- The uid and mode checks for the history directory
- Whether the range painted by `HIGHLIGHT` is readable in the actual Claude Code statusline (it becomes unreadable if `COLOR_SCHEME` and the theme mismatch. Check visually with `npm run preview`)
- The empty `cwd` guard for branch lookup
- That no synchronous fetch or git call has been added to the render path
- That auth prompts really do not appear (the presence of the lines is checked by `tests/script-parity.sh`)
- Pushing second-line tokens even when empty
- The cap from `UNTRACKED_DIFF_LIMIT`
- The `./` prefix on the config file path
- Locale pinning (the presence of the line is checked by `tests/script-parity.sh`. Output comparison depends on the runtime locale)
- That `gh` and git auth prompts really do not appear in the PR status child process (the presence of the lines is checked by `tests/script-parity.sh`)
- That the PR status underline (SGR 4), strikethrough (SGR 9), and OSC 8 links are actually rendered in the real Claude Code statusline (this depends on the terminal and Claude Code's rendering, so check visually)
- The shape of real GitHub responses (the fake gh returns fixed response JSON. Confirm locally that the query and `--jq` work with the real `gh`)
- That the `--jq` expressions work in the gojq built into `gh` (the fake gh evaluates with jq, so using a function that exists only in jq would not be detected)
