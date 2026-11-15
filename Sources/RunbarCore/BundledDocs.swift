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
          "description": "Command that runs the service in the foreground. Runs in zsh -l -c inside cwd. {port} becomes the port the service will start on."
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
          "enum": ["nextjs", "node", "python", "docker", "java", "other"],
          "description": "Service type. If omitted, Runbar guesses it from the command."
        },
        "open": {
          "type": "string",
          "description": "URL for the Open button. {port} becomes the real port. Default: http://localhost:{port}."
        },
        "env": {
          "type": "object",
          "additionalProperties": { "type": ["string", "number", "boolean"] },
          "description": "Extra environment variables."
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
        "autoPort": {
          "type": "boolean",
          "description": "If the port is taken, start on the next free one (skipping the other services' ports). Needs the command to use {port} or the PORT variable. Default: settings.autoPort."
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
    "finch": {
      "name": "Blue Finch",
      "root": "~/Developer/finch",
      "services": {
        "finch-api": {
          "cwd": "finch-api",
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
| `command`   | string, required                            | command that runs the service in the foreground; `{port}` becomes the port it will start on |
| `cwd`       | path                                        | relative to `root`, or absolute (default: the `root`) |
| `port`      | number                                      | expected port; Runbar exports `PORT` and warns if the service starts on a different one |
| `type`      | `nextjs` `node` `python` `docker` `java` `other` | icon and port rules; guessed from the command if omitted |
| `open`      | URL                                         | where the Open button goes; `{port}` becomes the real port |
| `env`       | object                                      | extra environment variables |
| `envFile`   | path                                        | `KEY=value` file to load, relative to `cwd` |
| `health`    | path or URL                                 | must answer 2xx/3xx for the service to count as running |
| `autostart` | `true`/`false`                              | start when Runbar opens |
| `restart`   | `never` `on-crash`                          | restart automatically if it crashes (up to 3 times in 2 minutes) |
| `stop`      | string                                      | extra command to stop it (e.g. `docker compose down`) |
| `autoPort`  | `true`/`false`                              | if the port is taken, start on the next free one (default: `settings.autoPort`) |

General settings (optional):

```json
"settings": { "look": "auto", "shell": "/bin/zsh", "notifyOnCrash": true, "autoPort": false }
```

`look`: `auto` (glass on macOS 26+), `solid` or `glass`.
`autoPort`: default for every service; each service can override it.

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
   file. Prefer ids that already name the project (`acme-web`, `finch-site`).
7. Don't remove existing services unless the user asks, and keep fields you
   don't understand.
8. After editing, run `runbar validate`. It shows each problem with line and
   column. Fix until no errors are left.

## Finding services in a folder

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
runbar status [--json]          status, real port, memory and CPU of each service
runbar start <id> [--wait]      start a service (--wait waits for the port to open)
runbar stop <id>                stop the service and its child processes
runbar restart <id> [--wait]    restart
runbar logs <id> [-n 100] [-f]  the service's output
runbar path                     the config folder
```

Logs are in `~/Library/Logs/Runbar/<id>.log`.
"""#
}
