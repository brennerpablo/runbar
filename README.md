# Runbar

A macOS menu bar app to start, stop and watch the development servers of all your
projects (Next.js, Python APIs, docker compose…) in one place.

- A list per project with the status, real port, memory and CPU of each service.
- A detail view with PID, start time, last log, memory and CPU charts (30 min) and live output.
- Detects port conflicts and when Next jumps to another port; shows ports held by outside processes.
- Recognizes services started outside Runbar (in Terminal, for example) by the process's folder.
- Services survive restarting or updating Runbar: it re-adopts the processes when it opens.
- Two looks: solid and Liquid Glass (automatic on macOS 26+).

## Configuration: a JSON file your agent can write

Everything comes from `~/.config/runbar/config.json`. The app keeps a `schema.json` and a
`README.md` written for agents next to it, and reloads on its own when the file changes. The
"Set up with an agent…" window has a ready-made request to paste into Claude Code, Codex or Cursor.

```json
{
  "$schema": "./schema.json",
  "version": 1,
  "projects": {
    "acme": {
      "name": "Acme Store",
      "root": "~/Developer/acme",
      "services": {
        "acme-web": { "cwd": "acme-web", "type": "nextjs", "command": "npm run dev", "port": 3000 }
      }
    }
  }
}
```

The full format is in [`Sources/RunbarCore/BundledDocs.swift`](Sources/RunbarCore/BundledDocs.swift)
(the same text the app writes to `~/.config/runbar/README.md`).

## Command line

```
runbar validate [--json]        check config.json (line and column of each error)
runbar status [--json]          status, real port, memory and CPU
runbar start <id> [--wait]      start a service (--wait waits for the port to open)
runbar stop <id>                stop the service and its child processes
runbar restart <id> [--wait]
runbar logs <id> [-n 100] [-f]
runbar reload | path
```

If the app is closed, `start`, `stop` and `restart` open it first.

## Build and install

Only needs the Command Line Tools (no Xcode).

```
make app       # build/Runbar.app
make install   # installs to ~/Applications, puts the runbar command on your PATH and opens the app
make build     # swift build (debug)
```

To uninstall: quit Runbar, delete `~/Applications/Runbar.app` and the `runbar` link
(in `/opt/homebrew/bin`, `/usr/local/bin` or `~/.local/bin`). The configuration lives in
`~/.config/runbar`, the logs in `~/Library/Logs/Runbar`.

### Review the UI without clicking the menu bar

```
.build/debug/RunbarApp --snapshot /tmp/runbar-snap [service-id]
```

Draws the panel (list and detail, solid and Liquid Glass, light and dark) and the agent
window to PNGs, with real data. Opens no socket and touches no services.

## How it works

| part | where |
|------|-------|
| JSON parser with line/column, and config validation | `Sources/RunbarCore/JSON.swift`, `Config.swift` |
| Processes: tree, memory (phys_footprint), CPU, LISTEN ports, folder | `Sources/RunbarCore/ProcScanner.swift` (libproc) |
| Starting a service: login shell, its own process group, output to the log file | `Sources/RunbarCore/Spawner.swift` |
| Unix socket between the CLI and the app | `Sources/RunbarCore/Control.swift` |
| Each service's state, re-adoption, automatic restart | `Sources/RunbarApp/ServiceRuntime.swift` |
| App model, monitoring every 2 s, conflict detection | `Sources/RunbarApp/AppModel.swift`, `Display.swift` |
| Menu bar icon and panel (drawn by the app, not `MenuBarExtra`; pinned under the icon) | `Sources/RunbarApp/StatusPanel.swift` |
| UI | `Sources/RunbarApp/PopoverView.swift`, `ServiceDetailView.swift`, `AgentView.swift`, `Components.swift`, `Theme.swift` |

SwiftUI's `@State` became a macro in the macOS 27 SDK and its plugin only ships with Xcode, so
the views use `@ViewState` (`Sources/RunbarApp/ViewState.swift`), which does the same with the `State` type.
