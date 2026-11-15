import Foundation

/// Posição (1-based) de um trecho no arquivo JSON.
public struct JSONPosition: Equatable, Sendable {
    public var line: Int
    public var column: Int
    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

/// Objeto JSON que preserva a ordem das chaves (a ordem do arquivo é a ordem do menu).
public struct JSONObject: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var value: JSON
        public var position: JSONPosition
    }

    public var entries: [Entry]

    public init(_ entries: [Entry] = []) {
        self.entries = entries
    }

    public var keys: [String] { entries.map(\.key) }
    public var isEmpty: Bool { entries.isEmpty }

    public subscript(key: String) -> JSON? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append(Entry(key: key, value: newValue, position: JSONPosition(line: 0, column: 0)))
            }
        }
    }

    public func position(of key: String) -> JSONPosition? {
        entries.first { $0.key == key }?.position
    }
}

public indirect enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)

    public var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Nome do tipo em português, para mensagens de erro.
    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "true/false"
        case .number: return "número"
        case .string: return "texto"
        case .array: return "lista"
        case .object: return "objeto"
        }
    }
}

public struct JSONParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var line: Int
    public var column: Int
    public var description: String { "linha \(line), coluna \(column): \(message)" }
}

/// Parser JSON estrito, com mensagens em português e linha/coluna exatas.
public struct JSONParser {
    private let b: [UInt8]
    private var i = 0
    private var line = 1
    private var col = 1

    private init(_ bytes: [UInt8]) { b = bytes }

    public static func parse(_ data: Data) throws -> JSON {
        var p = JSONParser([UInt8](data))
        if p.b.count >= 3, p.b[0] == 0xEF, p.b[1] == 0xBB, p.b[2] == 0xBF { p.i = 3 }
        try p.skipSpace()
        guard p.i < p.b.count else { throw p.fail("o arquivo está vazio") }
        let value = try p.value()
        try p.skipSpace()
        if p.i < p.b.count { throw p.fail("texto sobrando depois do fim do JSON") }
        return value
    }

    public static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    private var cur: UInt8? { i < b.count ? b[i] : nil }
    private var here: JSONPosition { JSONPosition(line: line, column: col) }

    private mutating func step() {
        let c = b[i]
        i += 1
        if c == 0x0A {
            line += 1
            col = 1
        } else if c & 0xC0 != 0x80 {
            col += 1
        }
    }

    private func fail(_ message: String) -> JSONParseError {
        JSONParseError(message: message, line: line, column: col)
    }

    private func describe(_ c: UInt8) -> String {
        if c >= 0x21 && c < 0x7F { return "'\(Character(Unicode.Scalar(c)))'" }
        return "um caractere inesperado"
    }

    private mutating func skipSpace() throws {
        while let c = cur {
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D:
                step()
            case 0x2F:
                let next = i + 1 < b.count ? b[i + 1] : 0
                if next == 0x2F || next == 0x2A { throw fail("JSON não aceita comentários (// ou /* */)") }
                return
            default:
                return
            }
        }
    }

    private mutating func value() throws -> JSON {
        guard let c = cur else { throw fail("o arquivo terminou no meio de um valor") }
        switch c {
        case 0x7B: return try object()
        case 0x5B: return try array()
        case 0x22: return .string(try string())
        case 0x74: try word("true"); return .bool(true)
        case 0x66: try word("false"); return .bool(false)
        case 0x6E: try word("null"); return .null
        case 0x2D, 0x30...0x39: return .number(try number())
        case 0x27: throw fail("use aspas duplas (\") em vez de aspas simples")
        default: throw fail("valor inesperado: \(describe(c))")
        }
    }

    private mutating func word(_ w: String) throws {
        for expected in w.utf8 {
            guard cur == expected else { throw fail("valor inválido; quis dizer \(w)?") }
            step()
        }
    }

    private mutating func object() throws -> JSON {
        step()
        var obj = JSONObject()
        try skipSpace()
        if cur == 0x7D {
            step()
            return .object(obj)
        }
        while true {
            try skipSpace()
            guard let c = cur else { throw fail("faltou fechar o objeto com }") }
            if c == 0x7D { throw fail("vírgula sobrando antes de }") }
            if c == 0x27 { throw fail("use aspas duplas nas chaves") }
            guard c == 0x22 else { throw fail("esperava uma chave entre aspas duplas, encontrei \(describe(c))") }
            let pos = here
            let key = try string()
            if obj.entries.contains(where: { $0.key == key }) {
                throw JSONParseError(message: "a chave \"\(key)\" aparece duas vezes no mesmo objeto", line: pos.line, column: pos.column)
            }
            try skipSpace()
            guard cur == 0x3A else { throw fail("esperava : depois de \"\(key)\"") }
            step()
            try skipSpace()
            let v = try value()
            obj.entries.append(JSONObject.Entry(key: key, value: v, position: pos))
            try skipSpace()
            guard let n = cur else { throw fail("faltou fechar o objeto com }") }
            switch n {
            case 0x2C: step()
            case 0x7D: step(); return .object(obj)
            case 0x22: throw fail("faltou uma vírgula antes desta chave")
            default: throw fail("esperava , ou } e encontrei \(describe(n))")
            }
        }
    }

    private mutating func array() throws -> JSON {
        step()
        var items: [JSON] = []
        try skipSpace()
        if cur == 0x5D {
            step()
            return .array(items)
        }
        while true {
            try skipSpace()
            guard let c = cur else { throw fail("faltou fechar a lista com ]") }
            if c == 0x5D { throw fail("vírgula sobrando antes de ]") }
            items.append(try value())
            try skipSpace()
            guard let n = cur else { throw fail("faltou fechar a lista com ]") }
            switch n {
            case 0x2C: step()
            case 0x5D: step(); return .array(items)
            default: throw fail("faltou uma vírgula entre os itens da lista")
            }
        }
    }

    private mutating func string() throws -> String {
        step()
        var out: [UInt8] = []
        while true {
            guard let c = cur else { throw fail("texto sem aspas de fechamento") }
            if c == 0x22 {
                step()
                break
            }
            if c == 0x0A { throw fail("quebra de linha dentro de um texto; use \\n") }
            if c < 0x20 { throw fail("caractere de controle dentro de um texto") }
            if c == 0x5C {
                step()
                guard let e = cur else { throw fail("texto sem aspas de fechamento") }
                switch e {
                case 0x22: out.append(0x22)
                case 0x5C: out.append(0x5C)
                case 0x2F: out.append(0x2F)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x75:
                    step()
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        guard cur == 0x5C, i + 1 < b.count, b[i + 1] == 0x75 else { throw fail("sequência \\u incompleta") }
                        step()
                        step()
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw fail("sequência \\u inválida") }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let u = Unicode.Scalar(scalar) else { throw fail("sequência \\u inválida") }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                    continue
                default:
                    throw fail("escape inválido \\\(describe(e))")
                }
                step()
                continue
            }
            out.append(c)
            step()
        }
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func hex4() throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 {
            guard let c = cur else { throw fail("sequência \\u incompleta") }
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw fail("sequência \\u inválida")
            }
            v = v * 16 + d
            step()
        }
        return v
    }

    private mutating func number() throws -> Double {
        let start = i
        let startPos = here
        while let c = cur, (0x30...0x39).contains(c) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45 {
            step()
        }
        let text = String(decoding: b[start..<i], as: UTF8.self)
        let grammar = #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#
        guard let d = Double(text), text.range(of: grammar, options: .regularExpression) != nil else {
            throw JSONParseError(message: "número inválido: \(text)", line: startPos.line, column: startPos.column)
        }
        return d
    }
}

// MARK: - Serialização (2 espaços, igual ao JSON.stringify(obj, null, 2))

public extension JSON {
    func prettyPrinted() -> String {
        var s = ""
        JSON.write(self, level: 0, into: &s)
        s.append("\n")
        return s
    }

    private static func pad(_ level: Int) -> String { String(repeating: "  ", count: level) }

    private static func write(_ v: JSON, level: Int, into s: inout String) {
        switch v {
        case .null:
            s += "null"
        case .bool(let flag):
            s += flag ? "true" : "false"
        case .number(let d):
            if d.rounded() == d, abs(d) < 1e15 { s += String(Int64(d)) } else { s += String(d) }
        case .string(let text):
            s += quote(text)
        case .array(let items):
            if items.isEmpty {
                s += "[]"
                return
            }
            let simple = items.allSatisfy {
                switch $0 {
                case .object, .array: return false
                default: return true
                }
            }
            if simple {
                let parts = items.map { item -> String in
                    var p = ""
                    write(item, level: 0, into: &p)
                    return p
                }
                let inline = "[" + parts.joined(separator: ", ") + "]"
                if inline.count <= 72 {
                    s += inline
                    return
                }
            }
            s += "[\n"
            for (k, item) in items.enumerated() {
                s += pad(level + 1)
                write(item, level: level + 1, into: &s)
                s += k == items.count - 1 ? "\n" : ",\n"
            }
            s += pad(level) + "]"
        case .object(let o):
            if o.entries.isEmpty {
                s += "{}"
                return
            }
            s += "{\n"
            for (k, e) in o.entries.enumerated() {
                s += pad(level + 1) + quote(e.key) + ": "
                write(e.value, level: level + 1, into: &s)
                s += k == o.entries.count - 1 ? "\n" : ",\n"
            }
            s += pad(level) + "}"
        }
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
