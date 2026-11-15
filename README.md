# Runbar

App de menu bar do macOS para subir, parar e acompanhar os servidores de desenvolvimento
de todos os projetos (Next.js, APIs Python, docker compose…) num lugar só.

- Lista por projeto com status, porta real, memória e CPU de cada serviço.
- Detalhe com PID, horário de início, último log, gráficos de memória e CPU (30 min) e a saída ao vivo.
- Detecta conflito de porta e quando o Next pula para outra porta; mostra portas ocupadas por processos de fora.
- Reconhece serviços iniciados fora do Runbar (no Terminal, por exemplo) pela pasta do processo.
- Os serviços sobrevivem a reiniciar ou atualizar o Runbar: ele readota os processos ao abrir.
- Dois visuais: sólido e Liquid Glass (automático no macOS 26+).

## Configuração: um JSON que o seu agente consegue escrever

Tudo vem de `~/.config/runbar/config.json`. O app mantém ao lado um `schema.json` e um
`README.md` escrito para agentes, e recarrega sozinho quando o arquivo muda. A janela
"Configurar com agente…" tem um pedido pronto para colar no Claude Code, Codex ou Cursor.

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

O formato completo está em [`Sources/RunbarCore/BundledDocs.swift`](Sources/RunbarCore/BundledDocs.swift)
(é o mesmo texto que o app grava em `~/.config/runbar/README.md`).

## Linha de comando

```
runbar validate [--json]        confere o config.json (linha e coluna de cada erro)
runbar status [--json]          status, porta real, memória e CPU
runbar start <id> [--wait]      sobe um serviço (--wait espera a porta abrir)
runbar stop <id>                para o serviço e os processos filhos
runbar restart <id> [--wait]
runbar logs <id> [-n 100] [-f]
runbar reload | path
```

Se o app estiver fechado, `start`, `stop` e `restart` abrem o app primeiro.

## Compilar e instalar

Precisa só do Command Line Tools (não precisa do Xcode).

```
make app       # build/Runbar.app
make install   # instala em ~/Applications, liga o comando runbar no PATH e abre o app
make build     # swift build (debug)
```

Para desinstalar: feche o Runbar, apague `~/Applications/Runbar.app` e o link `runbar`
(em `/opt/homebrew/bin`, `/usr/local/bin` ou `~/.local/bin`). A configuração fica em
`~/.config/runbar`, os logs em `~/Library/Logs/Runbar`.

### Revisar o visual sem clicar na menu bar

```
.build/debug/RunbarApp --snapshot /tmp/runbar-snap [id-do-serviço]
```

Desenha o popover (lista e detalhe, sólido e Liquid Glass, claro e escuro) e a janela do
agente em PNG, com os dados reais. Não abre socket nem mexe em serviços.

## Como funciona

| peça | onde |
|------|------|
| Parser JSON com linha/coluna e validação do config | `Sources/RunbarCore/JSON.swift`, `Config.swift` |
| Processos: árvore, memória (phys_footprint), CPU, portas em LISTEN, pasta | `Sources/RunbarCore/ProcScanner.swift` (libproc) |
| Subir serviço: login shell, grupo de processos próprio, saída no arquivo de log | `Sources/RunbarCore/Spawner.swift` |
| Socket Unix entre o CLI e o app | `Sources/RunbarCore/Control.swift` |
| Estado de cada serviço, readoção, reinício automático | `Sources/RunbarApp/ServiceRuntime.swift` |
| Modelo do app, monitoramento a cada 2 s, detecção de conflito | `Sources/RunbarApp/AppModel.swift`, `Display.swift` |
| Interface | `Sources/RunbarApp/PopoverView.swift`, `ServiceDetailView.swift`, `AgentView.swift` |

O `@State` do SwiftUI virou macro no SDK do macOS 27 e o plugin só vem com o Xcode; por isso
as views usam `@ViewState` (`Sources/RunbarApp/ViewState.swift`), que faz o mesmo com o tipo `State`.
