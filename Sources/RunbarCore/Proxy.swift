import Foundation

/// Tools that forward a local port to something remote. Runbar recognizes them in a proxy's command to
/// name them, and to tell an expired sign-in from any other failure.
public enum ProxyTool: String, Sendable, Equatable {
    case cloudSQL, alloyDB, kubectl, ssh, awsSSM, other

    public static func detect(_ command: String) -> ProxyTool {
        let c = command.lowercased()
        if c.contains("cloud-sql-proxy") || c.contains("cloud_sql_proxy") { return .cloudSQL }
        if c.contains("alloydb-auth-proxy") { return .alloyDB }
        if c.contains("kubectl"), c.contains("port-forward") { return .kubectl }
        if c.contains("aws ssm start-session") { return .awsSSM }
        // Case matters here: -L forwards a port, -l is the login name.
        if command.range(of: #"(^|[\s/])ssh\s(.*\s)?-[A-Za-z]*L"#, options: .regularExpression) != nil { return .ssh }
        return .other
    }

    /// "Cloud SQL proxy", for the detail header.
    public var label: String {
        switch self {
        case .cloudSQL: return "Cloud SQL proxy"
        case .alloyDB: return "AlloyDB proxy"
        case .kubectl: return "kubectl port-forward"
        case .ssh: return "SSH tunnel"
        case .awsSSM: return "AWS SSM tunnel"
        case .other: return "Proxy"
        }
    }

    /// "Cloud SQL", for the row's second line.
    public var shortLabel: String {
        switch self {
        case .cloudSQL: return "Cloud SQL"
        case .alloyDB: return "AlloyDB"
        case .kubectl: return "kubectl"
        case .ssh: return "SSH"
        case .awsSSM: return "AWS SSM"
        case .other: return "Proxy"
        }
    }

    /// Who the user signs in to, in "Your … sign-in expired".
    public var account: String? {
        switch self {
        case .cloudSQL, .alloyDB: return "Google Cloud"
        case .awsSSM: return "AWS"
        default: return nil
        }
    }

    /// The command that renews the sign-in, run in Terminal.
    public var signInCommand: String? {
        switch self {
        case .cloudSQL, .alloyDB: return "gcloud auth application-default login"
        case .awsSSM: return "aws sso login"
        default: return nil
        }
    }

    /// File (or folder) that changes when the user signs in again: Runbar reopens the proxy then.
    public var credentialsPath: String? {
        switch self {
        case .cloudSQL, .alloyDB: return Paths.home + "/.config/gcloud/application_default_credentials.json"
        case .awsSSM: return Paths.home + "/.aws/sso/cache"
        default: return nil
        }
    }

    /// A log line that means the sign-in expired or is missing.
    public func isSignInProblem(_ line: String) -> Bool {
        let l = line.lowercased()
        let needles: [String]
        switch self {
        case .cloudSQL, .alloyDB:
            needles = ["invalid_grant", "invalid_rapt", "reauth related error", "could not find default credentials",
                       "oauth2: cannot fetch token", "token has been expired or revoked", "reauthentication failed"]
        case .awsSSM:
            needles = ["expiredtoken", "token has expired", "unable to locate credentials", "error when retrieving token from sso"]
        default:
            return false
        }
        return needles.contains { l.contains($0) }
    }
}

/// How long a proxy may sit with no connections before Runbar closes it.
public enum IdleSetting: Equatable, Sendable {
    case never
    case after(TimeInterval)
    case invalid

    /// A proxy without `idle` closes after 15 minutes with no connections.
    public static let defaultSeconds: TimeInterval = 15 * 60

    /// The choices the detail view offers, as written in config.json.
    public static let presets = ["5m", "15m", "1h", "never"]

    /// "90s", "15m", "1h", "never".
    public static func parse(_ text: String) -> IdleSetting {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "never" { return .never }
        guard let unit = t.last, let n = Double(t.dropLast()), n > 0 else { return .invalid }
        switch unit {
        case "s": return .after(n)
        case "m": return .after(n * 60)
        case "h": return .after(n * 3600)
        default: return .invalid
        }
    }

    /// Seconds as config.json writes them: "15m", "1h", "90s".
    public static func text(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "never" }
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(seconds / 3600))h" }
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds))s"
    }

    /// Seconds as a person reads them: "15 min", "1 hour".
    public static func human(_ seconds: TimeInterval) -> String {
        if seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 {
            let h = Int(seconds / 3600)
            return h == 1 ? "1 hour" : "\(h) hours"
        }
        if seconds >= 60 { return "\(Int((seconds / 60).rounded())) min" }
        return "\(Int(seconds)) s"
    }
}
