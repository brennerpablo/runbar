import Foundation

public enum Format {
    private static func decimal(_ v: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }

    /// 1,4 GB · 214 MB · 3,2 MB
    public static func memory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1000 { return decimal(mb / 1024, 1) + " GB" }
        if mb >= 10 { return "\(Int(mb.rounded())) MB" }
        return decimal(mb, 1) + " MB"
    }

    /// 2,1% · 140%
    public static func cpu(_ v: Double) -> String {
        decimal(v, v >= 100 ? 0 : 1) + "%"
    }

    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 5 { return "agora" }
        if s < 60 { return "há \(Int(s)) s" }
        if s < 3600 { return "há \(Int(s / 60)) min" }
        if s < 86400 { return "há \(Int(s / 3600)) h" }
        return "há \(Int(s / 86400)) d"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "< 1 min" }
        let m = Int(seconds / 60)
        if m < 60 { return "\(m) min" }
        let h = m / 60
        if h < 24 { return String(format: "%dh %02dm", h, m % 60) }
        return "\(h / 24)d \(h % 24)h"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "d MMM HH:mm"
        return f
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "d MMM yyyy HH:mm:ss"
        return f
    }()

    /// 2 nov 2026 11:39:36
    public static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    /// 12:18 hoje, "1 nov 18:02" em outros dias.
    public static func clock(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) { return timeFormatter.string(from: date) }
        return dayTimeFormatter.string(from: date)
    }
}

public enum TerminalText {
    private static let ansi = try! NSRegularExpression(
        pattern: #"\x1B\[[0-?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B[@-Z\\\-_]"#
    )

    /// Remove cores e códigos de controle do terminal.
    public static func clean(_ s: String) -> String {
        var out = s
        if out.contains("\u{1B}") {
            out = ansi.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        if out.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" }) {
            out = String(String.UnicodeScalarView(out.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" }))
        }
        return out
    }

    /// Divide um bloco de saída em linhas, tratando \r como quebra (barras de progresso).
    public static func lines(from text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { clean(String($0)) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
