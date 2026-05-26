import Darwin
import Foundation

fileprivate func processOutput(_ executable: String, arguments: [String]) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = arguments

    let stdout = Pipe()
    proc.standardOutput = stdout
    proc.standardError = Pipe()

    do {
        try proc.run()
    } catch {
        return ""
    }

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

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

    /// Whether this adapter can accept additional user guidance while a turn is
    /// already running.
    var supportsPromptAppend: Bool { get }

    /// Send an additional user message into the active turn. Adapters that
    /// cannot steer an active turn should leave the default implementation.
    func append(prompt: String, attachments: [ImageAttachment]) throws

    /// Best-effort cancellation. Adapters should SIGTERM the child and let
    /// the stream finish with `.error("cancelled")` or similar.
    func cancel()

    /// Respond to an in-flight approval request previously emitted as
    /// `.approvalRequest`. Adapters that do not have a bidirectional protocol can
    /// ignore this; app-server based adapters should send a JSON-RPC response.
    func respondToApproval(id: String, decision: AgentApprovalDecision)
}

extension AgentAdapter {
    var supportsPromptAppend: Bool { false }
    func append(prompt: String, attachments: [ImageAttachment]) throws {
        throw AdapterError.promptAppendUnsupported
    }

    func respondToApproval(id: String, decision: AgentApprovalDecision) {}
}

enum ProcessTreeTerminator {
    static func terminate(_ process: Process,
                          closing stdin: FileHandle? = nil,
                          trackedDescendants: [Int32] = [],
                          killAfter grace: TimeInterval = 1.5) {
        let pid = process.processIdentifier
        terminate(pids: descendantPIDs(of: pid) + trackedDescendants, signal: SIGTERM)
        if process.isRunning {
            process.terminate()
        }
        try? stdin?.close()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            terminate(pids: descendantPIDs(of: pid) + trackedDescendants, signal: SIGKILL)
            if process.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }

    static func terminate(pids: [Int32], killAfter grace: TimeInterval = 1.5) {
        terminate(pids: pids, signal: SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            terminate(pids: pids, signal: SIGKILL)
        }
    }

    static func descendantPIDs(of root: Int32) -> [Int32] {
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
        let text = processOutput("/bin/ps", arguments: ["-axo", "pid=,ppid="])
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

    private static func terminate(pids: [Int32], signal: Int32) {
        var seen = Set<Int32>()
        for pid in pids.reversed() where pid > 1 && !seen.contains(pid) {
            seen.insert(pid)
            Darwin.kill(pid, signal)
        }
    }
}

final class ProcessDescendantTracker: @unchecked Sendable {
    private let rootPID: Int32
    private let interval: DispatchTimeInterval
    private let excludedCommandSubstrings: [String]
    private let queue = DispatchQueue(label: "dev.deng.helm.process-descendant-tracker",
                                      qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var knownPIDs: Set<Int32> = []

    init(process: Process,
         interval: DispatchTimeInterval = .milliseconds(250),
         excludedCommandSubstrings: [String] = ["SkyComputerUseService"]) {
        self.rootPID = process.processIdentifier
        self.interval = interval
        self.excludedCommandSubstrings = excludedCommandSubstrings
    }

    func start() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { [weak self] in
            self?.recordSnapshot()
        }
        lock.lock()
        timer = source
        lock.unlock()
        source.resume()
    }

    func stop() -> [Int32] {
        recordSnapshot()
        lock.lock()
        let source = timer
        timer = nil
        let snapshot = Array(knownPIDs)
        knownPIDs.removeAll()
        lock.unlock()
        source?.cancel()
        return snapshot
    }

    private func recordSnapshot() {
        var descendants = ProcessTreeTerminator.descendantPIDs(of: rootPID)
            .filter { $0 != rootPID }
        if !excludedCommandSubstrings.isEmpty {
            let commands = processCommandMap(for: descendants)
            descendants = descendants.filter { pid in
                guard let command = commands[pid] else { return true }
                return !excludedCommandSubstrings.contains { command.contains($0) }
            }
        }
        guard !descendants.isEmpty else { return }
        lock.lock()
        knownPIDs.formUnion(descendants)
        lock.unlock()
    }

    private func processCommandMap(for pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.map(String.init).joined(separator: ",")
        let text = processOutput("/bin/ps", arguments: ["-p", pidList, "-o", "pid=,command="])
        var map: [Int32: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(String(trimmed[..<firstSpace]).trimmingCharacters(in: .whitespaces))
            else { continue }
            map[pid] = String(trimmed[firstSpace...]).trimmingCharacters(in: .whitespaces)
        }
        return map
    }
}
