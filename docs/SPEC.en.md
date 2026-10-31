English | [🗾 日本語はこちら](./SPEC.md)

# Output Specification

> This is an English translation. If it differs from [SPEC.md](./SPEC.md) (Japanese), the Japanese version is authoritative.

This document describes the externally observable output that statusline-macos.sh (macOS version) and statusline-linux.sh (Linux version) must satisfy.
Both versions return **identical output** for the same input. For implementation rationale and alternatives that were not adopted, see [DESIGN.en.md](./DESIGN.en.md). For how to write tests, see [tests/README.en.md](../tests/README.en.md).

A change that alters the output must update this document and the expected values in `tests/assertions/` in the same change.

## Table of Contents

- [Input](#input)
- [Output Structure](#output-structure)
- [Line 1 Elements](#line-1-elements)
- [Line 2 Elements](#line-2-elements)
- [Trimming Rules](#trimming-rules)
- [Colors](#colors)
- [Rate Limit History](#rate-limit-history)
- [Configuration](#configuration)
- [Background Fetch (`GIT_FETCH=1`)](#background-fetch-git_fetch1)
- [PR Status (`PR_STATUS=1`)](#pr-status-pr_status1)
- [Startup Checks and Fallback Output](#startup-checks-and-fallback-output)
- [Non-Goals](#non-goals)

## Input

The following fields are used from the JSON that Claude Code passes on stdin.

| Field | Purpose | When missing |
| --- | --- | --- |
| `model.display_name` | Model name and color | Treated as `Unknown` |
| `effort.level` | Reasoning effort and its color | effort is not shown |
| `context_window.used_percentage` | Context usage | ctx is shown as `· --` |
| `rate_limits.five_hour.used_percentage` | Rate limit usage | rate is shown as `<chart> --` |
| `rate_limits.five_hour.resets_at` | Reset time (epoch seconds) | The time is not shown (same as `0`) |
| `rate_limits.seven_day.used_percentage` | Weekly (7-day) rate limit usage | weekly is shown as `· --` |
| `rate_limits.seven_day.resets_at` | Weekly reset time (epoch seconds) | The weekday is not shown (same as `0`) |
| `session_name` | Session name | The session column is omitted |
| `workspace.current_dir` | Used to get the directory name, branch, and commit hash. Also used to get ahead/behind, as the unit for throttling `GIT_FETCH`, and to get the PR status (cache key and the directory where `gh` / `git` run) | The directory column, the branch column (`<ab>` and `<pr>` are not shown either), and the commit column are omitted |

- Control characters (newline, tab, CR, ESC, etc.) in string fields (`model.display_name` / `session_name` / `workspace.current_dir` / `effort.level`) are replaced with a space.
  This prevents an ANSI escape hidden in a value from changing the color of the columns that follow
- Values are output as-is, without processing (a session name that starts with `-n` is displayed literally)
- The `pr` field is not used ([reason](DESIGN.en.md#the-stdin-pr-field)). The PR status is fetched by the script itself with `gh` when [`PR_STATUS=1`](#pr-status-pr_status1)
- `rate_limits` is passed only to subscribers such as claude.ai Pro / Max, and only after the first API response of a session. `five_hour` and `seven_day` can each be missing independently
- `rate_limits.spend_limit` is not used

## Output Structure

The output has **two lines**.

```text
<directory> | <branch>[ <ab>][ <pr>] | [<hash> ]<diff> | <session_name>
✻ <model>∙<effort> <ctx> | <rate> | <weekly>
```

The above is the order in the default layout. The order within each line can be changed with the [layout](#layout-layout_line1--layout_line2). `<pr>` appears only when `PR_STATUS=1`.

### Separators

| Position | Separator |
| --- | --- |
| Between columns (both lines) | ` \| ` (space, pipe, space) |
| Between `<model>` and `<effort>` | `∙` (U+2219, no surrounding spaces, uncolored) |
| Between `<effort>` (or `<model>`) and `<ctx>` | One space (no pipe) |
| Between the branch name and `<ab>`, and between `<ab>` and `<pr>` | One space (not placed before an empty element) |
| Between `<hash>` and `<diff>` | One space (not placed if `<hash>` is empty) |

### Line 1

- The default order is `directory` → `branch` → `commit` → `session`
- A column whose value is empty is **omitted entirely**, including its separator
- When every column is empty, **line 1 is not output at all**. No newline is output either, so the output is a single line containing only line 2
- The newline is attached to the end of line 1. No blank line ever appears at the start of the output when line 1 is absent

### Line 2

- The default order is `model_ctx` → `rate` → `weekly`
- **Always output**. `model_ctx`, `rate`, and `weekly` are always included
- `session_name` is not placed on line 2

## Line 1 Elements

### directory

The basename of `workspace.current_dir`.

- The trailing `/` is removed before taking the basename (`/tmp/my-project/` → `my-project`)
- When `current_dir` is `/` or empty, the basename is empty and the column is omitted entirely
- Trimmed to 25 characters ([Trimming Rules](#trimming-rules))
- Uncolored (the terminal and Claude Code foreground color). When `directory` is listed in `HIGHLIGHT`, the whole trimmed name is painted with `text` ([Highlight](#highlight-highlight))
- Not shown when `SHOW_CWD=0`. The two-line structure and the other line 1 elements remain
- git is not used to obtain it

### Branch column

Output `<branch>[ <ab>][ <pr>]` as a single column.

Branch name:

- The result of running `git branch --show-current` in `workspace.current_dir`
- When the result is empty and `git rev-parse --short HEAD` succeeds (detached HEAD), `HEAD` is output instead of the branch name. `<ab>` becomes an uncolored `*` (`HEAD *`). The short sha appears in the [commit column](#commit-column)
- Outside git, with an empty `current_dir`, or with git not installed, the **column is omitted entirely** (`<ab>` and `<pr>` do not appear either)
- Trimmed to 25 characters. If the name contains `/` and the last segment (after the last `/`) is 22 characters or fewer, the last segment is kept and the middle is omitted ([Trimming Rules](#trimming-rules))
- `<ab>` and `<pr>` are not subject to trimming and remain even when the branch name is cut
- The part of the trimmed name after the last `/` (the whole name if there is no `/`) is painted with `text`, and the part before it is uncolored.
  This is the display for the default `HIGHLIGHT` value `branch`; if `branch` is removed from `HIGHLIGHT`, the whole name is uncolored ([Highlight](#highlight-highlight)). A detached `HEAD` contains no `/`, so the whole name is painted

#### ahead/behind (`<ab>`)

Placed to the right of the branch name. Derived from the result of `git rev-list --left-right --count '@{upstream}...HEAD'`; it does not access the network (it reflects the difference as of the last fetch/pull).

| State | Display | Color |
| --- | --- | --- |
| ahead only (waiting to push) | `↑N` | `professionalBlue` (`106;155;204`, same for light) |
| behind only (waiting to pull) | `↓M` | `warning` (dark `255;193;7` / light `150;108;30`) |
| both | `↑N↓M` (ahead first, no separator) | ahead and behind are each painted in their own color |
| in sync (ahead=behind=0) | Nothing is output | — |
| no upstream set (rev-list fails) | `*` | `professionalBlue` (blue) |
| detached HEAD (rev-list fails) | `*` | Uncolored (foreground color) |

- `↑` is U+2191, `↓` is U+2193, and `*` is ASCII U+002A
- If the branch name is available but rev-list fails for another reason, the result is the same blue `*` as for no upstream
- Green is not used for ahead (it would be the same color as `+add` of `<diff>` on the same line 1, which is confusing)

#### PR Status (`<pr>`)

The GitHub PR linked to the current branch is shown as `#<number>[<CI symbol>][ <count>]`, to the right of `<ab>` (or to the right of the branch name if `<ab>` is empty), separated by a space (example: `main ↑1 #12✓ 3`).
Shown only when `PR_STATUS=1`. For details, see [PR Status (`PR_STATUS=1`)](#pr-status-pr_status1).

### Commit column

Output `[<hash> ]<diff>` as a single column.

Commit hash (`<hash>`):

- The result of running `git rev-parse --short HEAD` in `workspace.current_dir`. The number of digits is decided by git (by default the shortest unique length, at least 7 digits; it can be changed with `core.abbrev`)
- Not trimmed
- Uncolored. When `commit` is listed in `HIGHLIGHT`, only the hash is painted with `text`. The color of `<diff>` does not change ([Highlight](#highlight-highlight))
- When there is no commit yet (unborn), the hash cannot be obtained and only `<diff>` is output. No space is placed before it
- The display condition is the same as for the branch column. Outside git, with an empty `current_dir`, or with git not installed, the **column is omitted entirely**
- When `commit` is absent from `LAYOUT_LINE1`, neither the hash nor `<diff>` is output

#### Changed Lines (`<diff>`)

To the right of the hash, `<files><+added><-removed>` is output packed together with no separator (example: `3+13-5` = 3 files, +13 lines, -5 lines).

| Item | Specification |
| --- | --- |
| Tracked files | `git diff HEAD --numstat` (staged + unstaged) |
| Untracked files | The `??` entries of `git status -z`. All lines of each file are added to `+` (files matched by `.gitignore` are not included) |
| Limit on counting lines of untracked files | 50 files (`UNTRACKED_DIFF_LIMIT`). From the 51st file on, files are counted only in the file count and their lines are not added |
| Binary files | Counted in the file count but not added to the line counts |
| Color of the file count | `text` (a fixed color depending on `COLOR_SCHEME`: dark white `255;255;255` / light black `0;0;0`; not the default foreground color) |
| Color of `+N` | `success` (green) |
| Color of `-N` | `error` (red) |
| One side is 0 | That side is omitted (`3+8`, `2-5`). The file count is always output if there is any change |
| All 0 (clean) | `·` (U+00B7, uncolored) |

- In an unborn repository `git diff HEAD --numstat` fails, and the staged entries of `git status -z` (`A  path`) are not counted, so when there are only staged files the result is `·`

### session_name

- The value of `session_name` is output as-is. If empty, the column is omitted entirely
- Trimmed to 40 characters
- Uncolored. When `session` is listed in `HIGHLIGHT`, the whole trimmed name is painted with `text` ([Highlight](#highlight-highlight))
- Placed at the end of line 1 in the default layout

## Line 2 Elements

### model_ctx

Output `✻ <model>∙<effort> <ctx>` as a single column.

#### model

- `✻` (U+273B) and the model name are joined by one space and painted together in the model color
- The model name is trimmed to 13 characters. The color is decided from the full name before trimming
- When `SHOW_MODEL_NAME=0`, the model name is not output, and only `✻` is output, painted in the model color. `✻` is always shown regardless of settings
- For a model whose color is uncolored (Sonnet, `Unknown`, etc.), listing `model` in `HIGHLIGHT` paints from `✻` through the trimmed model name (only `✻` when `SHOW_MODEL_NAME=0`) with `text` ([Highlight](#highlight-highlight))

#### effort

- The value of `effort.level` is output as-is (`low` / `medium` / `high` / `xhigh` / `max`). Not trimmed
- Only the effort word is painted in the effort color, separately from model
- When `SHOW_MODEL_NAME=1`, an uncolored `∙` is placed between it and `<model>` (no surrounding spaces)
- When `SHOW_MODEL_NAME=0`, `∙` is not placed and there is one space between it and `✻` (`✻ high`)
- When `effort.level` is absent, neither `∙` nor effort is output (`✻ <model> <ctx>`)
- Any other value is output as-is, uncolored

#### ctx

The current usage is shown as a one-character spark. No history is kept.

| Usage | Display |
| --- | --- |
| 70% or more | `<spark> NN%` painted in the usage color |
| Less than 70% | `<spark>` only (no number, uncolored) |
| Missing | `· --` |

- `<spark>` is one character out of the eight levels `▁▂▃▄▅▆▇█`. For usage p, `int(p / 100 × 8 + 0.5)` is clamped to 1–8 and the character for that level is used
- The value of usage rounded to an integer is used for `NN` and for the color decision
- When uncolored (under 70%, or missing), listing `ctx_chart` in `HIGHLIGHT` paints `<spark>` (`·` when missing) with `text`. `--` is not painted ([Highlight](#highlight-highlight))

### rate

Shows the **remaining** 5-hour rate limit (100 − usage rounded to an integer). The chart is `RATE_CHART_LEN` characters (default 12).
By default, it lines up the latest 11 history entries, recorded at intervals of 300 seconds (5 minutes) or more, followed by the current value.
While rendering continues, this covers about one hour of progress (history is recorded only at render time, so gaps appear in periods when rendering stopped).

| Remaining | `resets_at` > 0 | `resets_at` is 0 or missing |
| --- | --- | --- |
| Over 40% (uncolored) | `<chart> HH:MM` | `<chart>` |
| 40% or less (colored) | `<chart> NN% - HH:MM` | `<chart> NN%` |

- The number `NN%` is shown only when a color is applied
- The separator between the number and the time is ` - ` (space, hyphen, space). Parentheses `()` are not used
- When a color is applied, everything from `<chart>` to the end is painted together in the remaining-capacity color
- `HH:MM` is `resets_at` converted to local time
- When usage is missing, the output is `<chart> --` (uncolored). In this case the rightmost character of the chart is not replaced with the current value
- When uncolored (over 40%, or missing), listing `rate_chart` in `HIGHLIGHT` paints `<chart>` with `text`, and listing `rate_reset` paints `HH:MM`. `--` is not painted ([Highlight](#highlight-highlight))

Chart:

- The rightmost character is **always the spark of the current remaining capacity**. It reflects the latest value on every render, independent of the sampling interval
- The `RATE_CHART_LEN − 1` characters on the left show the progression from the [Rate Limit History](#rate-limit-history)
- When the history has fewer than `RATE_CHART_LEN` entries, the left side is padded with `·` (U+00B7)
- Even when history cannot be saved (`HISTORY_DIR` is invalid), one character for the current value is output to the right of `RATE_CHART_LEN − 1` `·` characters (with the default length, `···········▁ 10% - 22:13`)

### weekly

Shows the **remaining** 7-day rate limit (100 − usage rounded to an integer) as the same one-character spark as ctx. No history is kept, so it does not show the decline over time.

| Remaining | `resets_at` > 0 | `resets_at` is 0 or missing |
| --- | --- | --- |
| Over 40% (uncolored) | `<spark> Mon` | `<spark>` |
| 40% or less (colored) | `<spark> NN% - Mon` | `<spark> NN%` |
| Usage is missing | `· --` (uncolored) | `· --` (uncolored) |

- `<spark>` follows the same rule as the rightmost character of the rate chart (eight levels `▁▂▃▄▅▆▇█`; for remaining capacity p, `int(p / 100 × 8 + 0.5)` is clamped to 1–8)
- The color thresholds, blinking, the condition for showing the number, and the ` - ` separator are the same as for rate. When a color is applied, everything from `<spark>` to the end is painted together
- The weekday is the three-letter English abbreviation of the weekday of `resets_at` converted to local time (`Sun` `Mon` `Tue` `Wed` `Thu` `Fri` `Sat`). It is in English regardless of the user's locale
- It is not affected by `POLL_INTERVAL_SEC` or `RATE_CHART_LEN`
- When uncolored (over 40%, or missing), listing `weekly_chart` in `HIGHLIGHT` paints `<spark>` (`·` when missing) with `text`, and listing `weekly_reset` paints the weekday. `--` is not painted ([Highlight](#highlight-highlight))

> [!NOTE]
> Since only the weekday is shown, a reset that falls on the same weekday as today (within 24 hours, or 6 or more days ahead) cannot be told apart from the display.

### Output Examples

```text
my-project | main ↑2↓3 | c9b8fce 3+13-5 | my-session
✻ Opus 4.7∙high ▆ 72% | ▇▇▇▆▆▆▅▅▄▄▃▃ 35% - 18:30 | ▅ Thu
```

```text
my-project | main ↑2↓3 #12✓ 3 | c9b8fce 3+13-5 | my-session
✻ Opus 4.7∙high ▆ 72% | ▇▇▇▆▆▆▅▅▄▄▃▃ 35% - 18:30 | ▅ Thu
```

```text
✻ Opus 4.7∙high ▄ | ▇▇▇▆▆▆▆▅▅▅▄▄ 18:30 | ▂ 22% - Thu
```

```text
✻ Unknown · -- | ············ -- | · --
```

The first is the default display with rate in the warning range and weekly at 62%.
The second is the `PR_STATUS=1` display, which adds the PR status (`#12✓ 3`) to the first.
The third is the display with weekly in the warning range (22%).
The fourth is the output when an empty JSON (`{}`) is passed with no rate history (if history exists, the chart part would be the saved history). All line 1 elements are empty, so there is only one line.

## Trimming Rules

| Element | Limit | When exceeded |
| --- | --- | --- |
| Model name | 13 characters | First 12 characters + `…` |
| Branch name | 25 characters | See below |
| Session name | 40 characters | First 39 characters + `…` |
| Directory name | 25 characters | First 24 characters + `…` |

The branch name is evaluated from the top in order.

| Condition | Result | Example |
| --- | --- | --- |
| 25 characters or fewer | Unchanged | `feature/new` |
| Contains `/`, and the part after the last `/` is 22 characters or fewer | First `25 - 1 - len("/<tail>")` characters + `…` + `/<tail>` | `feature/aaaaaaaaaaaaaaaaaaaa/yyy` → `feature/aaaaaaaaaaaa…/yyy` |
| Otherwise (no `/`, or the tail is 23 characters or more) | First 24 characters + `…` | `feature/improve-awesome-statusline` → `feature/improve-awesome-…` |

- 22 characters is the upper limit that still leaves at least one leading character (`1 + "…" + "/" + 22 = 25`)
- Even if the cut position falls right after a `/`, `…` follows as-is (the result can look like `feature/…/yyy`)

Common:

- `…` is U+2026
- In both versions, characters are counted per character under `LC_ALL=C.UTF-8`. CJK characters also count as one character
- Display width (CJK characters occupying 2 columns) is not considered
- effort, `<ab>`, and `<diff>` are not trimmed
- The commit hash is not trimmed. The number of digits is a value the user chose with `core.abbrev`, and cutting it would make it unusable as a hash

## Colors

The colors match Claude Code's light/dark themes. `COLOR_SCHEME` switches between `dark` (default) and `light`. Any value other than `light` is treated as `dark`.

All colors are truecolor foreground colors (`\033[38;2;R;G;Bm`), and `\033[0m` is appended at the end of a colored span.

Color is applied only where a color is deliberately specified (the rows in the table below whose color is not "uncolored"). All other elements are left uncolored and take the terminal and Claude Code foreground color.
Among the uncolored elements, those specified in [`HIGHLIGHT`](#highlight-highlight) are painted with `text`, only while they are uncolored.

### Color Thresholds

The RGB values are for dark. For the light values, see [Semantic Colors](#semantic-colors).

| Metric | Condition | Key | dark ANSI |
| --- | --- | --- | --- |
| ctx | 90% or more | `error` + blink | `\033[5m\033[38;2;255;107;128m` |
| | 80% or more | `claude` (orange) | `\033[38;2;215;119;87m` |
| | 70% or more | `warning` (yellow) | `\033[38;2;255;193;7m` |
| | Less than 70% | Uncolored | — |
| rate / weekly remaining | 5% or less | `error` + blink | `\033[5m\033[38;2;255;107;128m` |
| | 15% or less | `claude` (orange) | `\033[38;2;215;119;87m` |
| | 40% or less | `warning` (yellow) | `\033[38;2;255;193;7m` |
| | Over 40% | Uncolored | — |
| model | Name contains `Fable` | `autoAccept` (purple) | `\033[38;2;175;135;255m` |
| | Name contains `Opus` | `claude` (orange) | `\033[38;2;215;119;87m` |
| | Name contains `Haiku` | `subagent_cyan` (cyan) | `\033[38;2;8;145;178m` |
| | Other (Sonnet, etc.) | Uncolored | — |
| effort | `low` | `warning` (yellow) | `\033[38;2;255;193;7m` |
| | `medium` | `success` (green) | `\033[38;2;78;186;101m` |
| | `high` | `permission` (blue) | `\033[38;2;177;185;249m` |
| | `xhigh` | `autoAccept` (purple) | `\033[38;2;175;135;255m` |
| | `max` | Rainbow | [Rainbow Palette](#rainbow-palette) |
| ahead `↑N` | — | `professionalBlue` (blue) | `\033[38;2;106;155;204m` |
| behind `↓M` | — | `warning` (yellow) | `\033[38;2;255;193;7m` |
| `*` | No upstream set | `professionalBlue` (blue) | `\033[38;2;106;155;204m` |
| | detached HEAD | Uncolored | — |
| diff file count | — | `text` | `\033[38;2;255;255;255m` |
| diff `+N` | — | `success` (green) | `\033[38;2;78;186;101m` |
| diff `-N` | — | `error` (red) | `\033[38;2;255;107;128m` |
| pr `#<number>` | open + approved | `success` (green) | `\033[38;2;78;186;101m` |
| | open + pending | `permission` (blue-violet) | `\033[38;2;177;185;249m` |
| | open + changes requested | `error` (red) | `\033[38;2;255;107;128m` |
| | draft | Uncolored | — |
| | merged | `merged` (purple) + strikethrough | `\033[4;9m\033[38;2;135;0;255m` |
| | closed | Uncolored + strikethrough | `\033[4;9m` |
| pr CI symbol | `✓` | `success` (green) | `\033[38;2;78;186;101m` |
| | `✗` | `error` (red) | `\033[38;2;255;107;128m` |
| | `●` | `warning` (yellow) | `\033[38;2;255;193;7m` |
| pr comment count | — | Uncolored | — |
| Element specified in `HIGHLIGHT` | While uncolored | `text` | `\033[38;2;255;255;255m` |

- pr `#<number>` is underlined (`\033[4m`) regardless of state. It is placed before the color's ESC in the table above (for merged / closed, combined with the strikethrough as `\033[4;9m`)

- ctx, rate, and weekly have three levels: caution (yellow) → danger (orange) → critical (red + blink). The critical level is distinguished from the danger level by the blink attribute (`\033[5m`)
- The model decision uses substring matching and evaluates in the order `Fable` → `Opus` → `Haiku`. It does not depend on the version notation (`Fable 5 (1M context)` is also purple)
- ultracode cannot be distinguished from `xhigh` in the input, so it gets the same purple as `xhigh`
- The rainbow for `max` applies only to the effort word, not to `∙`

### Semantic Colors

All colors of both schemes. Only some are used in the current display; the rest are defined for future use. `subagent_*` correspond to the colors for Claude Code's subagents.

| Key | dark RGB | dark | light RGB | light |
| --- | --- | --- | --- | --- |
| `autoAccept` | `175;135;255` | #AF87FF | `135;0;255` | #8700FF |
| `bashBorder` | `253;93;177` | #FD5DB1 | `255;0;135` | #FF0087 |
| `claude` | `215;119;87` | #D77757 | `215;119;87` | #D77757 |
| `permission` | `177;185;249` | #B1B9F9 | `87;105;247` | #5769F7 |
| `secondaryBorder` | `136;136;136` | #888888 | `153;153;153` | #999999 |
| `text` | `255;255;255` | #FFFFFF | `0;0;0` | #000000 |
| `secondaryText` | `153;153;153` | #999999 | `102;102;102` | #666666 |
| `suggestion` | `177;185;249` | #B1B9F9 | `87;105;247` | #5769F7 |
| `remember` | `177;185;249` | #B1B9F9 | `0;0;255` | #0000FF |
| `success` | `78;186;101` | #4EBA65 | `44;122;57` | #2C7A39 |
| `error` | `255;107;128` | #FF6B80 | `171;43;63` | #AB2B3F |
| `warning` | `255;193;7` | #FFC107 | `150;108;30` | #966C1E |
| `diff_added` | `34;92;43` | #225C2B | `105;219;124` | #69DB7C |
| `diff_removed` | `122;41;54` | #7A2936 | `255;168;180` | #FFA8B4 |
| `diff_addedDimmed` | `71;88;74` | #47584A | `199;225;203` | #C7E1CB |
| `diff_removedDimmed` | `105;72;77` | #69484D | `253;210;216` | #FDD2D8 |
| `diff_addedWord` | `56;166;96` | #38A660 | `47;157;68` | #2F9D44 |
| `diff_removedWord` | `179;89;107` | #B3596B | `209;69;75` | #D1454B |
| `diff_addedWordDimmed` | `46;107;58` | #2E6B3A | `144;194;156` | #90C29C |
| `diff_removedWordDimmed` | `139;57;69` | #8B3945 | `232;165;173` | #E8A5AD |
| `planMode` | `0;102;102` | #006666 | `51;102;102` | #336666 |
| `effortUltra` | `135;0;255` | #8700FF | `135;0;255` | #8700FF |
| `rate_limit_fill` | `87;105;247` | #5769F7 | `51;102;255` | #3366FF |
| `rate_limit_empty` | `39;47;111` | #272F6F | `23;46;114` | #172E72 |
| `claudeShimmer` | `245;149;117` | #F59575 | `255;183;101` | #FFB765 |
| `permissionShimmer` | `137;155;255` | #899BFF | `101;152;255` | #6598FF |
| `warningShimmer` | `200;158;80` | #C89E50 | `255;183;50` | #FFB732 |
| `professionalBlue` | `106;155;204` | #6A9BCC | `106;155;204` | #6A9BCC |
| `chromeYellow` | `251;188;4` | #FBBC04 | `251;188;4` | #FBBC04 |
| `subtle` | `175;175;175` | #AFAFAF | `175;175;175` | #AFAFAF |
| `inactive` | `102;102;102` | #666666 | `102;102;102` | #666666 |
| `merged` | `135;0;255` | #8700FF | `135;0;255` | #8700FF |
| `fastMode` | `255;106;0` | #FF6A00 | `255;106;0` | #FF6A00 |
| `fastModeShimmer` | `255;150;50` | #FF9632 | `255;150;50` | #FF9632 |
| `subagent_red` | `220;38;38` | #DC2626 | `204;0;0` | #CC0000 |
| `subagent_orange` | `217;119;87` | #D97757 | `255;128;0` | #FF8000 |
| `subagent_yellow` | `202;138;4` | #CA8A04 | `255;204;0` | #FFCC00 |
| `subagent_green` | `22;163;74` | #16A34A | `0;204;0` | #00CC00 |
| `subagent_cyan` | `8;145;178` | #0891B2 | `0;178;178` | #00B2B2 |
| `subagent_blue` | `106;155;204` | #6A9BCC | `0;102;204` | #0066CC |
| `subagent_purple` | `130;125;189` | #827DBD | `128;0;128` | #800080 |
| `subagent_pink` | `196;102;134` | #C46686 | `255;102;178` | #FF66B2 |

Blinking (`\033[5m`) is not a color but an ANSI attribute, layered independently of the table above.

### Rainbow Palette

Exclusively for effort `max`. Fixed regardless of `COLOR_SCHEME`. The i-th character (0-based) is assigned the palette color number `i mod 7` (no interpolation).

| # | RGB | hex |
| --- | --- | --- |
| 0 | `235;95;87` | #EB5F57 |
| 1 | `245;139;87` | #F58B57 |
| 2 | `250;195;95` | #FAC35F |
| 3 | `145;200;130` | #91C882 |
| 4 | `130;170;220` | #82AADC |
| 5 | `155;130;200` | #9B82C8 |
| 6 | `200;130;180` | #C882B4 |

## Rate Limit History

Only the remaining rate limit is kept in history (ctx is not).

| Constant | Value | Purpose | Changeable |
| --- | --- | --- | --- |
| `RATE_CHART_LEN` | `12` | Number of chart characters (number of entries used for display) | Yes, in conf (2–20) |
| `RATE_CHART_LEN_MAX` | `20` | Number of entries kept in the history file (upper bound of `RATE_CHART_LEN`) | No (ignored if written in conf) |
| `POLL_INTERVAL_SEC` | `300` | Minimum interval for appending to history (seconds) | Yes, in conf (60–18000 ÷ `RATE_CHART_LEN`) |
| `LOCK_TIMEOUT_SEC` | `2` | Upper limit for waiting on the history file lock (seconds) | No |

- History is stored in a single file shared by all sessions (`<HISTORY_DIR>/rate`)
- The first time, 20 entries (`RATE_CHART_LEN_MAX`) are filled with the current value. After that, one entry is appended if at least `POLL_INTERVAL_SEC` seconds have passed since the previous append, and only the last 20 are kept
- The number of stored entries is 20 regardless of the display length, and the chart uses the last `RATE_CHART_LEN` entries.
  If the chart length is increased, the saved history is reflected in the display immediately (missing entries show as `·` and are filled in with each append).
  A history file with fewer entries than the stored count can also be used as-is
- If the lock cannot be acquired within `LOCK_TIMEOUT_SEC` seconds, no append is done for that render (rendering continues)
- The default `HISTORY_DIR` is `/tmp/claude-statusline-<uid>/`. It can be changed with the env `CLAUDE_STATUSLINE_HISTORY_DIR` (not available in conf)
- If `HISTORY_DIR` is a symlink, is not owned by the current uid, or does not have mode 700, the history feature is disabled and rendering continues

### Recommended Throttling Interval Ranges

Numeric settings (`RATE_CHART_LEN`, `POLL_INTERVAL_SEC`, `GIT_FETCH_INTERVAL_SEC`) have no env override and are changed in conf. Out-of-range values are rounded at startup with no warning.

| Value | Handling |
| --- | --- |
| Empty, or contains non-digits (including negative values) | Default (`12` / `300` / `900`) |
| 9 or more digits | Upper limit |
| Below the lower limit (including `0`) | Lower limit (`2` / `60` / `60`) |
| Above the upper limit | Upper limit |
| Leading 0 (`08`) | Treated as decimal (`8`) |

| Constant | Range | Rationale for the lower limit | Rationale for the upper limit |
| --- | --- | --- | --- |
| `RATE_CHART_LEN` | 2–20 | One history character + one current-value character. With 1, only the current value would remain and no progression would be shown | The longest possible line 2 (model name 13 characters, effort `medium`, ctx `█ 100%`, rate and weekly both in the warning range with time and weekday) is `58 + RATE_CHART_LEN` columns, so 20 gives 78 columns. It fits an 80-column terminal |
| `POLL_INTERVAL_SEC` | 60–(18000 ÷ `RATE_CHART_LEN`, integer division) | The statusline is called every few seconds to a dozen or so seconds, so anything shorter would update the history on every call and defeat the throttling | The interval at which the whole chart (`RATE_CHART_LEN` samples) covers the 5-hour (18000-second) window. Beyond it the chart no longer shows the trend. With the default chart length of 12 it is 1500; for 2 it is 9000, for 6 it is 3000, and for 20 it is 900 |
| `GIT_FETCH_INTERVAL_SEC` | 60–1800 | Anything shorter makes `git fetch` child processes too frequent. Throttling is counted per cwd, so the more worktrees of the same repository are open, the larger the total number of fetches | Beyond 30 minutes, the automatic refresh of `↓behind` is slow and not much different from a manual fetch |

## Configuration

### Display Constants

| Constant | Default | env | Value |
| --- | --- | --- | --- |
| `SHOW_MODEL_NAME` | `1` | `CLAUDE_STATUSLINE_SHOW_MODEL_NAME` | `1` shows the model name. Anything else hides it (`✻` remains) |
| `COLOR_SCHEME` | `dark` | `CLAUDE_STATUSLINE_COLOR_SCHEME` | `light` selects light. Anything else is dark |
| `SHOW_CWD` | `1` | `CLAUDE_STATUSLINE_SHOW_CWD` | `1` shows the directory column. Anything else hides it |
| `GIT_FETCH` | `0` | `CLAUDE_STATUSLINE_GIT_FETCH` | `1` enables background fetch. Anything else disables it |
| `PR_STATUS` | `0` | `CLAUDE_STATUSLINE_PR_STATUS` | `1` shows the [PR status](#pr-status-pr_status1) in the branch column. Anything else disables it |
| `LAYOUT_LINE1` | `directory\|branch\|commit\|session` | `CLAUDE_STATUSLINE_LAYOUT_LINE1` | [Layout](#layout-layout_line1--layout_line2) |
| `LAYOUT_LINE2` | `model_ctx\|rate\|weekly` | `CLAUDE_STATUSLINE_LAYOUT_LINE2` | [Layout](#layout-layout_line1--layout_line2) |
| `HIGHLIGHT` | `branch` | `CLAUDE_STATUSLINE_HIGHLIGHT` | [Highlight](#highlight-highlight) |
| `RATE_CHART_LEN` | `12` | None | Number of rate chart characters. [Recommended ranges](#recommended-throttling-interval-ranges) |
| `POLL_INTERVAL_SEC` | `300` | None | [Recommended ranges](#recommended-throttling-interval-ranges) |
| `GIT_FETCH_INTERVAL_SEC` | `900` | None | [Recommended ranges](#recommended-throttling-interval-ranges) |

### Precedence and Configuration File

The precedence is **env (`CLAUDE_STATUSLINE_*`) > configuration file > default**. When the value of an env variable or of the configuration file is an empty string, it is treated as not specified.

Configuration file:

- The default path is `~/.claude/statusline.conf`. It can be replaced with the env `CLAUDE_STATUSLINE_CONFIG`
- It is loaded as a shell script (sourced with `.`). Write the short names (`COLOR_SCHEME=light`, etc.) as variable assignments
- It is loaded only when it is a regular file and is readable. Otherwise (does not exist, no permission, is a directory) it is silently ignored
- Before loading, the 11 short names in the table above are unset, so variables of the same name in the outside environment have no effect
- After loading, the trailing `\r` is removed from the 11 values (so a file saved with CRLF gives the same result)
- Internal constants such as `RATE_CHART_LEN_MAX` have no effect even if written, because they are redefined after loading
- For numeric settings, [rounding](#recommended-throttling-interval-ranges) is applied after loading

The distributed template [`statusline.conf`](../statusline.conf) lists every item with its default value.

### Layout (`LAYOUT_LINE1` / `LAYOUT_LINE2`)

Tokens are written separated by `|`. Tokens are always joined with ` | `.

| Line | Token | Content |
| --- | --- | --- |
| Line 1 | `directory` | Directory name |
| | `branch` | `<branch>[ <ab>][ <pr>]` |
| | `commit` | `[<hash> ]<diff>` |
| | `session` | Session name |
| Line 2 | `model_ctx` | `✻ <model>∙<effort> <ctx>` |
| | `rate` | 5-hour rate limit |
| | `weekly` | Weekly (7-day) rate limit |

Common:

- Whitespace (spaces, tabs) around a token is ignored
- Tokens that cannot be used on that line (unknown ones, or ones belonging to the other line) are ignored
- If the same token appears more than once, only the first is taken
- If the value is an empty string, the default is used
- Elements bundled into one token (`model` and `ctx`, the branch name with `<ab>` / `<pr>`, the hash and `<diff>`) cannot be reordered individually

Line 1:

- Tokens that are not written are not output
- A token whose value is empty is omitted along with its column
- When there is no valid token, or all of them are empty, line 1 is not output (example: `LAYOUT_LINE1="none"`)
- `SHOW_CWD=0` has the same result as not writing `directory`

Line 2:

- Only the order of `model_ctx`, `rate`, and `weekly` can be changed
- Tokens that are not written are appended at the end in the default order. `LAYOUT_LINE2="rate"` becomes `rate | model_ctx | weekly`. `weekly` appears at the end even if it is not written
- A column is not omitted even if its value is empty. No token can be removed

### Highlight (`HIGHLIGHT`)

Among the elements displayed uncolored, the specified ones are painted with `text` (dark: white `255;255;255` / light: black `0;0;0`) to make them stand out. Tokens are written separated by `|`.

```bash
HIGHLIGHT="directory|branch|session|rate_chart|rate_reset"
```

| Token | Element | Condition for being uncolored | Painted range |
| --- | --- | --- | --- |
| `directory` | Directory name | Always | The whole trimmed name |
| `branch` | Branch name | Always | The part after the last `/` of the displayed name. The whole name if there is no `/` |
| `commit` | Commit hash | Always | The whole hash (`<diff>` is not painted) |
| `session` | Session name | Always | The whole trimmed name |
| `model` | `✻ <model>` (`✻` when `SHOW_MODEL_NAME=0`) | The name contains none of `Fable` / `Opus` / `Haiku` (Sonnet, `Unknown`, etc.) | From `✻` through the trimmed model name |
| `ctx_chart` | ctx spark | Usage under 70%, or missing | The one spark character (the `·` of `· --` when missing) |
| `rate_chart` | rate chart | Remaining over 40%, or usage missing | The whole chart (`RATE_CHART_LEN` characters) |
| `rate_reset` | rate reset time | Remaining over 40% | `HH:MM` |
| `weekly_chart` | weekly spark | Remaining over 40%, or usage missing | The one spark character (the `·` of `· --` when missing) |
| `weekly_reset` | weekly reset weekday | Remaining over 40% | The weekday (`Mon`, etc.) |
| `pr_comments` | PR comment count | Always | The count |

Examples of the painted range for branch:

| Displayed branch name | Painted range |
| --- | --- |
| `main` | `main` |
| `HEAD` (detached HEAD) | `HEAD` |
| `feature/xxx/yyy` | `yyy` |
| `feature/aaaaaaaaaaaa…/yyy` (name with the middle omitted) | `yyy` |
| `feature/improve-awesome-…` (name trimmed keeping the beginning) | `improve-awesome-…` |
| `platform-infrastructure-…` (name cut before any `/`) | `platform-infrastructure-…` |
| `abcdefghijklmnopqrstuvw/…` (name cut right after a `/`) | `…` |

- In a state where a color is applied, only that color is used and highlighting has no effect.
  This applies to ctx usage of 70% or more, rate / weekly remaining of 40% or less (the whole `<chart> NN% - HH:MM` takes the threshold color), and Fable / Opus / Haiku models
- Separators and whitespace are handled the same as in the [Layout](#layout-layout_line1--layout_line2).
  Whitespace (spaces, tabs) around a token is ignored, and unknown tokens are silently ignored. Writing the same token more than once is the same as writing it once
- The default is `branch`, which paints only the end of the branch name. To paint no element, write only an unknown token such as `none` (an empty value is treated as the default)
- In the configuration file the value contains `|`, so enclose it in quotes. Without quotes it is interpreted as a pipe, `command not found` is printed on every render, and `HIGHLIGHT` is not set either
- Making the env `CLAUDE_STATUSLINE_HIGHLIGHT` empty does not clear the value in the configuration file (an empty env is treated as not specified). To temporarily paint nothing through env, pass an unknown token such as `none`
- Painting happens after trimming. The trim position does not change with or without highlighting
- An element whose value is empty is not painted. An empty column on line 1 is omitted entirely even if a highlight is specified
- Whether an element is shown is independent of highlighting. An element not written in `LAYOUT_LINE*`, or one hidden by `SHOW_CWD=0`, is not shown even if specified
- The output has the same form as other colored elements: `\033[38;2;R;G;Bm<text>\033[0m`

The following uncolored elements are not targets.

| Element | Reason |
| --- | --- |
| `NN%` and ` - ` of ctx / rate / weekly | They are shown only in a state where a color is applied |
| effort | All known values (`low` through `max`) are colored. Only an unexpected value is uncolored |
| `*` of a detached HEAD | Being uncolored distinguishes it from the blue `*` of no upstream |
| `#<number>` of a PR that is draft / closed | Being uncolored distinguishes it from the colored number of open and from the purple of merged |
| `--` when missing, and `·` of a clean `<diff>` | Not values but marks meaning missing or unchanged |
| The branch name up to the last `/` | Only the end, which often describes the work, is made to stand out |
| ` \| `, `∙`, and the spaces between elements | Separators, not elements |

> [!WARNING]
> `text` is a fixed color decided by `COLOR_SCHEME`, so if `COLOR_SCHEME` does not match the Claude Code theme it becomes unreadable (using `dark` on a light background puts white text on a white background).
> Set `COLOR_SCHEME` to match the Claude Code theme. The diff file count uses the same color.

## Background Fetch (`GIT_FETCH=1`)

Only when `GIT_FETCH=1`, `git fetch --quiet` is started in the background to bring `↓behind` closer to the latest. With `GIT_FETCH=0` (default), no fetch is done at all and the network is not accessed.

- Rendering does not wait for the fetch to finish. The fetch result is reflected in `<ab>` of subsequent renders
- It is not started if less than `GIT_FETCH_INTERVAL_SEC` seconds have passed since the last start. The interval is counted per `workspace.current_dir` (a different subdirectory or worktree of the same repository is counted separately)
- It is not started in these cases: the branch cannot be obtained (outside git), detached HEAD, no upstream set, or `HISTORY_DIR` is invalid
- It never asks for authentication input (`GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=/bin/true`, `SSH_ASKPASS=/bin/true`, `SSH_ASKPASS_REQUIRE=force`). For a remote without credentials, the fetch fails silently and `↓behind` is not updated
- The fetch's own output is discarded and never mixes into the statusline. The only difference `GIT_FETCH` makes is that updated remote-tracking branches are reflected in `<ab>` on subsequent renders

## PR Status (`PR_STATUS=1`)

Only when `PR_STATUS=1`, the GitHub PR linked to the current branch is shown in `<pr>` of the branch column. The information is obtained by starting `gh api graphql` in the background, and rendering only reads the cache.

- With `PR_STATUS=0` (default), `gh` is never started and the network is not accessed
- Even with `PR_STATUS=1`, `gh` is not started if `LAYOUT_LINE1` has no `branch`
- When the value is empty, neither `<pr>` nor the preceding space is output. The branch column itself remains
- The environment variable `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is not checked. The fetch is performed even if it is set

### Display Format

```text
#<number>[<CI symbol>][ <count>]
```

| State | Color of `#<number>` | Decoration | CI symbol | Comment count |
| --- | --- | --- | --- | --- |
| open: approved | `success` | Underline (SGR 4) | Shown | Shown |
| open: pending (awaiting review, or no review yet) | `permission` | Underline (SGR 4) | Shown | Shown |
| open: changes requested | `error` | Underline (SGR 4) | Shown | Shown |
| draft | Uncolored | Underline (SGR 4) | Shown | Shown |
| merged | `merged` | Underline + strikethrough (SGR 4;9) | Not shown | Not shown |
| closed (closed without merging) | Uncolored | Underline + strikethrough (SGR 4;9) | Not shown | Not shown |

- The prefix `PR` is not added (`#12`)
- Colors use the values of the existing color definitions ([Semantic Colors](#semantic-colors)). draft and closed are not colored and take the terminal foreground color.
  The decoration is `\033[4m` (`\033[4;9m` for merged / closed) placed before the color and cleared with `\033[0m`. The decoration applies only to `#<number>`, not to the CI symbol or the comment count
- The CI symbol follows `#<number>` directly with no separator (`#12✓`)
- `<pr>` is not trimmed

The review state is decided by `reviewDecision`. In a repository that does not require reviews, `reviewDecision` is always `null` even when approved, so when it is `null` the state is decided from `latestReviews` (each reviewer's latest review).

| `reviewDecision` | `latestReviews` | Review state |
| --- | --- | --- |
| `APPROVED` | (not checked) | approved |
| `CHANGES_REQUESTED` | (not checked) | changes requested |
| `REVIEW_REQUIRED` | (not checked) | pending |
| Anything else (`null`, etc.) | At least one `CHANGES_REQUESTED` | changes requested |
| | Not the above, and at least one `APPROVED` | approved |
| | Neither | pending |

The CI symbol is decided from the `statusCheckRollup.state` of the PR's head commit (the value with which GitHub aggregates all checks, the same as the check display on the PR page).

| `statusCheckRollup.state` | Symbol | Color |
| --- | --- | --- |
| `SUCCESS` | `✓` | `success` |
| `FAILURE` / `ERROR` | `✗` | `error` |
| `PENDING` / `EXPECTED` | `●` | `warning` |
| `null` (no checks at all), etc. | Not shown | — |

Comment count:

- The PR's `totalCommentsCount` (the comment count computed by GitHub) is used as-is. It is the same value as the number on the speech-bubble icon in GitHub's PR list, and is the total of the following
  - Comments in the conversation tab
  - Comments on lines of code (including replies to threads)
  - Reviews with a body
- Counting is left to GitHub; there is no filtering by author and no recounting
- No symbol is added; only the number is output, after one space. If there is a CI symbol it goes after that (`#12✓ 3`), otherwise after the number (`#12 3`).
  Without the space, the number would read as a continuation of the PR number when there is no CI symbol (`#123`)
- When the count is 0, neither the count nor the preceding space is output (`#12✓`). No rounding such as `99+` is done; the number is output as-is
- Uncolored. When `pr_comments` is listed in `HIGHLIGHT`, it is painted with `text` ([Highlight](#highlight-highlight))

Link:

- Only the `#<number>` part (including its color and decoration) is wrapped in OSC 8 to make a link to the PR URL (`\033]8;;<url>\a` … `\033]8;;\a`). The CI symbol and the comment count are not included in the link
- When the environment variable `FORCE_HYPERLINK` is `0`, OSC 8 is not output
- It cannot be clicked in terminals that do not support OSC 8

### Target PR

- The repository to query (the base repository) is left to `gh`'s own resolution (`{owner}` / `{repo}` of `gh api`)
- The head branch name and owner are decided from the push destination
  - Branch name: the `<branch>` of `<remote>/<branch>` from `git rev-parse --abbrev-ref '@{push}'`
  - Owner: the `<owner>` of the URL from `git remote get-url --push <remote>` (`git@host:owner/repo.git`, `https://host/owner/repo(.git)`, `ssh://git@host/owner/repo`)
- When the push destination cannot be obtained (not pushed yet), the local branch name and the owner of the base repository are used. The owner of the base repository is also used when the owner cannot be taken from the URL
- The 10 newest PRs for the head branch name are fetched, only those whose `headRepositoryOwner` matches the head owner (case-insensitive) are kept as candidates, and one is chosen in this order
  1. The newest `OPEN` one
  2. Otherwise, the newest `MERGED` / `CLOSED` one whose `headRefOid` matches the local HEAD
  3. If neither exists, no PR

### When Nothing Is Shown

`<pr>` is treated as empty in any of the following cases.

- The branch cannot be obtained (outside git), or it is a detached HEAD
- There is no cache yet (such as the first render right after switching branches)
- There is no PR
- More than `PR_STALE_SEC` (1800 seconds) have passed since the last successful fetch. This happens when fetching keeps failing because `gh` is unauthenticated, offline, the remote is not GitHub, the base repository cannot be determined, and so on
- The fetch time in the cache is in the future (such as after the clock was set back). It is replaced by the result of the next fetch
- The cache is corrupt (any of the number of fields, `fetched_at`, the number, or the state is invalid)
- `HISTORY_DIR` is invalid
- `gh` is not installed

No message is shown to guide the user about `gh`. If a field of the cache other than the number and the state has an unexpected value, that field is treated as absent (the review state is pending, and the CI symbol and the comment count are not shown).
The comment count is used only when, like the number, it is an integer of at most 9 digits with no leading 0.
If the URL does not start with `https://`, or contains a character other than ASCII alphanumerics and the symbols used in URLs (`._~:/?#=&+@%-`), it is not made into a link.

### Refresh

- Rendering only reads the cache and calls neither `gh` nor any additional `git`
- The cache is kept per pair of `workspace.current_dir` and local branch name (`<HISTORY_DIR>/pr-<key>`). Switching branches reads a different cache, so the PR of the previous branch is not shown
- If the following interval has passed since the last fetch attempt, a fetch is started in the background. The current render does not wait, and the result is reflected in subsequent renders

| State | Refetch interval |
| --- | --- |
| open / draft with CI running, or the local HEAD differs from the PR head | 30 seconds |
| open / draft not matching the above | 300 seconds |
| No PR | 300 seconds |
| merged / closed | 900 seconds |
| The previous attempt failed, or there is no cache (second and later attempts) | 300 seconds |

- The intervals and `PR_STALE_SEC` are internal constants and cannot be changed from conf
- Whether the local HEAD matches the PR head is decided at fetch time. Rendering does not look at HEAD, so for a merged / closed PR the display remains until the next refetch (up to 900 seconds later), even if new commits are added to the same branch
- While a fetch is running, the next one is not started. If the in-progress marker is older than 90 seconds, it is removed as a trace of abnormal termination before starting
- A single `gh` run is cut off at 60 seconds. On failure (non-zero exit, cut off, unexpected output), the cache is not rewritten and the previous display remains
- The GraphQL cost of one query is 1 point. With the shortest interval of 30 seconds sustained, that is at most 120 queries per hour per cache
- It never asks for authentication or other input (`GH_PROMPT_DISABLED=1`, plus the same four git variables as in [Background Fetch](#background-fetch-git_fetch1)). It also suppresses update notices (`GH_NO_UPDATE_NOTIFIER=1`, `GH_NO_EXTENSION_UPDATE_NOTIFIER=1`)
- `GH_REPO`, `GH_FORCE_TTY`, and `CLICOLOR_FORCE` are not passed to `gh`. `GH_TOKEN`, `GITHUB_TOKEN`, `GH_HOST`, and `GH_ENTERPRISE_TOKEN` are passed through as-is

## Startup Checks and Fallback Output

When a requirement is missing, only the following single line is output and the script exits (exit code 0).

| Version | Condition | Output |
| --- | --- | --- |
| macOS version | `jq` is missing | `✻ -- (jq required: brew install jq)` |
| Linux version | bash is older than 4.1 | `✻ -- (bash 4.1+ required)` |
| Linux version | `jq` is missing | `✻ -- (jq required: sudo apt install jq)` |
| Linux version | `flock` is missing | `✻ -- (flock required: sudo apt install util-linux)` |

Both versions fix `LC_ALL=C.UTF-8` at the top. The way characters are counted and the display of UTF-8 characters (`✻`, `▁..█`, `…`, `↑↓`, `∙`) depend on this.

## Non-Goals

- **No setting is provided to go back to a one-line layout**. Line 1 is absent only when all line 1 elements are empty
- GitLab merge requests are not handled by the PR status display
- The PR badge in Claude Code's standard footer is not removed (it is displayed side by side with the PR status display, in a different place)
- Trimming based on display width (counting CJK as 2 columns) is not done
- `git fetch` is not run synchronously on every render
- No history chart is kept for ctx and weekly
- `rate_limits.spend_limit` (the usage cap of the Claude apps gateway) is not shown
- No setting is provided to remove the weekly column (no line 2 token can be removed)
- Localizing the weekday of weekly (such as `月`), and showing the time alongside it when the reset is near, are not done
- No env override is provided for `RATE_CHART_LEN`, `POLL_INTERVAL_SEC`, or `GIT_FETCH_INTERVAL_SEC` (the throttling of the history file shared by all sessions would vary per session)
- The configuration file is not JSON or YAML (shell variable assignments only)
