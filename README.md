# Mac Janitor

Keeps the disk from filling up with agent leftovers. One LaunchAgent wakes the
`janitor` CLI hourly; it runs every 6 hours, or at once when free space drops
below 20 GB. A menu-bar applet previews what would go, cleans on demand and holds
the settings.

## What it removes

| What | When |
|---|---|
| `node_modules` in worktrees | the worktree is untouched for 3 days |
| A worktree, whole | merged into main with nothing left to push (and idle 1 day), or its PR is open and it is untouched for 3 days, or it is untouched for 30 days |
| Docker images | no container uses them and they arrived locally over 7 days ago |
| Android emulators (AVDs) | unused for 7 days |
| Claude Code scratchpads (`/private/tmp/claude-<uid>/<project>/<session>`) | untouched for 14 days |

Worktrees are found by walking the home folder, skipping other volumes, `~/Library`,
the Trash and `node_modules`: those registered with any repo there, plus plain copies in
`<repo>-worktrees`. A worktree whose repo is gone (its `.git` file points nowhere
and no repo holds its record) counts as a plain copy, which only the 30-day rule
removes. One whose repo moved keeps its record there and is never removed whole;
`git worktree repair` reconnects it. The PR rules need a GitHub remote. The main
checkout and branches are never removed.

"Untouched" is the newest file modification time in the worktree, ignoring
`node_modules`, plus its git `HEAD` and `index`. Directory times are ignored, so
removing `node_modules` does not restart the clock.

## What it never removes

- Anything a running process has open or as its working directory (`lsof`).
- Anything a LaunchAgent plist mentions.
- Anything in the keep list (the pin in the applet).
- A `node_modules` that another checkout's `node_modules` symlinks into, unless that
  checkout is itself idle or going (donor checkouts). Symlinked `node_modules` are
  never removed themselves: they free nothing.
- A git checkout of some other repo sitting in a worktree folder, or anything containing a checkout.
- Running emulators, and images used by any container, including Docker Desktop's own.

Before a git worktree goes (plain copies get no salvage), uncommitted changes are saved as a patch, untracked files
up to 50 MB as a tarball, both in `~/Library/Application Support/MacJanitor/salvage/`
for 30 days. A commit that no branch or remote holds gets a
`refs/janitor/<name>-<time>` ref.

## Layout

- `Sources/JanitorCore` - rules, guards, config, the run report
- `Sources/janitor` - the CLI launchd runs
- `Sources/MacJanitor` - the menu-bar applet
- `install/` - build, install and uninstall scripts

## Use

```sh
./install/install.sh                  # build, install the LaunchAgent, start the applet
.build/release/janitor run --dry-run  # print the plan, delete nothing
launchctl kickstart gui/$(id -u)/com.ignacy.mac-janitor   # wake the job now
./install/uninstall.sh
swift test
```

The report of the last real run is `~/Library/Application Support/MacJanitor/last-run.json`,
one line per run goes to `history.jsonl` beside it, and every action is logged to
`~/Library/Logs/mac-janitor.log`.

Settings live in `~/Library/Application Support/MacJanitor/config.json`, which holds
only the keys that differ from the defaults in `Sources/JanitorCore/Config.swift`,
e.g. `{"paused": true, "openPRIdleDays": 5, "disabled": ["avd"]}`. The applet edits it.
