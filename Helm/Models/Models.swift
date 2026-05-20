import SwiftUI

enum Vendor: String, CaseIterable, Codable, Hashable {
    case claude
    case codex

    var shortLabel: String {
        switch self {
        case .claude: return "CC"
        case .codex:  return "Cx"
        }
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }

    var badgeColor: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.45, blue: 0.04)
        case .codex:  return Color(red: 0.18, green: 0.22, blue: 0.28)
        }
    }
}

enum ProjectLocation: Hashable {
    case local(path: String)
    case ssh(host: String, path: String, status: SSHStatus)

    var pathString: String {
        switch self {
        case .local(let p): return p
        case .ssh(_, let p, _): return p
        }
    }

    var subtitle: String {
        switch self {
        case .local: return "local"
        case .ssh(let host, _, _): return "ssh \(host)"
        }
    }
}

enum SSHStatus: Hashable {
    case connected
    case connecting
    case failed(reason: String)

    var color: Color {
        switch self {
        case .connected:  return .green
        case .connecting: return .yellow
        case .failed:     return .red
        }
    }
}

struct Profile: Identifiable, Hashable {
    let id: UUID
    var name: String
    var vendor: Vendor
    var subtitle: String   // e.g. "env overlay", "~/.claude default"
}

struct Project: Identifiable, Hashable {
    let id: UUID
    var name: String
    var location: ProjectLocation
    var collapsed: Bool = false
}

enum ApprovalMode: String, CaseIterable, Hashable {
    case readOnly = "Read-only"
    case ask = "Ask"
    case auto = "Auto"
}

struct Session: Identifiable, Hashable {
    let id: UUID
    var projectId: UUID
    var title: String
    var vendor: Vendor
    var model: String
    var profileName: String
    var approvalMode: ApprovalMode = .ask
    var lastUpdate: String   // pre-formatted "2m", "1h", "1d" for mock
    var messages: [Message] = []
}

struct Message: Identifiable, Hashable {
    let id: UUID
    enum Role: Hashable { case user, assistant(meta: String) }
    var role: Role
    var who: String
    var meta: String?
    var parts: [Part]
}

enum Part: Hashable, Identifiable {
    case text(String)
    case toolCall(ToolCall)
    case diff(Diff)
    case approval(Approval)

    var id: String {
        switch self {
        case .text(let s):        return "t:" + String(s.hashValue)
        case .toolCall(let t):    return "c:" + t.id.uuidString
        case .diff(let d):        return "d:" + d.id.uuidString
        case .approval(let a):    return "a:" + a.id.uuidString
        }
    }
}

struct ToolCall: Hashable, Identifiable {
    let id: UUID
    var name: String
    var arg: String
    var status: Status
    var meta: String?         // "0.4s"
    var body: String?         // command output preview

    enum Status: Hashable {
        case ok(exit: Int)
        case error(exit: Int)
        case running
    }
}

struct Diff: Hashable, Identifiable {
    let id: UUID
    var path: String
    var plus: Int
    var minus: Int
    var lines: [Line]

    struct Line: Hashable, Identifiable {
        let id = UUID()
        var lineNo: String
        var kind: Kind
        var text: String
        enum Kind: Hashable { case context, add, del }
    }
}

struct Approval: Hashable, Identifiable {
    let id: UUID
    var command: String
    var cwd: String
}
