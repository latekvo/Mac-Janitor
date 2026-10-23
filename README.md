# Mac Janitor

Keeps the disk from filling up with agent leftovers. One LaunchAgent runs the
`janitor` CLI every 6 hours; a menu-bar applet shows what it did and can preview
or run it on demand.

## What it removes

| What | When |
|---|---|
| `node_modules` in argent worktrees | the worktree is untouched for 3 days |
| An argent worktree, whole | merged into main with nothing left to push (and idle 1 day), or its PR is open and it is untouched for 3 days, or it is untouched for 30 days |
| Docker images | no container uses them and they arrived locally over 7 days ago |
| Android emulators (AVDs) | unused for 7 days |
| Claude Code scratchpads (`/private/tmp/claude-<uid>/<project>/<session>`) | untouched for 14 days |

"Untouched" is the newest modification time in the worktree, ignoring
`node_modules`, plus its git `HEAD` and `index`.

Worktrees are those registered with `~/dev/engineering/argent`, plus plain copies in
`~/dev/engineering/argent-worktrees`. Branches are never deleted.

## What it never removes

- Anything a running process has open or as its working directory (`lsof`).
- Anything a LaunchAgent plist mentions.
- A worktree or `node_modules` that a kept checkout's `node_modules` symlinks into
  (donor checkouts).
- A git checkout of some other repo sitting in the worktree folder.
- Running emulators, and images used by any container, running or stopped.

Before a worktree goes, uncommitted changes are saved as a patch, untracked files
up to 50 MB as a tarball, both in `~/Library/Application Support/MacJanitor/salvage/`.
A commit that no branch or remote holds gets a `refs/janitor/<name>-<time>` ref.

## Layout

- `Sources/JanitorCore` - rules, guards, the run report
- `Sources/janitor` - the CLI launchd runs
- `Sources/MacJanitor` - the menu-bar applet
- `install/` - build, install and uninstall scripts

## Use

```sh
./install/install.sh                  # build, install the LaunchAgent, start the applet
.build/release/janitor run --dry-run  # print the plan, delete nothing
launchctl kickstart gui/$(id -u)/com.ignacy.mac-janitor   # run the job now
./install/uninstall.sh
swift test
```

The report of the last real run is `~/Library/Application Support/MacJanitor/last-run.json`,
one line per run goes to `history.jsonl` beside it, and every action is logged to
`~/Library/Logs/mac-janitor.log`.

Thresholds and paths can be overridden in `~/Library/Application Support/MacJanitor/config.json`
with any subset of the keys in `Sources/JanitorCore/Config.swift`, e.g.
`{"paused": true}` or `{"openPRIdleDays": 5}`.
