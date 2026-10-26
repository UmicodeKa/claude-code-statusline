English | [🗾 日本語はこちら](./README.md)

# claude-code-statusline

A set of scripts that customize the Claude Code status line. There is a macOS version (`statusline-macos.sh`) and a Linux version (`statusline-linux.sh`), and both print the same content.

> [!NOTE]
> This repository is an unofficial project and is not affiliated with Anthropic.

> [!NOTE]
> This repository is for personal use, and responses to Issues and Pull Requests are not guaranteed. Feel free to fork and modify it ([For developers](#for-developers)).

> [!NOTE]
> This page is a translation of [README.md](./README.md) (Japanese). If they differ, README.md is authoritative.
> The developer documents are also available in English: [DEVELOPMENT](docs/DEVELOPMENT.en.md), [SPEC](docs/SPEC.en.md), [DESIGN](docs/DESIGN.en.md) and [tests](tests/README.en.md).
> The Japanese versions are authoritative for those as well. The comments inside the scripts and tests are in Japanese.

## Overview

The status line is shown on two lines like this.

```text
my-project | main ↑2↓3 | c9b8fce 3+13-5 | my-session
✻ Opus 4.7∙high ▆ 72% | ▇▇▇▆▆▆▅▅▄▄▃▃ 35% - 18:30 | ▅ Thu
```

- Line 1: directory name / git branch (with the difference from the remote; [`PR_STATUS=1`](#showing-pr-status-with-pr_status1) also shows the GitHub PR status) / commit hash and the number of changed lines in the working tree / session name
- Line 2: model name and reasoning effort / context usage / trend of the 5-hour rate limit remaining and its reset time / weekly (7-day) rate limit remaining and the day of the week it resets

When context usage rises or the rate limit remaining drops, the color and the number tell you.

## Requirements

| Item | macOS version | Linux version |
| --- | --- | --- |
| OS | macOS | Linux with GNU coreutils (tested on Debian/Ubuntu) |
| bash | `/bin/bash` (3.2 or later) | 4.1 or later |
| Required commands | `jq` | `jq`, `flock` (part of util-linux) |
| Optional | `git` (2.22 or later) | `git` (2.22 or later) |
| Optional (`PR_STATUS=1`) | `gh` (latest) | `gh` (latest) |
| Locale | `C.UTF-8` (included in current macOS) | `C.UTF-8` (included in Debian 11 and later) |

- Without `git`, or outside a git repository, only the branch and commit columns are omitted and the rest is shown. A git older than 2.22 has no `git branch --show-current`, so it is treated the same as outside a git repository
- `gh` is needed only with `PR_STATUS=1`. It assumes the latest version (tested with 2.103)
- The login shell (zsh, etc.) does not matter
- Everything else uses only each OS's standard commands such as `awk`, `date`, `stat` and `mkdir`
- Colors are output as 24-bit color (truecolor). Use a terminal that supports truecolor

## Setup

Get the repository and run the following in that directory.

```bash
git clone https://github.com/UmicodeKa/claude-code-statusline.git
cd claude-code-statusline
mkdir -p ~/.claude
```

### macOS

1. Install the dependency (if not installed yet).

   ```bash
   brew install jq
   ```

2. Place the script.

   ```bash
   cp statusline-macos.sh ~/.claude/statusline.sh
   chmod +x ~/.claude/statusline.sh
   ```

3. Add the following to `~/.claude/settings.json`.

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh"
     }
   }
   ```

4. Restart Claude Code and the status line takes effect.

### Linux

1. Install the dependencies (if not installed yet).

   ```bash
   sudo apt install jq util-linux
   ```

2. Place the script.

   ```bash
   cp statusline-linux.sh ~/.claude/statusline.sh
   chmod +x ~/.claude/statusline.sh
   ```

3. Add the same `statusLine` setting as in step 3 for macOS to `~/.claude/settings.json`, and restart Claude Code.

## Customization

### Configuration file

Write settings in `~/.claude/statusline.conf` to change the behavior without editing the script. Without the file, the defaults are used.
The quickest way is to copy the template [`statusline.conf`](statusline.conf), which lists every option with its default, and edit only the lines you want to change.

```bash
cp statusline.conf ~/.claude/statusline.conf
```

```bash
COLOR_SCHEME=light
GIT_FETCH=1
LAYOUT_LINE1="session|directory|branch|commit"
```

| Setting | Default | Description |
| --- | --- | --- |
| `SHOW_MODEL_NAME` | `1` | `0` hides the model name and shows only `✻` (model-specific color) and the effort |
| `COLOR_SCHEME` | `dark` | Switches the color scheme between `dark` and `light` |
| `SHOW_CWD` | `1` | `0` hides the directory name on line 1 |
| `LAYOUT_LINE1` | `directory\|branch\|commit\|session` | Elements and order of line 1 |
| `LAYOUT_LINE2` | `model_ctx\|rate\|weekly` | Order of line 2 |
| `HIGHLIGHT` | `branch` | Which uncolored elements to emphasize ([details](#highlight)) |
| `GIT_FETCH` | `0` | `1` enables the background `git fetch` |
| `PR_STATUS` | `0` | `1` shows the PR status in the branch column ([details](#showing-pr-status-with-pr_status1)) |
| `RATE_CHART_LEN` | `12` | Number of characters in the rate limit chart (2-20) |
| `POLL_INTERVAL_SEC` | `300` | Interval for recording the rate limit history (seconds) |
| `GIT_FETCH_INTERVAL_SEC` | `900` | Minimum interval of the background `git fetch` (seconds) |

- Values are written as shell variable assignments of the form `NAME=value`
- Commands other than variable assignments are also executed on every render. A command that prints to stdout mixes that text into the statusline, and writing `exit` stops rendering.
  Putting spaces around `=`, as in `COLOR_SCHEME = light`, runs a command instead of assigning a variable
- An unreadable file (no permission, a directory, etc.) is ignored and the defaults are used
- See [SPEC](docs/SPEC.en.md) for the detailed behavior of each option

### Precedence

When the same setting is specified in several places, the order of precedence is environment variable > configuration file > default.

- The environment variable is `CLAUDE_STATUSLINE_<NAME>` (e.g. `CLAUDE_STATUSLINE_COLOR_SCHEME=light`). It is mainly for tests and temporary switching
- `RATE_CHART_LEN`, `POLL_INTERVAL_SEC` and `GIT_FETCH_INTERVAL_SEC` have no environment variable and can be changed only in the configuration file
- Write the short name (`COLOR_SCHEME`) in the configuration file. Writing the environment variable name there overwrites the value from the environment

### Layout

Write the elements (tokens) in `LAYOUT_LINE1` / `LAYOUT_LINE2` separated by `|`. Because of the `|`, quote the value in the configuration file (the same applies to `HIGHLIGHT`).

| Line | Token | Description |
| --- | --- | --- |
| Line 1 | `directory` | Directory name |
| Line 1 | `branch` | Branch name + difference from the remote (+ PR status with `PR_STATUS=1`) |
| Line 1 | `commit` | Commit hash + number of changed lines |
| Line 1 | `session` | Session name |
| Line 2 | `model_ctx` | Model name, effort and context usage |
| Line 2 | `rate` | 5-hour rate limit |
| Line 2 | `weekly` | Weekly (7-day) rate limit |

- Line 1 shows only the tokens you write. Without `commit`, neither the commit hash nor the changed lines are shown. Writing only unknown tokens, such as `LAYOUT_LINE1="none"`, removes line 1 entirely
- On line 2 only the order can be changed. Tokens you omit are appended at the end, so all three are always shown (`weekly` appears at the end even if you do not write it)
- There is no setting to go back to a one-line layout

### Highlight

Among the elements that are shown in the terminal's foreground color without any color, such as the directory name and the branch name, those listed in `HIGHLIGHT` are painted with the text color of `COLOR_SCHEME`
(white for dark, black for light) to stand out. Separate the tokens with `|`.

```bash
HIGHLIGHT="directory|branch|session|rate_chart|rate_reset"
```

| Token | Element painted |
| --- | --- |
| `directory` | Directory name |
| `branch` | The part of the branch name after the last `/` (`yyy` for `feature/xxx/yyy`) |
| `commit` | Commit hash (the changed lines are not painted) |
| `session` | Session name |
| `model` | `✻` and the model name (for models without a color, such as Sonnet) |
| `ctx_chart` | Context usage spark |
| `rate_chart` / `rate_reset` | 5-hour rate limit chart / reset time |
| `weekly_chart` / `weekly_reset` | Weekly rate limit spark / day of the week it resets |
| `pr_comments` | Number of PR comments |

- An element that already has a color keeps it, such as ctx or the rate limit in a warning level, or a model color like Opus
- The default is `branch` (only the end of the branch name). To paint nothing, write only an unknown token such as `HIGHLIGHT="none"` (unknown tokens are ignored, and an empty value falls back to the default)
- Keep `COLOR_SCHEME` matched to the Claude Code theme. If they differ, the text becomes unreadable, for example white text on a light background
- Emptying the environment variable `CLAUDE_STATUSLINE_HIGHLIGHT` does not clear the value from the configuration file. To disable it temporarily, pass an unknown token such as `none`

### Range of numeric settings

`RATE_CHART_LEN` is 2-20 characters, `POLL_INTERVAL_SEC` is 60-(18000 ÷ `RATE_CHART_LEN`) seconds (60-1500 with the default chart length of 12), and `GIT_FETCH_INTERVAL_SEC` is 60-1800 seconds.
A value outside the range (including `0`) is clamped to the nearest boundary, and an empty, negative or non-numeric value falls back to the default (no warning is shown). See [SPEC](docs/SPEC.en.md) for the rationale of the ranges.

The upper limit of `POLL_INTERVAL_SEC` is the interval at which the whole chart covers the 5-hour rate limit window. A shorter chart allows a longer interval, and a longer chart covers the 5 hours in finer steps.

### Notes on using `GIT_FETCH=1`

By default `↑ahead↓behind` shows the difference as of the last `git fetch` / `git pull` and does not access the network.
With `GIT_FETCH=1`, `git fetch` runs in a background process separate from rendering, and `↓behind` is refreshed in later renders. The fetch is throttled to once per `GIT_FETCH_INTERVAL_SEC` (15 minutes by default) for each current directory.

The background fetch never shows an authentication prompt. This avoids passphrase or host key prompts interrupting the Claude Code screen. In the following cases the fetch fails silently and `↓behind` is not updated.

- On an SSH remote, the key has a passphrase and is not registered in ssh-agent
- The host key is not in `known_hosts` (first connection) or has changed
- On an HTTPS remote, no credentials are stored in the credential helper

To use the automatic refresh, register the key in ssh-agent beforehand with `ssh-add`, or set up a credential helper.

### Showing PR status with `PR_STATUS=1`

With `PR_STATUS=1`, the GitHub PR linked to the current branch is shown at the end of the branch column (right of the difference from the remote), separated by a space. By default (`0`) it is not shown and `gh` is not used to query GitHub.

```bash
PR_STATUS=1
```

```text
my-project | feature/login ↑1 #12✓ 3 | c9b8fce 3+10-2 | my-session
```

- `#12` is underlined and its color shows the PR state (approved green, awaiting review blue-violet, changes requested red, draft uncolored, merged purple + strikethrough, closed uncolored + strikethrough)
- `✓` / `✗` / `●` mean CI succeeded / failed / running, and follow `#12`. Nothing is shown if there are no checks
- The trailing `3` is the number of PR comments (conversation, line comments and their replies, and reviews with a body). It is the same number as the speech-bubble icon in the GitHub PR list, and is not shown for 0
- Nothing is shown if there is no PR or it cannot be fetched
- Removing `branch` from `LAYOUT_LINE1` also stops the PR from being shown, and `gh` is not started

Preparation:

1. Install the latest `gh` (`brew install gh` / [Linux](https://github.com/cli/cli#installation))
2. Authenticate with `gh auth login`
3. When there are several remotes, such as in a fork setup, run `gh repo set-default` in the repository to choose which one PRs are queried from (if it is not set, the fetch fails and nothing is shown)

Behavior:

- The fetch runs in the background and rendering does not wait for it. So nothing is shown for the first few renders right after switching, and it appears from the first render after the fetch completes
- The statusline is updated only when Claude Code has an event. To reflect things like CI completion while idle, add `"refreshInterval": 30` to `statusLine` in `~/.claude/settings.json`.
  Rendering only reads the cache, so re-running every 30 seconds adds little load
- The refetch interval is 30-900 seconds depending on the state. One query costs 1 point of the GitHub API GraphQL budget, from the same allowance as other `gh` usage (5000 points per hour)
- `#12` is an OSC 8 link, and on supporting terminals (iTerm2, etc.) Cmd+click / Ctrl+click opens the PR. Terminal.app does not support OSC 8, so it is not clickable.
  Over SSH or tmux the escape sequence may be dropped and it will not be a link. The environment variable `FORCE_HYPERLINK=0` turns the link off
- It is shown in a different place from the PR badge in Claude Code's standard footer, so both may appear side by side. The standard badge may not update when you switch PRs in the same session, but this one always shows the PR of the current branch
- Remotes other than GitHub (GitLab, etc.) are not supported

## What is displayed

| Element | Description |
| --- | --- |
| Directory name | Name of the current directory. Truncated with `…` beyond 25 characters |
| Branch name | git branch name. Truncated with `…` beyond 25 characters. If the part after the last `/` is 22 characters or fewer, it is kept and the middle is truncated (`feature/improve-sta…/trim`). `HEAD` for a detached HEAD |
| `↑N↓M` | Difference from the remote-tracking branch. `↑` is waiting to be pushed, `↓` is waiting to be pulled. Not shown when in sync |
| `*` | No remote-tracking branch (blue) / detached HEAD (uncolored) |
| `#12✓ 3` | PR number, CI and number of comments (only with `PR_STATUS=1`) |
| Commit hash | Short hash of HEAD. The length follows git's `core.abbrev` and is never truncated. Not shown in a repository with no commits yet |
| `3+13-5` | Changes in the working tree (files / added lines / deleted lines). Includes untracked files. `·` if there are no changes |
| Session name | Shown only when set. Truncated with `…` beyond 40 characters |
| `✻ model name` | Shown in the model-specific color. Truncated with `…` beyond 13 characters |
| effort | Reasoning effort (`low` / `medium` / `high` / `xhigh` / `max`). Not shown for models that do not support it |
| Context usage | One-character bar (`▁` to `█`). The number is added at 70% or more |
| Rate limit | The trend of the 5-hour window remaining as a bar of `RATE_CHART_LEN` characters (12 by default), whose rightmost character is always the current value. The number is added at 40% remaining or less, followed by the reset time |
| Weekly limit | The 7-day window remaining as a one-character bar, followed by the day of the week it resets (`Sun` to `Sat`). The number is added at 40% remaining or less. `· --` if there is no value |

- An element with no value is omitted together with its separator. If every element on line 1 is missing, line 1 is not shown at all. Elements on line 2 are not omitted even without a value
- The rate limit history is shared by all sessions

### Examples

Normal (no warnings, no changes):

```text
my-project | main | c9b8fce · | my-session
✻ Opus 4.7∙high ▄ | ▇▇▇▆▆▆▆▅▅▅▄▄ 18:30 | ▅ Thu
```

Branch with changes and a PR (`PR_STATUS=1`), context and rate limit in the warning range:

```text
my-project | main ↑2↓3 #12✓ 3 | c9b8fce 3+13-5 | my-session
✻ Opus 4.7∙high ▆ 72% | ▇▇▇▆▆▆▅▅▄▄▃▃ 35% - 18:30 | ▅ Thu
```

Weekly limit in the warning range (22% remaining):

```text
my-project | main | c9b8fce · | my-session
✻ Opus 4.7∙high ▄ | ▇▇▇▆▆▆▆▅▅▅▄▄ 18:30 | ▂ 22% - Thu
```

Long names are truncated (the commit hash and changed lines are not truncated):

```text
my-project | feature/improve-sta…/trim | c9b8fce 1+8 | my-project-refactoring-and-cleanup-work…
✻ Opus 4.7∙high ▄ | ▇▇▇▆▆▆▆▅▅▅▄▄ 18:30 | ▅ Thu
```

`SHOW_MODEL_NAME=0`:

```text
my-project | main | c9b8fce · | my-session
✻ xhigh ▄ | ▇▇▇▆▆▆▆▅▅▅▄▄ 18:30 | ▅ Thu
```

Outside a git repository and without a session name:

```text
my-project
✻ Opus 4.7∙high ▄ | ▇▇▇▆▆▆▆▅▅▅▄▄ 18:30 | ▅ Thu
```

## Color reference

The colors match the Claude Code light/dark themes and are switched with `COLOR_SCHEME`. The table below shows how they look with dark. See [SPEC](docs/SPEC.en.md) for the full palette including the RGB values.

| Target | Color |
| --- | --- |
| Model | Fable is purple, Opus is orange, Haiku is cyan, and the others (Sonnet, etc.) are uncolored |
| effort | `low` yellow, `medium` green, `high` blue, `xhigh` purple, `max` rainbow, one character at a time |
| Context usage | Yellow at 70% or more, orange at 80% or more, blinking red at 90% or more |
| Rate limit remaining (5-hour / weekly) | Yellow at 40% or less, orange at 15% or less, blinking red at 5% or less |
| Branch column | `↑` blue, `↓` yellow |
| Commit column | Hash uncolored, number of changed files in the text color, added lines green, deleted lines red |
| PR number | Underlined. approved green, pending blue-violet, changes requested red, draft uncolored, merged purple + strikethrough, closed uncolored + strikethrough |
| PR CI | `✓` green, `✗` red, `●` yellow |

## Update and uninstall

### Update

Update the repository and copy the script for the version you use again. `~/.claude/statusline.conf` is carried over as is.
Values in the configuration file take precedence over the defaults, so delete the line from the configuration file for any option that should follow the default again.
If you created the configuration file from the template (`statusline.conf`), compare it with the updated template and take in any new tokens (values of `LAYOUT_LINE1` or `HIGHLIGHT`) and options.
Tokens not written in `LAYOUT_LINE1` are not shown.

```bash
cd claude-code-statusline
git pull
cp statusline-macos.sh ~/.claude/statusline.sh
```

On Linux, copy `statusline-linux.sh`.

### Uninstall

1. Remove the `statusLine` setting from `~/.claude/settings.json`.
2. Delete the files you placed.

   ```bash
   rm ~/.claude/statusline.sh ~/.claude/statusline.conf
   ```

3. The history directory `/tmp/claude-statusline-<uid>/` is removed on reboot. To remove it right away, run `rm -r "/tmp/claude-statusline-$(id -u)"`.

## Troubleshooting

### Only `✻ -- (...)` is shown

When a required command or bash version is missing, the following single line is shown and the script exits.

| Display | Fix |
| --- | --- |
| `✻ -- (jq required: brew install jq)` | Install `jq` on macOS |
| `✻ -- (jq required: sudo apt install jq)` | Install `jq` on Linux |
| `✻ -- (flock required: sudo apt install util-linux)` | Install `flock` on Linux |
| `✻ -- (bash 4.1+ required)` | Run the Linux version with bash 4.1 or later |

### Nothing is shown

- Check that the execute permission is set with `chmod +x ~/.claude/statusline.sh`
- Check that the `command` path in `~/.claude/settings.json` matches where you placed the script
- Run it manually and check the output. If line 2 (such as `✻ Unknown ...`) appears as below, the script itself works

  ```bash
  echo '{}' | ~/.claude/statusline.sh
  ```

- Check that `~/.claude/statusline.conf` has no lines other than variable assignments (such as `exit`)

### Garbled characters

The script pins the locale to `C.UTF-8` at the top. In old environments without `C.UTF-8` (Debian 10 and earlier, etc.), `✻` and the bars may break, or the truncation position of names may shift.
Change `export LC_ALL=C.UTF-8` at the top of the script to an available UTF-8 locale such as `en_US.UTF-8`.

### `↓behind` is not updated

By default `git fetch` is not run, so `↓` is the value as of the last fetch / pull. Set `GIT_FETCH=1` to refresh it automatically. If it is still not updated, check the authentication conditions in [Notes on using `GIT_FETCH=1`](#notes-on-using-git_fetch1).

### The PR is not shown

- Check that `PR_STATUS=1` is set and that `LAYOUT_LINE1` contains `branch`
- Check that `gh auth status` shows you are authenticated and that `gh pr view` in the repository shows the PR. With several remotes, run `gh repo set-default`
- It is not shown if the branch has not been pushed or the pushed branch has no PR. A merged or closed PR is shown only when the local HEAD matches that PR's last commit
- If fetching keeps failing, the display disappears 30 minutes after the last success

### The colors look wrong

- Check that the terminal supports truecolor (24-bit color). On a terminal that does not, the colors may be approximated or the control characters may show as they are
- On a terminal with a light background, set `COLOR_SCHEME=light`

## Privacy and security

- `~/.claude/statusline.conf` is loaded as a shell script and executed on every render. Do not write untrusted content in it
- The network is accessed only when you enable `GIT_FETCH=1` (`git fetch`) or `PR_STATUS=1` (queries to the GitHub API via `gh`)
- The rate limit history and the PR cache are saved in `/tmp/claude-statusline-<uid>/` with permission 700. If the directory is owned by another user or is a symbolic link, it is not used and the display continues without the history and the PR status

## For developers

This repository is for personal use, and responses to Issues and Pull Requests are not guaranteed. Even if accepted, they may not be merged. Feel free to fork and modify it ([0BSD](LICENSE)).

See [DEVELOPMENT](docs/DEVELOPMENT.en.md) for setting up the environment and running the tests, and [SPEC](docs/SPEC.en.md) for the output specification.

## License

[0BSD](LICENSE). No copyright notice is required, and you may copy, modify and redistribute it freely.
