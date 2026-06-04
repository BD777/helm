import Foundation

/// Best-effort parser for shell snippets that set env vars before invoking
/// `claude` / `codex`. Designed for pasting a function body like:
///
/// ```
/// claude-relay() {
///   ANTHROPIC_BASE_URL="https://api-proxy.example.com" \
///   ANTHROPIC_AUTH_TOKEN="plat_..." \
///   ANTHROPIC_MODEL="provider-model-id" \
///   claude "$@"
/// }
/// ```
///
/// Also accepts loose `export FOO=bar` lines, bare `FOO=bar` pairs, and a
/// trailing `<command> "$@"` to recover commandPath.
enum ShellEnvParser {
    struct Parsed: Equatable {
        var env: [String: String] = [:]
        var commandPath: String? = nil
    }

    static func parse(_ raw: String) -> Parsed {
        var out = Parsed()

        // Glue line-continuations together first.
        let joined = raw
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "\\\r\n", with: " ")

        for rawLine in joined.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasSuffix("{") || line == "}" { continue }
            if line.hasPrefix("function ") { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }

            // Walk the line collecting `NAME=VALUE` pairs, then check whether
            // there's a trailing command word.
            var remainder = line[...]
            while let (name, value, rest) = takeAssignment(remainder) {
                out.env[name] = value
                remainder = rest.drop(while: { $0 == " " || $0 == "\t" })
            }

            // Whatever is left on the line: a command being invoked with the env.
            let tail = remainder.trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty, let cmd = tail.split(whereSeparator: { $0 == " " }).first {
                let candidate = String(cmd)
                if candidate != "&&" && candidate != "||" && !candidate.hasPrefix("$") {
                    out.commandPath = candidate
                }
            }
        }

        return out
    }

    // MARK: -

    /// Match a single `NAME=VALUE` at the start of `s`, where VALUE may be
    /// `"…"`, `'…'`, or an unquoted run of non-space chars. Returns the parsed
    /// pair and the substring after it.
    private static func takeAssignment(_ s: Substring) -> (String, String, Substring)? {
        let trimmed = s.drop(while: { $0 == " " || $0 == "\t" })
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let nameSlice = trimmed[trimmed.startIndex..<eq]
        let name = String(nameSlice)
        guard isValidEnvName(name) else { return nil }

        var i = trimmed.index(after: eq)
        guard i < trimmed.endIndex else {
            return (name, "", trimmed[i..<trimmed.endIndex])
        }

        let first = trimmed[i]
        if first == "\"" || first == "'" {
            let quote = first
            i = trimmed.index(after: i)
            guard let end = trimmed[i...].firstIndex(of: quote) else { return nil }
            let value = String(trimmed[i..<end])
            let after = trimmed.index(after: end)
            return (name, value, trimmed[after..<trimmed.endIndex])
        } else {
            let end = trimmed[i...].firstIndex(where: { $0 == " " || $0 == "\t" }) ?? trimmed.endIndex
            let value = String(trimmed[i..<end])
            return (name, value, trimmed[end..<trimmed.endIndex])
        }
    }

    private static func isValidEnvName(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
