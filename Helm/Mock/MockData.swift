import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    var projects: [Project]
    var sessions: [Session]
    var selectedSessionId: UUID?
    var pendingApproval: Bool = false
    var isStreaming: Bool = false
    var showPickerMenu: Bool = false

    init(projects: [Project], sessions: [Session], selectedSessionId: UUID? = nil) {
        self.projects = projects
        self.sessions = sessions
        self.selectedSessionId = selectedSessionId
    }

    var selectedSession: Session? {
        get { sessions.first { $0.id == selectedSessionId } }
        set {
            guard let new = newValue, let idx = sessions.firstIndex(where: { $0.id == new.id }) else { return }
            sessions[idx] = new
        }
    }

    func project(for sessionId: UUID) -> Project? {
        guard let s = sessions.first(where: { $0.id == sessionId }) else { return nil }
        return projects.first { $0.id == s.projectId }
    }

    func sessions(in projectId: UUID) -> [Session] {
        sessions.filter { $0.projectId == projectId }
    }

    func toggleCollapsed(_ projectId: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[i].collapsed.toggle()
    }
}

extension AppStore {
    static func demo() -> AppStore {
        let p1 = Project(id: UUID(), name: "helm", location: .local(path: "~/workspace/helm"))
        let p2 = Project(id: UUID(), name: "ccm",  location: .local(path: "~/workspace/ccm"))
        let p3 = Project(id: UUID(), name: "prod-api",
                         location: .ssh(host: "prod-1", path: "/srv/api", status: .connecting),
                         collapsed: true)

        let s1 = Session(
            id: UUID(),
            projectId: p1.id,
            title: "Wire up ACP adapter for claude -p",
            vendor: .claude,
            model: "Opus 4.7",
            profileName: "super-relay",
            approvalMode: .ask,
            lastUpdate: "2m",
            messages: MockMessages.demoConversation()
        )
        let s2 = Session(
            id: UUID(), projectId: p1.id, title: "Sketch session index schema",
            vendor: .codex, model: "gpt-5", profileName: "default", lastUpdate: "34m"
        )
        let s3 = Session(
            id: UUID(), projectId: p1.id, title: "Rename Helm → Bosun?",
            vendor: .claude, model: "Sonnet 4.6", profileName: "direct", lastUpdate: "2h"
        )
        let s4 = Session(
            id: UUID(), projectId: p2.id, title: "Investigate compaction window",
            vendor: .codex, model: "gpt-5", profileName: "default", lastUpdate: "1d"
        )
        let s5 = Session(
            id: UUID(), projectId: p3.id, title: "Debug 502 spike",
            vendor: .claude, model: "Opus 4.7", profileName: "remote-default", lastUpdate: "3h"
        )

        return AppStore(
            projects: [p1, p2, p3],
            sessions: [s1, s2, s3, s4, s5],
            selectedSessionId: s1.id
        )
    }
}

enum MockMessages {
    static func demoConversation() -> [Message] {
        let userMsg = Message(
            id: UUID(),
            role: .user, who: "deng", meta: "2 min ago",
            parts: [
                .text("""
                Set up an ACP adapter that wraps `claude -p`. Should accept `session/new`, `session/prompt`, stream tool calls as `session/update`. Use stdio transport.
                """)
            ]
        )

        let bashCall = ToolCall(
            id: UUID(),
            name: "Bash",
            arg: "ls -la ~/workspace/helm && cat ~/workspace/helm/package.json 2>/dev/null",
            status: .ok(exit: 0),
            meta: "0.4s",
            body: """
            total 16
            drwxr-xr-x  6 deng staff   192 May 20 15:42 .
            drwxr-xr-x 18 deng staff   576 May 20 15:42 ..
            drwxr-xr-x  3 deng staff    96 May 20 15:40 design/
            drwxr-xr-x  2 deng staff    64 May 20 15:40 docs/
            -rw-r--r--  1 deng staff   492 May 20 15:40 README.md
            (no package.json)
            """
        )

        let diff = Diff(
            id: UUID(),
            path: "adapters/claude-acp/src/index.ts",
            plus: 34, minus: 0,
            lines: [
                .init(lineNo: "+1", kind: .add, text: "import { createServer } from \"@agentclientprotocol/sdk/stdio\";"),
                .init(lineNo: "+2", kind: .add, text: "import { spawn } from \"node:child_process\";"),
                .init(lineNo: "+3", kind: .add, text: "import { randomUUID } from \"node:crypto\";"),
                .init(lineNo: "4",  kind: .context, text: ""),
                .init(lineNo: "+5", kind: .add, text: "const sessions = new Map<string, { cwd: string }>();"),
                .init(lineNo: "+6", kind: .add, text: ""),
                .init(lineNo: "+7", kind: .add, text: "const server = createServer({"),
                .init(lineNo: "+8", kind: .add, text: "  initialize: async () => ({"),
                .init(lineNo: "+9", kind: .add, text: "    protocolVersion: 1,"),
            ]
        )

        let assistant = Message(
            id: UUID(),
            role: .assistant(meta: "thought for 4s"),
            who: "Claude · Opus 4.7", meta: "thought for 4s",
            parts: [
                .text("I'll scaffold a TypeScript package that implements the ACP server over stdio and shells out to `claude -p --output-format stream-json`. Let me first look at what's in `workspace/helm`."),
                .toolCall(bashCall),
                .text("No existing TS scaffold. I'll create one under `adapters/claude-acp`. Here's the plan: pnpm workspace, add `@agentclientprotocol/sdk`, spawn `claude -p` per `session/prompt`, map events."),
                .diff(diff),
                .text("Continuing with `session/prompt` handler…")
            ]
        )

        return [userMsg, assistant]
    }

    static func demoApproval() -> Approval {
        Approval(
            id: UUID(),
            command: "rm -rf node_modules && pnpm install",
            cwd: "~/workspace/helm/adapters/claude-acp"
        )
    }
}
