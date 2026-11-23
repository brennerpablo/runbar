import Foundation

/// Files the app keeps in ~/.config/runbar next to config.json.
public enum BundledDocs {
    public static let schema = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "runbar-config-v1",
  "title": "Runbar config",
  "description": "Local development services that Runbar starts, stops and monitors. Read README.md in this folder.",
  "type": "object",
  "additionalProperties": false,
  "required": ["projects"],
  "properties": {
    "$schema": { "type": "string" },
    "version": { "const": 1 },
    "settings": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "look": {
          "enum": ["auto", "solid", "glass"],
          "default": "auto",
          "description": "App look. auto uses glass (blurred, translucent panel) on macOS 26 or later and solid on earlier versions."
        },
        "shell": {
          "type": "string",
          "default": "/bin/zsh",
          "description": "Shell that runs the commands, always as a login shell (-l -c)."
        },
        "notifyOnCrash": {
          "type": "boolean",
          "default": true,
          "description": "Show a notification when a service crashes."
        },
        "autoPort": {
          "type": "boolean",
          "default": false,
          "description": "Default for every service: if the configured port is taken, start on the next free port. Each service can override it."
        },
        "activeProjectsFirst": {
          "type": "boolean",
          "default": true,
          "description": "List projects with something running before the others in the panel. The others keep their order from this file."
        },
        "hosts": {
          "type": "boolean",
          "default": true,
          "description": "Give each service with a port (proxies aside) a local address, <id>.localhost, that Runbar routes to whatever port it runs on. The browser keeps its saved passwords and cookies for that address. Each service can set or turn off its own with host."
        },
        "hostPort": {
          "type": "integer",
          "minimum": 1,
          "maximum": 65535,
          "default": 80,
          "description": "Port the .localhost addresses answer on. 80 keeps it out of the URL (http://acme-web.localhost)."
        }
      }
    },
    "projects": {
      "type": "object",
      "description": "Projects, in the order they appear in the menu. The key is the project id.",
      "propertyNames": { "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]*$" },
      "additionalProperties": { "$ref": "#/$defs/project" }
    }
  },
  "$defs": {
    "project": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "name": { "type": "string", "description": "Name shown in the menu. Default: the id." },
        "root": { "type": "string", "description": "Base folder of the project. Accepts ~." },
        "services": {
          "type": "object",
          "description": "The project's services. The key is the service id, unique across the whole file.",
          "propertyNames": { "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]*$" },
          "additionalProperties": { "$ref": "#/$defs/service" }
        }
      }
    },
    "service": {
      "type": "object",
      "additionalProperties": false,
      "required": ["command"],
      "properties": {
        "command": {
          "type": "string",
          "minLength": 1,
          "description": "Command that runs the service in the foreground. Runs in zsh -l -c inside cwd. {port} becomes the port the service will start on, {host} its local address (acme-web.localhost) and {url} the URL the browser uses (http://acme-web.localhost)."
        },
        "cwd": {
          "type": "string",
          "description": "Folder the command runs in. Relative to the project root, or absolute. Default: the root."
        },
        "port": {
          "type": ["integer", "null"],
          "minimum": 1,
          "maximum": 65535,
          "description": "Expected port. Runbar exports PORT=<port> and warns if the service starts on a different one."
        },
        "type": {
          "enum": ["nextjs", "node", "python", "docker", "java", "proxy", "other"],
          "description": "Service type. If omitted, Runbar guesses it from the command. proxy: a local port forwarded to something remote (cloud-sql-proxy, kubectl port-forward, ssh -L): it opens when a service that needs it starts and closes after idle with no connections."
        },
        "needs": {
          "type": "array",
          "items": { "type": "string", "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]*$" },
          "uniqueItems": true,
          "description": "Ids of services (usually proxies) to open before this one starts. Runbar waits up to 30 s for each one's port, and keeps them open while this service runs."
        },
        "idle": {
          "type": "string",
          "pattern": "^([0-9]+(\\.[0-9]+)?[smh]|never)$",
          "default": "15m",
          "description": "Proxies only: how long it may sit with no connections (and no running service that needs it) before Runbar closes it. \"5m\", \"15m\", \"1h\" or \"never\"."
        },
        "open": {
          "type": "string",
          "description": "URL for the Open button. {port} becomes the real port, {host} and {url} the local address. Default: the local address (http://<id>.localhost), or http://localhost:{port} for a service without one."
        },
        "host": {
          "type": ["string", "boolean"],
          "description": "The service's local address, always under .localhost: \"acme\" is acme.localhost, \"app.acme\" is app.acme.localhost. false turns it off. Default: <id>.localhost for a service with a port (not a proxy), unless settings.hosts is false."
        },
        "env": {
          "type": "object",
          "additionalProperties": { "type": ["string", "number", "boolean"] },
          "description": "Extra environment variables. {port}, {host} and {url} are replaced in the values (\"BETTER_AUTH_URL\": \"{url}\")."
        },
        "envFile": {
          "type": "string",
          "description": "File of variables (KEY=value) to load, relative to cwd."
        },
        "health": {
          "type": "string",
          "description": "Path (e.g. /health) or URL that must answer 2xx/3xx for the service to count as running."
        },
        "autostart": { "type": "boolean", "default": false, "description": "Start when Runbar opens." },
        "restart": { "enum": ["never", "on-crash"], "default": "never", "description": "Restart automatically if the process crashes." },
        "stop": {
          "type": "string",
          "description": "Extra command to stop it (e.g. docker compose down). The process and its children are always ended too."
        },
        "install": {
          "type": "string",
          "description": "Command that reinstalls the service's dependencies (e.g. pnpm install). Runbar runs it in cwd after deleting node_modules or .venv from its Disk view. Without it, Runbar picks one from the lockfile: npm ci, pnpm install --frozen-lockfile, yarn install --frozen-lockfile, bun install, uv sync, or a new .venv from requirements.txt."
        },
        "autoPort": {
          "type": "boolean",
          "description": "If the port is taken, start on the next free one (skipping the other services' ports). Needs the command to use {port} or the PORT variable. Default: settings.autoPort (always false for proxies, whose clients expect a fixed port)."
        }
      }
    }
  }
}

"""#

    public static let readme = #"""
# Runbar — instructions for agents

Runbar is a macOS menu bar app that starts, stops and monitors local development
servers (Next.js apps, Python APIs, docker compose…). Everything it knows comes
from the `config.json` in this folder. This file explains the format so an agent
can write or adjust the configuration.

## Files

| file          | who edits it           | what it is                                 |
|---------------|------------------------|--------------------------------------------|
| `config.json` | you, the agent, the app | the configuration                         |
| `schema.json` | the app (don't edit)   | JSON Schema of the format                  |
| `README.md`   | the app (don't edit)   | this file                                  |

The app watches the folder and reloads on its own. If the JSON becomes invalid,
it keeps using the last valid version and shows the error with line and column.

## Format

```json
{
  "$schema": "./schema.json",
  "version": 1,
  "projects": {
    "acme": {
      "name": "Acme Store",
      "root": "~/Developer/acme",
      "services": {
        "acme-web": {
          "cwd": "acme-web",
          "type": "nextjs",
          "command": "npm run dev",
          "port": 3000
        },
        "acme-db": {
          "cwd": "acme-db",
          "type": "docker",
          "command": "docker compose up",
          "stop": "docker compose down",
          "port": 8080
        }
      }
    },
    "orbit": {
      "name": "Orbit Labs",
      "root": "~/Developer/orbit",
      "services": {
        "orbit-api": {
          "cwd": "orbit-api",
          "type": "python",
          "command": ".venv/bin/uvicorn app.main:app --reload --port {port}",
          "port": 8000,
          "autoPort": true,
          "open": "http://localhost:{port}/docs",
          "restart": "on-crash"
        }
      }
    }
  }
}
```

Projects and services are objects keyed by id, in the order they appear in the
menu. The service id is what the command line uses (`runbar start acme-web`).

## Fields

Project:

| field      | type    | what it does                                |
|------------|---------|---------------------------------------------|
| `name`     | string  | name shown in the menu (default: the id)    |
| `root`     | path    | base folder of the project; accepts `~`     |
| `services` | object  | the services, keyed by id                   |

Service:

| field       | type                                        | what it does |
|-------------|---------------------------------------------|--------------|
| `command`   | string, required                            | command that runs the service in the foreground; `{port}` becomes the port it will start on, `{host}` and `{url}` its local address |
| `cwd`       | path                                        | relative to `root`, or absolute (default: the `root`) |
| `port`      | number                                      | expected port; Runbar exports `PORT` and warns if the service starts on a different one |
| `type`      | `nextjs` `node` `python` `docker` `java` `proxy` `other` | icon and port rules; guessed from the command if omitted |
| `open`      | URL                                         | where the Open button goes; `{port}` becomes the real port (default: the local address) |
| `host`      | name or `false`                             | local address under `.localhost` (`"acme"` → `acme.localhost`); `false` turns it off (default: `<id>.localhost`) |
| `env`       | object                                      | extra environment variables; `{port}`, `{host}` and `{url}` are replaced in the values |
| `envFile`   | path                                        | `KEY=value` file to load, relative to `cwd` |
| `health`    | path or URL                                 | must answer 2xx/3xx for the service to count as running |
| `autostart` | `true`/`false`                              | start when Runbar opens |
| `restart`   | `never` `on-crash`                          | restart automatically if it crashes (up to 3 times in 2 minutes) |
| `stop`      | string                                      | extra command to stop it (e.g. `docker compose down`) |
| `install`   | string                                      | command that reinstalls dependencies after Runbar deletes `node_modules` or `.venv` (default: picked from the lockfile) |
| `autoPort`  | `true`/`false`                              | if the port is taken, start on the next free one (default: `settings.autoPort`; always off for proxies) |
| `needs`     | list of ids                                 | services (usually proxies) opened before this one starts |
| `idle`      | `5m` `15m` `1h` `never`                     | proxies only: close after this long with no connections (default `15m`) |

## Local addresses

Every service with a port (proxies aside) also answers at `http://<id>.localhost`:
Runbar listens on port 80 of this Mac (loopback only, no root) and passes each
request, WebSockets included, to whatever port the service runs on now. The
browser keeps saved passwords and cookies per address, so they survive autoPort
moving the service, and two apps no longer share `localhost`'s cookies.

- `"host": "acme"` gives `acme-web` the address `acme.localhost`; `"app.acme"`
  gives `app.acme.localhost`. `"host": false` turns it off for that service, and
  `"settings": { "hosts": false }` for all of them.
- `.localhost` names reach this Mac on their own (browsers and macOS), with no
  `/etc/hosts` entry.
- The service sees the original `Host` header (`acme.localhost`), so links and
  redirects it builds from it stay on the address.
- Apps that check their own URL (Better Auth's `BETTER_AUTH_URL`, NextAuth's
  `NEXTAUTH_URL`, OAuth callbacks) need it set to the address: use `{url}` in
  `env` or in the command, which becomes `http://acme-web.localhost`.

```json
"acme-web": {
  "cwd": "acme-web",
  "command": "npm run dev -- -p {port}",
  "port": 3000,
  "host": "acme",
  "env": { "BETTER_AUTH_URL": "{url}" }
}
```

- `http://localhost` lists every address and whether its service is running. An
  address whose service is stopped or starting shows a page that loads the app
  as soon as it answers.
- If something else holds port 80, the panel says who, Open falls back to
  `localhost:<port>`, and Runbar tries again every few seconds.
  `settings.hostPort` moves the addresses to another port (`http://acme.localhost:8888`).

## Proxies

A proxy forwards a local port to something remote: `cloud-sql-proxy`, `kubectl
port-forward`, `ssh -L`, `aws ssm start-session`. Declare it as a service with
`"type": "proxy"` (Runbar also guesses it from those commands), and list it in
`needs` of each service that connects through it:

```json
"takt-api": {
  "cwd": "takt-api",
  "command": ".venv/bin/uvicorn app.main:app --reload --port {port}",
  "port": 8100,
  "needs": ["takt-db"]
},
"takt-db": {
  "type": "proxy",
  "command": "cloud-sql-proxy --port {port} my-project:us-east1:takt",
  "port": 5434,
  "idle": "15m",
  "open": "postgres://localhost:{port}/takt"
}
```

- Starting `takt-api` opens `takt-db` first and waits for its port.
- Runbar counts the connections open to the proxy's port. With none, and no
  service that needs it running, it closes the proxy after `idle`.
- `open` is the connection URL the app copies (no browser button for proxies).
- Don't run proxies from a LaunchAgent with `KeepAlive`: launchd would keep the
  port open all day and restart it whenever it is stopped. Runbar can move such a
  job into config.json from "ports in use outside Runbar".
- `runbar open <id> --wait` opens a proxy from the Terminal (for a migration, a
  `psql` session); it closes on its own after `idle`.

General settings (optional):

```json
"settings": { "look": "auto", "shell": "/bin/zsh", "notifyOnCrash": true, "autoPort": false, "activeProjectsFirst": true, "hosts": true, "hostPort": 80 }
```

`look`: `auto` (glass on macOS 26+), `solid` or `glass`.
`autoPort`: default for every service; each service can override it.
`activeProjectsFirst`: projects with something running come first in the panel (on by default).
`hosts`: each service's local address, `<id>.localhost` (on by default). `hostPort`: the port those addresses answer on (80).

## Rules

1. `command` runs in `zsh -l -c` inside `cwd`. Use the same command you would run
   in the Terminal. Don't use `&`, `nohup` or `npm start &`: the process has to
   stay in the foreground, or Runbar thinks it exited.
2. The login shell loads Homebrew's PATH but doesn't activate venvs. For Python,
   use the venv's binary: `.venv/bin/uvicorn …`, `.venv/bin/python manage.py …`.
3. Write the port in the command as `{port}`: Runbar replaces it with the port the
   service will start on (`npm run dev -- -p {port}`, `pnpm dev -p {port}`,
   `.venv/bin/uvicorn app.main:app --port {port}`). It also exports
   `PORT=<port>`, which Next.js respects.
4. Each service needs a different port. Many Next.js apps default to 3000: pick
   free ports (3001, 3002…). If the `package.json` script already hardcodes the
   port (`next dev -p 3100`), call the binary directly so it can be changed:
   `npx next dev -p {port}` or `pnpm exec next dev -p {port}`.
5. Port taken: without `autoPort`, Runbar doesn't start the service and says who
   holds the port. With `"autoPort": true`, it starts on the next free port,
   skipping the ports of the other services in the file. The `{port}` in the
   command is what makes that possible; a fixed number in the command prevents it
   (`runbar validate` warns about it).
6. Ids: letters, digits, `.`, `_` and `-`. A service id is unique across the whole
   file. Prefer ids that already name the project (`acme-web`, `orbit-site`).
7. Don't remove existing services unless the user asks, and keep fields you
   don't understand.
8. After editing, run `runbar validate`. It shows each problem with line and
   column. Fix until no errors are left.

## Finding services in a folder

`runbar scan` lists the development servers Runbar finds in the projects' folders
that config.json doesn't run yet, each with an id, a command and a free port, as
JSON ready to paste under the project's `services` (`--json` for the whole list).
Start from it, check each against the project's README, and skip the ones that
aren't servers. A project that isn't in the file yet isn't scanned: add it with
its `root` first. What to look for:

- `package.json` with a `dev` script → `npm run dev` (`pnpm dev` if there is a
  `pnpm-lock.yaml`, `yarn dev` with `yarn.lock`, `bun dev` with `bun.lockb`).
  If the `next` dependency is present, `type: "nextjs"`.
- Monorepos (`apps/*`, `packages/*`, `pnpm-workspace.yaml`): one service per app
  that runs a server, each with its own port.
- `docker-compose.yml`, `compose.yaml` → `docker compose up`,
  `stop: "docker compose down"`, `type: "docker"`, port = the main published one.
- FastAPI → `.venv/bin/uvicorn app.main:app --reload --port {port}`.
  Django → `.venv/bin/python manage.py runserver {port}`. Flask →
  `.venv/bin/flask run --port {port}`.
- The project's README usually gives the development command: check it.
- Skip folders without a development server: libraries, scripts that run and
  exit, CLIs, backups.

## Command line

The app installs the `runbar` command (⋯ menu → Install the runbar command).

```
runbar validate [--json]        check config.json (line and column of each error)
runbar scan [--all] [--json]    dev servers in the projects' folders not in config.json
runbar status [--json]          status, real port, address, memory and CPU of each service
runbar start <id> [--wait]      start a service (--wait waits for the port to open)
runbar stop <id>                stop the service and its child processes
runbar restart <id> [--wait]    restart
runbar open <id> [--wait]       open a proxy (same as start)
runbar close <id>               close a proxy (same as stop)
runbar logs <id> [-n 100] [-f]  the service's output
runbar path                     the config folder
```

Logs are in `~/Library/Logs/Runbar/<id>.log`.
"""#
}
