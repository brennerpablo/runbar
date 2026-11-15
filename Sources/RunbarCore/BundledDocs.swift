import Foundation

/// Arquivos que o app mantém em ~/.config/runbar ao lado do config.json.
public enum BundledDocs {
    public static let schema = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "runbar-config-v1",
  "title": "Runbar config",
  "description": "Serviços locais de desenvolvimento que o Runbar sobe, para e monitora. Leia README.md nesta pasta.",
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
          "description": "Visual do app. auto usa Liquid Glass no macOS 26 ou mais novo e sólido nos anteriores."
        },
        "shell": {
          "type": "string",
          "default": "/bin/zsh",
          "description": "Shell que roda os comandos, sempre como login shell (-l -c)."
        },
        "notifyOnCrash": {
          "type": "boolean",
          "default": true,
          "description": "Mostra uma notificação quando um serviço cai."
        },
        "autoPort": {
          "type": "boolean",
          "default": false,
          "description": "Padrão para todos os serviços: se a porta configurada estiver ocupada, sobe na próxima porta livre. Cada serviço pode sobrescrever."
        }
      }
    },
    "projects": {
      "type": "object",
      "description": "Projetos, na ordem em que aparecem no menu. A chave é o id do projeto.",
      "propertyNames": { "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]*$" },
      "additionalProperties": { "$ref": "#/$defs/project" }
    }
  },
  "$defs": {
    "project": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "name": { "type": "string", "description": "Nome exibido no menu. Padrão: o id." },
        "root": { "type": "string", "description": "Pasta base do projeto. Aceita ~." },
        "services": {
          "type": "object",
          "description": "Serviços do projeto. A chave é o id do serviço, único no arquivo todo.",
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
          "description": "Comando que sobe o serviço em primeiro plano. Roda em zsh -l -c dentro de cwd. {port} vira a porta em que o serviço vai subir."
        },
        "cwd": {
          "type": "string",
          "description": "Pasta onde o comando roda. Relativa ao root do projeto ou absoluta. Padrão: o root."
        },
        "port": {
          "type": ["integer", "null"],
          "minimum": 1,
          "maximum": 65535,
          "description": "Porta esperada. O Runbar exporta PORT=<port> e avisa se o serviço subir em outra."
        },
        "type": {
          "enum": ["nextjs", "node", "python", "docker", "java", "other"],
          "description": "Tipo do serviço. Se omitido, o Runbar tenta adivinhar pelo comando."
        },
        "open": {
          "type": "string",
          "description": "URL do botão Abrir. {port} vira a porta real. Padrão: http://localhost:{port}."
        },
        "env": {
          "type": "object",
          "additionalProperties": { "type": ["string", "number", "boolean"] },
          "description": "Variáveis de ambiente extras."
        },
        "envFile": {
          "type": "string",
          "description": "Arquivo de variáveis (KEY=valor) para carregar, relativo a cwd."
        },
        "health": {
          "type": "string",
          "description": "Rota (ex.: /health) ou URL que precisa responder 2xx/3xx para o serviço contar como no ar."
        },
        "autostart": { "type": "boolean", "default": false, "description": "Sobe quando o Runbar abre." },
        "restart": { "enum": ["never", "on-crash"], "default": "never", "description": "Reinicia sozinho se o processo cair." },
        "stop": {
          "type": "string",
          "description": "Comando extra para parar (ex.: docker compose down). Sempre encerra também o processo e os filhos."
        },
        "autoPort": {
          "type": "boolean",
          "description": "Se a porta estiver ocupada, sobe na próxima livre (pulando as portas dos outros serviços). Precisa que o comando use {port} ou a variável PORT. Padrão: settings.autoPort."
        }
      }
    }
  }
}

"""#

    public static let readme = #"""
# Runbar — instruções para agentes

O Runbar é um app de menu bar do macOS que sobe, para e monitora servidores de
desenvolvimento locais (apps Next.js, APIs Python, docker compose…). Tudo o que
ele sabe vem do `config.json` desta pasta. Este arquivo explica o formato para
que um agente consiga montar ou ajustar a configuração.

## Arquivos

| arquivo       | quem edita           | o que é                                    |
|---------------|----------------------|--------------------------------------------|
| `config.json` | você, o agente, o app | a configuração                             |
| `schema.json` | o app (não edite)    | JSON Schema do formato                     |
| `README.md`   | o app (não edite)    | este arquivo                               |

O app observa a pasta e recarrega sozinho. Se o JSON ficar inválido, ele
continua usando a última versão válida e mostra o erro com linha e coluna.

## Formato

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

Projetos e serviços são objetos indexados pelo id, na ordem em que aparecem no
menu. O id do serviço é o que se usa na linha de comando (`runbar start acme-web`).

## Campos

Projeto:

| campo      | tipo    | o que faz                                   |
|------------|---------|---------------------------------------------|
| `name`     | texto   | nome exibido no menu (padrão: o id)         |
| `root`     | caminho | pasta base do projeto; aceita `~`           |
| `services` | objeto  | os serviços, indexados pelo id              |

Serviço:

| campo       | tipo                                        | o que faz |
|-------------|---------------------------------------------|-----------|
| `command`   | texto, obrigatório                          | comando que sobe o serviço em primeiro plano; `{port}` vira a porta em que ele vai subir |
| `cwd`       | caminho                                     | relativo ao `root` ou absoluto (padrão: o `root`) |
| `port`      | número                                      | porta esperada; o Runbar exporta `PORT` e avisa se o serviço subir em outra |
| `type`      | `nextjs` `node` `python` `docker` `java` `other` | ícone e regras de porta; se omitido, é adivinhado pelo comando |
| `open`      | URL                                         | destino do botão Abrir; `{port}` vira a porta real |
| `env`       | objeto                                      | variáveis de ambiente extras |
| `envFile`   | caminho                                     | arquivo `KEY=valor` para carregar, relativo a `cwd` |
| `health`    | rota ou URL                                 | precisa responder 2xx/3xx para o serviço contar como no ar |
| `autostart` | `true`/`false`                              | sobe quando o Runbar abre |
| `restart`   | `never` `on-crash`                          | reinicia sozinho se cair (até 3 vezes em 2 minutos) |
| `stop`      | texto                                       | comando extra para parar (ex.: `docker compose down`) |
| `autoPort`  | `true`/`false`                              | se a porta estiver ocupada, sobe na próxima livre (padrão: `settings.autoPort`) |

Configurações gerais (opcional):

```json
"settings": { "look": "auto", "shell": "/bin/zsh", "notifyOnCrash": true, "autoPort": false }
```

`look`: `auto` (Liquid Glass no macOS 26+), `solid` ou `glass`.
`autoPort`: padrão para todos os serviços; cada serviço pode sobrescrever.

## Regras

1. `command` roda em `zsh -l -c` dentro de `cwd`. Use o mesmo comando que você
   rodaria no Terminal. Não use `&`, `nohup` nem `npm start &`: o processo tem
   que ficar em primeiro plano, senão o Runbar acha que ele terminou.
2. O shell de login carrega o PATH do Homebrew, mas não ativa venvs. Em Python,
   use o binário do venv: `.venv/bin/uvicorn …`, `.venv/bin/python manage.py …`.
3. Escreva a porta no comando como `{port}`: o Runbar troca pela porta em que o
   serviço vai subir (`npm run dev -- -p {port}`, `pnpm dev -p {port}`,
   `.venv/bin/uvicorn app.main:app --port {port}`). Ele também exporta
   `PORT=<porta>`, que o Next.js respeita.
4. Cada serviço precisa de uma porta diferente. Vários apps Next.js usam 3000
   por padrão: escolha portas livres (3001, 3002…). Se o script do
   `package.json` já fixa a porta (`next dev -p 3100`), chame o binário direto
   para poder trocar: `npx next dev -p {port}` ou `pnpm exec next dev -p {port}`.
5. Porta ocupada: sem `autoPort`, o Runbar não sobe o serviço e diz quem está
   na porta. Com `"autoPort": true`, ele sobe na próxima porta livre, pulando as
   portas dos outros serviços do arquivo. O `{port}` no comando é o que permite
   isso; um número fixo no comando impede (o `runbar validate` avisa).
6. Ids: letras, números, `.`, `_` e `-`. O id de serviço é único no arquivo todo.
   Prefira ids que já identificam o projeto (`acme-web`, `finch-site`).
7. Não remova serviços que já existem sem o usuário pedir, e preserve campos que
   você não entende.
8. Depois de editar, rode `runbar validate`. Ele mostra cada problema com linha e
   coluna. Corrija até não sobrar erro.

## Como descobrir serviços numa pasta

- `package.json` com script `dev` → `npm run dev` (`pnpm dev` se houver
  `pnpm-lock.yaml`, `yarn dev` com `yarn.lock`, `bun dev` com `bun.lockb`).
  Se a dependência `next` existir, `type: "nextjs"`.
- Monorepos (`apps/*`, `packages/*`, `pnpm-workspace.yaml`): um serviço por app
  que sobe servidor, cada um com sua porta.
- `docker-compose.yml`, `compose.yaml` → `docker compose up`,
  `stop: "docker compose down"`, `type: "docker"`, porta = a principal publicada.
- FastAPI → `.venv/bin/uvicorn app.main:app --reload --port {port}`.
  Django → `.venv/bin/python manage.py runserver {port}`. Flask →
  `.venv/bin/flask run --port {port}`.
- O README do projeto costuma dizer o comando de desenvolvimento: confira.
- Ignore pastas sem servidor de desenvolvimento: bibliotecas, scripts que rodam
  e terminam, CLIs, backups.

## Linha de comando

O app instala o comando `runbar` (menu ⋯ → Instalar comando no Terminal).

```
runbar validate [--json]        confere o config.json (linha e coluna de cada erro)
runbar status [--json]          status, porta real, memória e CPU de cada serviço
runbar start <id> [--wait]      sobe um serviço (--wait espera a porta abrir)
runbar stop <id>                para o serviço e os processos filhos
runbar restart <id> [--wait]    reinicia
runbar logs <id> [-n 100] [-f]  saída do serviço
runbar path                     pasta da configuração
```

Os logs ficam em `~/Library/Logs/Runbar/<id>.log`.
"""#
}
