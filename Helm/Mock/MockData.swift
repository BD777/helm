import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    var projects: [Project]
    var sessions: [Session]
    var providers: [Provider]
    var models: [Model]
    var profiles: [Profile]
    var selectedSessionId: UUID? {
        didSet {
            guard oldValue != selectedSessionId else { return }
            // Drop the previously-selected session if it was an unsent draft.
            // Codex-style: a draft only becomes a real sidebar row after the
            // first message is sent (which flips isDraft to false in `send`).
            if let oldId = oldValue,
               let oldIdx = sessions.firstIndex(where: { $0.id == oldId }),
               sessions[oldIdx].isDraft {
                sessions.remove(at: oldIdx)
            }
            scheduleStateSave()
            if let id = selectedSessionId {
                Task { @MainActor [weak self] in
                    await self?.ensureHistoryLoaded(for: id)
                }
            }
        }
    }
    var isStreaming: Bool = false
    var selectedSessionIsStreaming: Bool {
        guard let selectedSessionId else { return false }
        return isSessionStreaming(selectedSessionId)
    }
    var showProfilesSheet: Bool = false

    /// Bumped each time the user sends a message. The chat list watches this
    /// to force a scroll-to-bottom after Send, regardless of where the user
    /// was previously parked. Distinct from the geometry-based stick-to-
    /// bottom: pressing Send is an explicit "show me what just landed" intent.
    var sendTick: Int = 0

    /// Wall-clock time of the most recent successful write to profiles.json
    /// / state.json. Editors read these to render a "Saved · HH:mm:ss" hint
    /// so the auto-save isn't invisible.
    var lastProfilesSaveAt: Date?
    var lastStateSaveAt: Date?

    private let profileStore: ProfileStore
    private let stateStore: StateStore
    /// One vendor-specific session store per vendor, used to lazily load
    /// history from the agent's own jsonl on disk and to enumerate sessions
    /// for "import existing CLI session" flows. Keep one instance each so
    /// repeated reads don't pay startup cost.
    private let sessionStores: [Vendor: AgentSessionStore]

    init(projects: [Project] = [],
         sessions: [Session] = [],
         selectedSessionId: UUID? = nil,
         profileStore: ProfileStore = ProfileStore(),
         stateStore: StateStore = StateStore()) {
        self.profileStore = profileStore
        self.stateStore = stateStore
        self.sessionStores = [
            .claude: ClaudeSessionStore(),
            .codex:  CodexSessionStore(),
        ]

        let profilesFile = profileStore.load()
        self.providers = profilesFile.providers
        // Skip Models that lack a providerModelId — those are partial drafts
        // that an earlier code path persisted before we added validation.
        // They have no value and they pollute pickers.
        let cleanModels = profilesFile.models.filter { !$0.providerModelId.isEmpty }
        self.models = cleanModels
        self.profiles = profilesFile.profiles

        // Caller-provided projects/sessions (previews / tests) win over disk.
        let stateFile = stateStore.load()
        self.projects = projects.isEmpty ? stateFile.projects : projects
        // Drop sessions that were never sent (no vendor-issued id, no jsonl
        // backing). These are leftovers from clicks that pre-date the draft
        // pattern — keeping them just clutters the sidebar.
        let cleanSessions = (sessions.isEmpty ? stateFile.sessions : sessions)
            .filter { $0.vendorSessionId != nil }
        self.sessions = cleanSessions
        let restoredSelection = selectedSessionId ?? stateFile.selectedSessionId
        self.selectedSessionId = cleanSessions.contains { $0.id == restoredSelection }
            ? restoredSelection
            : nil

        // didSet doesn't fire from `init`, so kick off the lazy-load
        // explicitly if there's a selected session restored from disk.
        if let sid = self.selectedSessionId {
            Task { @MainActor [weak self] in
                await self?.ensureHistoryLoaded(for: sid)
            }
        }

        // Expose write-completed timestamps for the UI. The stores invoke
        // these callbacks via `DispatchQueue.main.async`, so we're already on
        // the main thread — but the closures are `@Sendable`, so Swift needs
        // `MainActor.assumeIsolated` to let us mutate `self`.
        profileStore.onSaved = { [weak self] in
            MainActor.assumeIsolated {
                self?.lastProfilesSaveAt = Date()
            }
        }
        stateStore.onSaved = { [weak self] in
            MainActor.assumeIsolated {
                self?.lastStateSaveAt = Date()
            }
        }

        // If we filtered any invalid records during load, persist the cleaned
        // table so the JSON on disk stops carrying the orphan.
        if cleanModels.count != profilesFile.models.count {
            scheduleProfilesSave()
        }
        if cleanSessions.count != stateFile.sessions.count {
            scheduleStateSave()
        }
    }

    // MARK: - Lookups

    func profile(_ id: UUID) -> Profile? { profiles.first { $0.id == id } }
    func provider(_ id: UUID) -> Provider? { providers.first { $0.id == id } }
    func model(_ id: UUID) -> Model? { models.first { $0.id == id } }

    func profiles(for vendor: Vendor) -> [Profile] {
        profiles.filter { $0.vendor == vendor }
    }

    func providers(for vendor: Vendor) -> [Provider] {
        providers.filter { $0.vendor == vendor }
    }

    func models(in providerId: UUID) -> [Model] {
        models.filter { $0.providerId == providerId }
    }

    // MARK: - Provider / Model / Profile mutations

    func upsertProvider(_ p: Provider) {
        if let i = providers.firstIndex(where: { $0.id == p.id }) { providers[i] = p }
        else { providers.append(p) }
        scheduleProfilesSave()
    }

    func deleteProvider(_ id: UUID) {
        providers.removeAll { $0.id == id }
        // Cascade: drop models on this provider, profiles pointing at them.
        let dropped = models.filter { $0.providerId == id }.map(\.id)
        models.removeAll { $0.providerId == id }
        profiles.removeAll { p in
            p.providerId == id ||
            dropped.contains(p.primaryModelId) ||
            (p.opusModelId.map { dropped.contains($0) } ?? false) ||
            (p.sonnetModelId.map { dropped.contains($0) } ?? false) ||
            (p.haikuModelId.map { dropped.contains($0) } ?? false)
        }
        scheduleProfilesSave()
    }

    func upsertModel(_ m: Model) {
        if let i = models.firstIndex(where: { $0.id == m.id }) { models[i] = m }
        else { models.append(m) }
        scheduleProfilesSave()
    }

    func deleteModel(_ id: UUID) {
        models.removeAll { $0.id == id }
        // Profiles pointing at it become invalid; drop them rather than
        // leave dangling pointers.
        profiles.removeAll { p in
            p.primaryModelId == id ||
            p.opusModelId == id ||
            p.sonnetModelId == id ||
            p.haikuModelId == id
        }
        scheduleProfilesSave()
    }

    func upsertProfile(_ p: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p }
        else { profiles.append(p) }
        scheduleProfilesSave()
    }

    func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        scheduleProfilesSave()
    }

    private func scheduleProfilesSave() {
        profileStore.scheduleSave(ProfileStoreFile(
            version: ProfileStoreFile.currentVersion,
            providers: providers,
            models: models,
            profiles: profiles
        ))
    }

    private func scheduleStateSave() {
        stateStore.scheduleSave(AppStateFile(
            version: AppStateFile.currentVersion,
            projects: projects,
            sessions: sessions.filter { !$0.isDraft },
            selectedSessionId: selectedSessionId
        ))
    }

    /// Synchronously persist everything in-flight. Call from
    /// `applicationWillTerminate` so debounced writes can't be lost on quit.
    func flushAll() {
        profileStore.flush(ProfileStoreFile(
            version: ProfileStoreFile.currentVersion,
            providers: providers,
            models: models,
            profiles: profiles
        ))
        stateStore.flush(AppStateFile(
            version: AppStateFile.currentVersion,
            projects: projects,
            sessions: sessions.filter { !$0.isDraft },
            selectedSessionId: selectedSessionId
        ))
    }

    // MARK: - Session helpers

    var selectedSession: Session? {
        get { sessions.first { $0.id == selectedSessionId } }
        set {
            guard let new = newValue, let idx = sessions.firstIndex(where: { $0.id == new.id }) else { return }
            sessions[idx] = new
        }
    }

    func isSessionStreaming(_ sessionId: UUID) -> Bool {
        isStreaming && activeSessionId == sessionId
    }

    func project(for sessionId: UUID) -> Project? {
        guard let s = sessions.first(where: { $0.id == sessionId }) else { return nil }
        return projects.first { $0.id == s.projectId }
    }

    func sessions(in projectId: UUID) -> [Session] {
        sessions.filter { $0.projectId == projectId && !$0.isDraft }
    }

    func toggleCollapsed(_ projectId: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[i].collapsed.toggle()
        scheduleStateSave()
    }

    /// Display string for a session's current binding (e.g.
    /// "Claude Sonnet 4.6 · es2-relay"). Falls back gracefully if the
    /// profile / model has been deleted.
    func sessionHeadline(_ session: Session) -> String {
        guard let p = profile(session.profileId) else { return "—" }
        guard let m = model(p.primaryModelId) else { return p.name }
        return m.label + " · " + p.name
    }

    // MARK: - Project / Session creation

    /// Opens a folder picker. Adds the chosen directory as a local project.
    /// Returns the new project id, or nil if the user cancelled.
    @discardableResult
    func addLocalProjectViaPicker() -> UUID? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let name = url.lastPathComponent
        let project = Project(id: UUID(), name: name, location: .local(path: url.path))
        projects.append(project)
        scheduleStateSave()
        return project.id
    }

    /// Creates a new session in the given project, defaulting to the first
    /// available profile (preferring Claude). Returns nil if no profiles exist.
    @discardableResult
    func newSession(in projectId: UUID,
                    vendor: Vendor? = nil,
                    profileId: UUID? = nil) -> UUID? {
        let pickedProfile: Profile? = {
            if let id = profileId, let p = profile(id) { return p }
            if let v = vendor, let p = profiles(for: v).first { return p }
            return profiles(for: .claude).first ?? profiles.first
        }()
        guard let profile = pickedProfile else { return nil }
        // Codex sessions seed sandbox + effort from the profile's defaults if
        // any; the other fields stay at vendor-native defaults and are simply
        // ignored when the session's vendor doesn't use them.
        let sandbox = profile.sandboxMode ?? .workspace
        let codexEffort = profile.reasoningEffort ?? .medium
        let session = Session(
            id: UUID(),
            projectId: projectId,
            title: "New chat",
            profileId: profile.id,
            claudePermissionMode: .defaultMode,
            codexSandboxMode: sandbox,
            codexApprovalMode: .onRequest,
            claudeEffort: .medium,
            codexEffort: codexEffort,
            lastUpdate: "now",
            isDraft: true
        )
        sessions.append(session)
        selectedSessionId = session.id  // didSet schedules state save + history load
        return session.id
    }

    /// Switch the current session to a different profile (same vendor).
    /// Cross-vendor switches start a new session instead — call newSession.
    func setProfile(_ profile: Profile, on sessionId: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        guard sessions[idx].profileId == profile.id ||
              self.profile(sessions[idx].profileId)?.vendor == profile.vendor else { return }
        sessions[idx].profileId = profile.id
        scheduleStateSave()
    }

    /// Update the session's Claude permission mode. No-op for non-Claude
    /// sessions (the field is still stored, just unused at spawn time).
    func setClaudePermission(_ mode: ClaudePermissionMode, on sessionId: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        guard sessions[idx].claudePermissionMode != mode else { return }
        sessions[idx].claudePermissionMode = mode
        scheduleStateSave()
    }

    /// Update the session's Codex sandbox scope.
    func setCodexSandbox(_ mode: Profile.SandboxMode, on sessionId: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        guard sessions[idx].codexSandboxMode != mode else { return }
        sessions[idx].codexSandboxMode = mode
        scheduleStateSave()
    }

    /// Update the session's Codex approval policy.
    func setCodexApproval(_ mode: CodexApprovalMode, on sessionId: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        guard sessions[idx].codexApprovalMode != mode else { return }
        sessions[idx].codexApprovalMode = mode
        scheduleStateSave()
    }

    /// Update the session's Claude reasoning effort.
    func setClaudeEffort(_ effort: ClaudeEffort, on sessionId: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        guard sessions[idx].claudeEffort != effort else { return }
        sessions[idx].claudeEffort = effort
        scheduleStateSave()
    }

    /// Update the session's Codex reasoning effort.
    func setCodexEffort(_ effort: Profile.ReasoningEffort, on sessionId: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        guard sessions[idx].codexEffort != effort else { return }
        sessions[idx].codexEffort = effort
        scheduleStateSave()
    }

    /// Pull the vendor's session log from disk into this session's transcript
    /// if we haven't already. Idempotent — safe to call repeatedly. Failures
    /// are logged but never thrown to the UI; an empty session just stays
    /// empty.
    func ensureHistoryLoaded(for sessionId: UUID) async {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              sessions[sIdx].transcript.isEmpty,
              let profile = profile(sessions[sIdx].profileId),
              let project = projects.first(where: { $0.id == sessions[sIdx].projectId }),
              let store = sessionStores[profile.vendor]
        else { return }
        // Use the vendor session id if we have one; otherwise our session.id
        // doubles as the vendor id for Claude (we passed it via --session-id).
        let vendorId = sessions[sIdx].vendorSessionId
            ?? sessions[sIdx].id.uuidString.lowercased()
        do {
            let items = try await store.history(sessionId: vendorId, project: project)
            guard let stillIdx = sessions.firstIndex(where: { $0.id == sessionId }),
                  sessions[stillIdx].transcript.isEmpty else { return }
            sessions[stillIdx].transcript = items
        } catch {
            NSLog("[helm.history] load failed for %@: %@",
                  vendorId, error.localizedDescription)
        }
    }

    // MARK: - Agent invocation

    private var currentAdapter: AgentAdapter?
    private var streamTask: Task<Void, Never>?
    private var activeRunId: UUID?
    private var activeSessionId: UUID?
    private var activeAssistantId: UUID?
    /// Maps vendor tool_use ids → our ToolCall.id for the active assistant
    /// message so input fragments and tool_results can land on the right call.
    private var toolMap: [String: UUID] = [:]

    func send(_ prompt: String, attachments: [ImageAttachment] = []) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard let sIdx = sessions.firstIndex(where: { $0.id == selectedSessionId }) else { return }
        // Promote a draft to a real session — first send is what makes the
        // sidebar row appear.
        if sessions[sIdx].isDraft {
            sessions[sIdx].isDraft = false
        }
        if sessions[sIdx].transcript.isEmpty {
            sessions[sIdx].title = Self.title(for: trimmed,
                                              attachments: attachments)
        }
        sessions[sIdx].lastUpdate = "now"
        let session = sessions[sIdx]
        guard let project = projects.first(where: { $0.id == session.projectId }) else {
            appendError(to: sIdx, "Session has no project (id=\(session.projectId))."); return
        }
        guard let profile = profile(session.profileId) else {
            appendError(to: sIdx, "Session's profile is missing — open Profiles and bind one."); return
        }

        let runConfig: RunConfig
        do {
            runConfig = try RunConfigResolver.resolve(profile: profile,
                                                     session: session,
                                                     providers: providers,
                                                     models: models)
        } catch {
            appendError(to: sIdx, error.localizedDescription)
            return
        }

        var userParts: [Part] = []
        if !trimmed.isEmpty { userParts.append(.text(trimmed)) }
        for att in attachments { userParts.append(.image(att.fileURL)) }
        let userMsg = Message(
            id: UUID(), role: .user, who: "you", meta: nil,
            parts: userParts
        )
        let assistantMsg = Message(
            id: UUID(),
            role: .assistant(meta: "thinking…"),
            who: runConfig.headlineModel,
            meta: "thinking…",
            parts: []
        )
        sessions[sIdx].transcript.append(.message(userMsg))
        sessions[sIdx].transcript.append(.message(assistantMsg))
        let sessionId = session.id
        let assistantId = assistantMsg.id
        sendTick &+= 1

        // Append a manifest entry indexed by the user-message ordinal so we
        // can rehydrate thumbnails after restart without paying base64 cost.
        if !attachments.isEmpty {
            let userOrdinal = sessions[sIdx].transcript
                .dropLast() // exclude the assistant placeholder we just added
                .compactMap { $0.message }
                .filter { if case .user = $0.role { return true } else { return false } }
                .count - 1
            ImageManifestStore.append(sessionId: session.id,
                                      userMessageOrdinal: userOrdinal,
                                      filenames: attachments.map { $0.fileURL.lastPathComponent })
        }

        isStreaming = true
        let runId = UUID()
        activeRunId = runId
        activeSessionId = sessionId
        activeAssistantId = assistantId
        toolMap = [:]

        let adapter: AgentAdapter
        switch profile.vendor {
        case .claude: adapter = ClaudeLocalAdapter()
        case .codex:
            appendError(to: sIdx, "Codex adapter not implemented yet.")
            finishStreaming(runId: runId)
            return
        }
        currentAdapter = adapter

        do {
            let stream = try adapter.start(prompt: trimmed, attachments: attachments, session: session, run: runConfig, project: project)
            streamTask = Task { [weak self] in
                do {
                    for try await event in stream {
                        guard !Task.isCancelled else { break }
                        self?.handle(event, runId: runId,
                                     sessionId: sessionId,
                                     assistantId: assistantId)
                    }
                } catch {
                    self?.handle(.error(error.localizedDescription),
                                 runId: runId,
                                 sessionId: sessionId, assistantId: assistantId)
                }
                self?.finishStreaming(runId: runId)
            }
        } catch {
            appendError(to: sIdx, "Failed to start agent: \(error.localizedDescription)")
            finishStreaming(runId: runId)
        }
    }

    func cancelStreaming() {
        guard isStreaming else { return }
        let adapter = currentAdapter
        let task = streamTask
        if let sessionId = activeSessionId,
           let assistantId = activeAssistantId {
            markRunStopped(sessionId: sessionId, assistantId: assistantId)
        }
        finishStreaming()
        task?.cancel()
        adapter?.cancel()
    }

    private func finishStreaming(runId: UUID? = nil) {
        if let runId, activeRunId != runId { return }
        isStreaming = false
        currentAdapter = nil
        streamTask = nil
        activeRunId = nil
        activeSessionId = nil
        activeAssistantId = nil
        toolMap = [:]
    }

    private func handle(_ event: AgentEvent, runId: UUID,
                        sessionId: UUID, assistantId: UUID) {
        guard activeRunId == runId else { return }
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        switch event {
        case .sessionId(let id):
            if sessions[sIdx].vendorSessionId != id {
                sessions[sIdx].vendorSessionId = id
                scheduleStateSave()
            }

        case .assistantTextDelta(let chunk):
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                msg.meta = "streaming…"
                if case .text(let existing) = msg.parts.last {
                    msg.parts[msg.parts.count - 1] = .text(existing + chunk)
                } else {
                    msg.parts.append(.text(chunk))
                }
            }

        case .toolCallStart(let vendorId, let name, let input):
            let call = ToolCall(id: UUID(), name: name, arg: input,
                                status: .running, meta: nil, body: nil)
            toolMap[vendorId] = call.id
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                msg.parts.append(.toolCall(call))
            }

        case .toolInputDelta(let vendorId, let fragment):
            guard let callId = toolMap[vendorId] else { return }
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                guard let pIdx = msg.parts.firstIndex(where: {
                    if case .toolCall(let t) = $0 { return t.id == callId } else { return false }
                }), case .toolCall(var call) = msg.parts[pIdx] else { return }
                call.arg += fragment
                msg.parts[pIdx] = .toolCall(call)
            }

        case .toolResult(let vendorId, let output, let isError):
            guard let callId = toolMap[vendorId] else { return }
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                guard let pIdx = msg.parts.firstIndex(where: {
                    if case .toolCall(let t) = $0 { return t.id == callId } else { return false }
                }), case .toolCall(var call) = msg.parts[pIdx] else { return }
                call.body = output
                call.status = isError ? .error(exit: 1) : .ok(exit: 0)
                msg.parts[pIdx] = .toolCall(call)
            }

        case .messageStop:
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                if msg.meta == "streaming…" || msg.meta == "thinking…" {
                    msg.meta = nil
                }
            }

        case .finalResult(let text, let isError):
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                msg.role = .assistant(meta: isError ? "error" : "done")
                msg.meta = isError ? "error" : nil
                if !text.isEmpty {
                    if msg.parts.isEmpty {
                        msg.parts.append(.text(text))
                    } else if isError {
                        msg.parts.append(.text("⚠️ " + text))
                    }
                } else if isError, msg.parts.isEmpty {
                    msg.parts.append(.text("⚠️ Agent reported an error but produced no output. Check Console.app for `helm.claude` logs."))
                }
            }

        case .error(let detail):
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                msg.meta = "error"
                msg.parts.append(.text("⚠️ " + detail))
            }
        }
    }

    private func mutateAssistant(at sIdx: Int, id: UUID, _ mutate: (inout Message) -> Void) {
        guard let mIdx = sessions[sIdx].transcript.firstIndex(where: {
            $0.message?.id == id
        }), case .message(var msg) = sessions[sIdx].transcript[mIdx] else { return }
        mutate(&msg)
        sessions[sIdx].transcript[mIdx] = .message(msg)
    }

    private func markRunStopped(sessionId: UUID, assistantId: UUID) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              let mIdx = sessions[sIdx].transcript.firstIndex(where: {
                  $0.message?.id == assistantId
              }),
              case .message(var msg) = sessions[sIdx].transcript[mIdx]
        else { return }

        msg.role = .assistant(meta: "stopped")
        msg.meta = "stopped"
        let hasToolCall = msg.parts.contains { part in
            if case .toolCall = part { return true }
            return false
        }
        if hasToolCall {
            msg.parts = msg.parts.map { part in
                guard case .toolCall(var call) = part else { return part }
                if case .running = call.status {
                    call.status = .stopped
                }
                return .toolCall(call)
            }
            sessions[sIdx].transcript[mIdx] = .message(msg)
            sessions[sIdx].transcript.append(.message(Message(
                id: UUID(),
                role: .assistant(meta: "stopped"),
                who: msg.who,
                meta: "stopped",
                parts: [.text("Stopped.")]
            )))
        } else {
            if msg.parts.isEmpty {
                msg.parts.append(.text("Stopped."))
            }
            sessions[sIdx].transcript[mIdx] = .message(msg)
        }
    }

    private func appendError(to sIdx: Int, _ text: String) {
        let errMsg = Message(
            id: UUID(),
            role: .assistant(meta: "error"),
            who: "Helm",
            meta: "error",
            parts: [.text("⚠️ " + text)]
        )
        sessions[sIdx].transcript.append(.message(errMsg))
    }

    private static func title(for prompt: String,
                              attachments: [ImageAttachment],
                              maxLength: Int = 52) -> String {
        let normalized = prompt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        let base: String
        if normalized.isEmpty {
            base = attachments.count == 1
                ? "Image"
                : "\(attachments.count) images"
        } else {
            base = normalized
        }

        guard base.count > maxLength else { return base }
        return String(base.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
