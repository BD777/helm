import Darwin
import Foundation

func jsonErrorIsPresent(_ value: Any?) -> Bool {
    switch value {
    case nil:
        return false
    case is NSNull:
        return false
    case let text as String:
        return !text.isEmpty
    case let object as [String: Any]:
        return !object.isEmpty
    default:
        return true
    }
}

enum SSHRemote {
    static let executable = "/usr/bin/ssh"
    private static let pathPrefix = [
        "$HOME/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ].joined(separator: ":")

    static func arguments(host: String,
                          remoteCommand: String,
                          batchMode: Bool,
                          connectTimeout: Int? = nil) -> [String] {
        var args = ["-T"]
        if batchMode {
            args.append(contentsOf: ["-o", "BatchMode=yes"])
        }
        if let connectTimeout {
            args.append(contentsOf: ["-o", "ConnectTimeout=\(connectTimeout)"])
        }
        args.append(host)
        args.append(remoteCommand)
        return args
    }

    static func commandLine(command: String,
                            args: [String],
                            env: [String: String],
                            workingDirectory: String) -> String {
        let cd = "cd -- \(shellPath(workingDirectory))"
        let exportPath = "export PATH=\(pathPrefix):${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
        let executable = shellQuote(command)
        let argv = ([executable] + args.map(shellQuote)).joined(separator: " ")
        let envPairs = env
            .sorted { $0.key < $1.key }
            .map { shellQuote("\($0.key)=\($0.value)") }

        let run = envPairs.isEmpty
            ? argv
            : "env \(envPairs.joined(separator: " ")) \(argv)"
        return "\(cd) && \(exportPath) && \(run)"
    }

    static func shellPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" {
            return "$HOME"
        }
        if trimmed.hasPrefix("~/") {
            return "$HOME" + shellQuote(String(trimmed.dropFirst()))
        }
        return shellQuote(trimmed)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct SSHDirectoryListing: Sendable {
    let resolvedPath: String
    let directories: [String]
}

struct SSHRemoteError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

enum SSHDirectoryBrowser {
    static func list(host: String, path: String) async throws -> SSHDirectoryListing {
        try await Task.detached(priority: .utility) {
            let command = """
            cd -- \(SSHRemote.shellPath(path)) && \
            printf '__HELM_PWD__%s\\n' "$(pwd -P)" && \
            find . -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sed 's#^\\./##' | LC_ALL=C sort -f | awk '!/^\\./ { print } /^\\./ { hidden[++n] = $0 } END { for (i = 1; i <= n; i++) print hidden[i] }' | head -n 200
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: SSHRemote.executable)
            proc.arguments = SSHRemote.arguments(
                host: host,
                remoteCommand: command,
                batchMode: true,
                connectTimeout: 8
            )

            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr

            do {
                try proc.run()
            } catch {
                throw SSHRemoteError(message: error.localizedDescription)
            }
            proc.waitUntilExit()

            let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
            let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
            guard proc.terminationStatus == 0 else {
                let reason = lastNonEmptyLine(stderrText) ?? lastNonEmptyLine(stdoutText)
                throw SSHRemoteError(message: reason?.isEmpty == false ? reason! : "ssh exited \(proc.terminationStatus)")
            }

            let lines = stdoutText.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard let markerIndex = lines.firstIndex(where: { $0.hasPrefix("__HELM_PWD__") }) else {
                throw SSHRemoteError(message: "Remote directory listing returned no path.")
            }

            let resolvedPath = String(lines[markerIndex].dropFirst("__HELM_PWD__".count))
            let directories = lines.dropFirst(markerIndex + 1)
                .filter { !$0.isEmpty && $0 != "." }
            return SSHDirectoryListing(resolvedPath: resolvedPath,
                                       directories: Array(directories))
        }.value
    }

    private static func lastNonEmptyLine(_ raw: String) -> String? {
        raw.split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Events the UI cares about — vendor-agnostic. Concrete adapters translate
/// their wire format into this stream.
enum AgentEvent: Sendable {
    /// Vendor session id, surfaced as soon as the agent reports it. Helm
    /// stores this on `Session.vendorSessionId` to enable resume.
    case sessionId(String)

    /// Assistant text increment (a `text_delta` from Claude, an output_text
    /// delta from Codex, etc).
    case assistantTextDelta(String)

    /// One assistant tool invocation begins. `input` is the raw JSON snapshot
    /// available at the start (may be empty — fills in via `toolInputDelta`).
    case toolCallStart(id: String, name: String, input: String)

    /// Streaming JSON fragment for the in-flight tool call.
    case toolInputDelta(id: String, fragment: String)

    /// Result of a tool call (from the agent's own tool runner — not Helm's).
    case toolResult(id: String, output: String, isError: Bool)

    /// The agent runtime needs a user decision before it can continue.
    case approvalRequest(AgentApprovalRequest)

    /// A previously-surfaced approval request has been resolved elsewhere.
    case approvalResolved(id: String)

    /// One assistant message completes.
    case messageStop

    /// Turn finished. `text` is the final result text the agent reports.
    case finalResult(text: String, isError: Bool)

    /// Surfaced when the adapter or child process errors out.
    case error(String)
}

struct AgentApprovalRequest: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case command
        case fileChange
        case mcpElicitation
        case permissions
        case userInput
        case other
    }

    let id: String
    let kind: Kind
    let title: String
    let message: String
    let detail: String?
    let allowsSessionApproval: Bool
}

enum AgentApprovalDecision: Sendable {
    case accept
    case acceptForSession
    case decline
    case cancel
}

protocol AgentAdapter: AnyObject {
    /// Where this vendor keeps its sessions on disk + how to enumerate / read
    /// them. `AppStore` uses this to lazily load history when a session is
    /// opened, instead of persisting messages itself.
    var sessionStore: AgentSessionStore { get }

    /// Spawn the agent and stream events back. The returned stream finishes
    /// when the agent exits; throwing tears the conversation down.
    func start(prompt: String,
               attachments: [ImageAttachment],
               session: Session,
               run: RunConfig,
               project: Project) throws -> AsyncThrowingStream<AgentEvent, Error>

    /// Best-effort cancellation. Adapters should SIGTERM the child and let
    /// the stream finish with `.error("cancelled")` or similar.
    func cancel()

    /// Respond to an in-flight approval request previously emitted as
    /// `.approvalRequest`. Adapters that do not have a bidirectional protocol can
    /// ignore this; app-server based adapters should send a JSON-RPC response.
    func respondToApproval(id: String, decision: AgentApprovalDecision)
}

extension AgentAdapter {
    func respondToApproval(id: String, decision: AgentApprovalDecision) {}
}

enum ProcessTreeTerminator {
    static func terminate(_ process: Process,
                          closing stdin: FileHandle? = nil,
                          killAfter grace: TimeInterval = 1.5) {
        let pid = process.processIdentifier
        let descendants = descendantPIDs(of: pid)
        for child in descendants.reversed() {
            Darwin.kill(child, SIGTERM)
        }
        if process.isRunning {
            process.terminate()
        }
        try? stdin?.close()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            let remaining = descendantPIDs(of: pid)
            for child in remaining.reversed() {
                Darwin.kill(child, SIGKILL)
            }
            if process.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }

    private static func descendantPIDs(of root: Int32) -> [Int32] {
        let childrenByParent = processParentMap()
        var out: [Int32] = []

        func visit(_ pid: Int32) {
            for child in childrenByParent[pid] ?? [] {
                out.append(child)
                visit(child)
            }
        }

        visit(root)
        return out
    }

    private static func processParentMap() -> [Int32: [Int32]] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,ppid="]

        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()

        do {
            try proc.run()
        } catch {
            return [:]
        }
        proc.waitUntilExit()

        let text = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        var map: [Int32: [Int32]] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2,
                  let pid = Int32(String(parts[0])),
                  let ppid = Int32(String(parts[1]))
            else { continue }
            map[ppid, default: []].append(pid)
        }
        return map
    }
}
