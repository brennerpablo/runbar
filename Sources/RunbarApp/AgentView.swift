import AppKit
import RunbarCore
import SwiftUI

enum AgentPrompt {
    static func setup(root: String) -> String {
        """
        Configure o Runbar para os meus projetos em \(root).

        Leia ~/.config/runbar/README.md e edite ~/.config/runbar/config.json seguindo o ~/.config/runbar/schema.json. Para cada app que sobe um servidor de desenvolvimento (Next.js, APIs Python, docker compose…), adicione um serviço com a pasta, o comando e uma porta que não colida com as outras. Mantenha o que já existe no arquivo e rode `runbar validate` no fim.
        """
    }

    static func fixError(_ issue: ConfigIssue) -> String {
        let loc = issue.line > 0 ? "linha \(issue.line), coluna \(issue.column)" : "posição desconhecida"
        return "O ~/.config/runbar/config.json está inválido (\(loc)): \(issue.message). Corrija o arquivo seguindo ~/.config/runbar/README.md e rode `runbar validate` até não sobrar erro."
    }
}

struct AgentView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var root = ""
    @ViewState private var copied = false
    @ViewState private var cliMessage: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Peça para o seu agente configurar")
                        .font(.system(size: 20, weight: .semibold))
                    Text("O Runbar lê tudo de um arquivo JSON. Qualquer agente que edita arquivos no seu Mac consegue montar a configuração inteira, e o Runbar recarrega assim que o arquivo muda.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                step(1, "Copie o pedido") {
                    HStack(spacing: 8) {
                        Text("Pasta dos projetos").font(.system(size: 12.5))
                        TextField("~/Documents/repos", text: $root)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onChange(of: root) { copied = false }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(AgentPrompt.setup(root: root.isEmpty ? model.suggestedRoot : root))
                            .font(.system(size: 12.5))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Pasteboard.copy(AgentPrompt.setup(root: root.isEmpty ? model.suggestedRoot : root))
                            copied = true
                        } label: {
                            Label(copied ? "Copiado" : "Copiar pedido", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(14)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                }

                step(2, "Cole no seu agente") {
                    Text("Claude Code, Codex, Cursor ou outro com acesso aos seus arquivos. Ele lê o README.md, varre as pastas e escreve o config.json.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                step(3, "Confira aqui") { status }
            }
            .padding(28)
            .frame(width: 580, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 22) {
                sidebarSection("Em ~/.config/runbar") {
                    fileRow("config.json", "Sua configuração. Você, o agente e o app editam o mesmo arquivo.")
                    fileRow("schema.json", "JSON Schema para validar e ter autocomplete no editor.")
                    fileRow("README.md", "Instruções escritas para agentes: formato, regras de porta, exemplos.")
                    Button("Mostrar no Finder") { model.revealConfigDir() }.controlSize(.small)
                }
                sidebarSection("No terminal") {
                    fileRow("runbar validate", "Confere o arquivo e aponta o erro com linha e coluna.")
                    fileRow("runbar status --json", "Status, porta real, memória e CPU de cada serviço.")
                    fileRow("runbar start · stop · logs <id>", "O agente também sobe serviços e lê os logs para testar o que mudou.")
                    if let installed = model.cliInstalledPath {
                        Text("Instalado em \(Paths.abbreviate(installed))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Instalar comando runbar") { cliMessage = model.installCLI() }.controlSize(.small)
                    }
                    if let cliMessage {
                        Text(cliMessage).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(width: 300, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.primary.opacity(0.03))
        }
        .frame(minHeight: 600)
        .onAppear { if root.isEmpty { root = model.suggestedRoot } }
    }

    @ViewBuilder
    private var status: some View {
        if let issue = model.configError {
            VStack(alignment: .leading, spacing: 8) {
                Label("config.json com erro", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.rbWarn)
                Text("\(issue.location.isEmpty ? "" : issue.location + ": ")\(issue.message)")
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Copiar erro para o agente") { Pasteboard.copy(AgentPrompt.fixError(issue)) }
                    Button("Abrir config.json") { model.openConfigFile() }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.rbOrange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle().fill(Color.rbGreen).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("config.json válido").font(.system(size: 13, weight: .semibold))
                        Text(validLine).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Abrir config.json") { model.openConfigFile() }.controlSize(.small)
                }
                ForEach(model.configWarnings.prefix(4), id: \.description) { w in
                    Text("aviso: \(w.message)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.rbWarn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.rbGreen.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var validLine: String {
        let s = model.config.services.count
        let p = model.config.projects.count
        let when = model.configLoadedAt.map { " · lido às \(Format.clock($0))" } ?? ""
        return "\(s) \(s == 1 ? "serviço" : "serviços") em \(p) \(p == 1 ? "projeto" : "projetos")\(when)"
    }

    private func step<Content: View>(_ n: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 14, weight: .semibold)).padding(.top, 3)
                content()
            }
        }
    }

    private func sidebarSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func fileRow(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
