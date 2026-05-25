import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    var projects: [Project]
    var sessions: [Session]
    var sidebarSessions: [SidebarSession]
    var projectSchedulers: [ProjectSchedulerState]
    var selectedProjectId: UUID?
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
                removeSidebarSession(oldId)
                sessions.remove(at: oldIdx)
            }
            if let selectedSessionId,
               let project = project(for: selectedSessionId) {
                selectedProjectId = project.id
            }
            scheduleStateSave()
            if let id = selectedSessionId {
                restoreTranscriptSnapshotIfNeeded(for: id)
                Task { @MainActor [weak self] in
                    await self?.ensureHistoryLoaded(for: id)
                }
            }
        }
    }
    var isStreaming: Bool {
        !runningSessionIds.isEmpty
    }
    var selectedSessionIsStreaming: Bool {
        guard let selectedSessionId else { return false }
        return isSessionStreaming(selectedSessionId)
    }
    var selectedSessionIsLoadingHistory: Bool {
        guard let selectedSessionId else { return false }
        return loadingHistorySessionIds.contains(selectedSessionId)
    }
    var showProfilesSheet: Bool = false
    var showSSHProjectSheet: Bool = false
    var showQuickSwitcher: Bool = false
    var imagePreviewURL: URL?
    var pendingApproval: AgentApprovalRequest? {
        currentPendingApprovalEntry?.request
    }
    var pendingApprovalKey: String? {
        currentPendingApprovalEntry?.key
    }
    var composerFocusTick: Int = 0

    /// Bumped each time the user sends a message. The chat list watches this
    /// to force a scroll-to-bottom after Send, regardless of where the user
    /// was previously parked. Distinct from the geometry-based stick-to-
    /// bottom: pressing Send is an explicit "show me what just landed" intent.
    var sendTick: Int = 0

    private var currentPendingApprovalEntry: PendingApprovalEntry? {
        if let selectedSessionId,
           let selectedEntry = pendingApprovalQueue.first(where: { $0.sessionId == selectedSessionId }) {
            return selectedEntry
        }
        return pendingApprovalQueue.first
    }

    /// Wall-clock time of the most recent successful write to profiles.json
    /// / state.json. Editors read these to render a "Saved · HH:mm:ss" hint
    /// so the auto-save isn't invisible.
    var lastProfilesSaveAt: Date?
    var lastStateSaveAt: Date?

    private let profileStore: ProfileStore
    private let stateStore: StateStore
    private var loadingHistorySessionIds: Set<UUID> = []
    private var probingSSHProjectIds: Set<UUID> = []
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
        let loadedProjects = projects.isEmpty ? stateFile.projects : projects
        self.projects = loadedProjects
        let loadedSchedulers = stateFile.schedulers.filter { scheduler in
            loadedProjects.contains { $0.id == scheduler.projectId }
        }
        self.projectSchedulers = loadedSchedulers
        let schedulerSessionIds = Set(loadedSchedulers.flatMap { scheduler -> [UUID] in
            var ids = scheduler.tasks.compactMap(\.sessionId)
            if let schedulerSessionId = scheduler.schedulerSessionId {
                ids.append(schedulerSessionId)
            }
            return ids
        })
        // Drop sessions that were never sent. Keep sessions with either a
        // vendor-issued id or Helm's own transcript snapshot; a failed launch
        // can still produce useful chat context before the vendor reports an id.
        // Scheduler-created worker sessions are also kept even before their
        // first run because the scheduler state owns them by reference.
        let cleanSessions = (sessions.isEmpty ? stateFile.sessions : sessions)
            .filter {
                $0.vendorSessionId != nil ||
                TranscriptSnapshotStore.exists(sessionId: $0.id) ||
                schedulerSessionIds.contains($0.id)
            }
        self.sessions = cleanSessions
        self.sidebarSessions = Self.sidebarSessions(from: cleanSessions)
        let restoredSelection = selectedSessionId ?? stateFile.selectedSessionId
        self.selectedSessionId = cleanSessions.contains { $0.id == restoredSelection }
            ? restoredSelection
            : nil
        let restoredProjectId = stateFile.selectedProjectId
            ?? self.selectedSessionId.flatMap { sessionId in
                cleanSessions.first { $0.id == sessionId }?.projectId
            }
        self.selectedProjectId = loadedProjects.contains { $0.id == restoredProjectId }
            ? restoredProjectId
            : loadedProjects.first?.id

        // didSet doesn't fire from `init`, so kick off the lazy-load
        // explicitly if there's a selected session restored from disk.
        if let sid = self.selectedSessionId {
            restoreTranscriptSnapshotIfNeeded(for: sid)
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
        for project in self.projects where project.location.isSSH {
            Task { @MainActor [weak self] in
                await self?.probeSSHProject(project.id)
            }
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
            selectedSessionId: selectedSessionId,
            selectedProjectId: selectedProjectId,
            schedulers: projectSchedulers
        ))
    }

    /// Synchronously persist everything in-flight. Call from
    /// `applicationWillTerminate` so debounced writes can't be lost on quit.
    func flushAll() {
        persistTranscriptSnapshots()
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
            selectedSessionId: selectedSessionId,
            selectedProjectId: selectedProjectId,
            schedulers: projectSchedulers
        ))
    }

    // MARK: - Session helpers

    func session(_ id: UUID) -> Session? {
        sessions.first { $0.id == id }
    }

    var selectedSession: Session? {
        get { sessions.first { $0.id == selectedSessionId } }
        set {
            guard let new = newValue, let idx = sessions.firstIndex(where: { $0.id == new.id }) else { return }
            sessions[idx] = new
            upsertSidebarSession(for: new)
        }
    }

    func isSessionStreaming(_ sessionId: UUID) -> Bool {
        runningSessionIds.contains(sessionId)
    }

    func activeRunStartedAt(for sessionId: UUID) -> Date? {
        activeRunStartedAts[sessionId]
    }

    func project(for sessionId: UUID) -> Project? {
        guard let s = sessions.first(where: { $0.id == sessionId }) else { return nil }
        return projects.first { $0.id == s.projectId }
    }

    var selectedProject: Project? {
        if let selectedSessionId,
           let project = project(for: selectedSessionId) {
            return project
        }
        guard let selectedProjectId else { return nil }
        return projects.first { $0.id == selectedProjectId }
    }

    var selectedSSHStatus: SSHStatus? {
        guard let selectedProject else { return nil }
        return sshStatus(for: selectedProject.id)
    }

    func sshStatus(for projectId: UUID) -> SSHStatus? {
        guard let project = projects.first(where: { $0.id == projectId }),
              case .ssh(_, _, let status) = project.location
        else { return nil }
        return status
    }

    func sessions(in projectId: UUID) -> [Session] {
        sessions.filter { $0.projectId == projectId && !$0.isDraft }
    }

    func sidebarSessions(in projectId: UUID) -> [SidebarSession] {
        sidebarSessions.filter { $0.projectId == projectId }
    }

    var visibleSessions: [Session] {
        projects.flatMap { project in
            sessions(in: project.id)
        }
    }

    func requestComposerFocus() {
        composerFocusTick &+= 1
    }

    func selectProjectOverview(_ projectId: UUID) {
        guard projects.contains(where: { $0.id == projectId }) else { return }
        selectedProjectId = projectId
        selectedSessionId = nil
        _ = ensureSchedulerStateIndex(for: projectId)
        scheduleStateSave()
    }

    func showQuickSwitcherPanel() {
        guard !visibleSessions.isEmpty else {
            requestComposerFocus()
            return
        }
        showQuickSwitcher = true
    }

    func hideQuickSwitcherPanel() {
        showQuickSwitcher = false
    }

    @discardableResult
    func newSessionInCurrentProject() -> UUID? {
        let projectId = selectedProject?.id ?? projects.first?.id
        guard let projectId else { return nil }
        return newSession(in: projectId)
    }

    func selectRelativeSession(offset: Int) {
        let scopedSessions: [Session] = {
            if let selectedProject {
                let projectSessions = sessions(in: selectedProject.id)
                if !projectSessions.isEmpty { return projectSessions }
            }
            return visibleSessions
        }()
        guard !scopedSessions.isEmpty else { return }

        let currentIndex = selectedSessionId
            .flatMap { selectedId in scopedSessions.firstIndex { $0.id == selectedId } }
        let base = currentIndex ?? (offset > 0 ? -1 : scopedSessions.count)
        let nextIndex = (base + offset + scopedSessions.count) % scopedSessions.count
        selectedSessionId = scopedSessions[nextIndex].id
    }

    func selectSidebarItem(_ oneBasedIndex: Int) {
        let rows = visibleSessions
        guard rows.indices.contains(oneBasedIndex - 1) else { return }
        selectedSessionId = rows[oneBasedIndex - 1].id
    }

    func renameSession(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = sessions.firstIndex(where: { $0.id == id })
        else { return }
        sessions[idx].title = trimmed
        sessions[idx].lastUpdate = "now"
        upsertSidebarSession(for: sessions[idx])
        scheduleStateSave()
    }

    func deleteSession(_ id: UUID) {
        guard !isSessionStreaming(id),
              let idx = sessions.firstIndex(where: { $0.id == id })
        else { return }
        let projectId = sessions[idx].projectId
        let wasSelected = selectedSessionId == id
        sessions.remove(at: idx)
        removeSidebarSession(id)
        TranscriptSnapshotStore.delete(sessionId: id)
        if wasSelected {
            selectedSessionId = sessions.first {
                $0.projectId == projectId && !$0.isDraft
            }?.id
        } else {
            scheduleStateSave()
        }
    }

    func toggleCollapsed(_ projectId: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[i].collapsed.toggle()
        scheduleStateSave()
    }

    func moveProject(_ sourceId: UUID, around targetId: UUID, after: Bool) {
        guard sourceId != targetId,
              let sourceIndex = projects.firstIndex(where: { $0.id == sourceId })
        else { return }

        let previousOrder = projects.map(\.id)
        let moving = projects.remove(at: sourceIndex)
        guard let targetIndex = projects.firstIndex(where: { $0.id == targetId }) else {
            projects.insert(moving, at: sourceIndex)
            return
        }

        let insertionIndex = min(projects.count, targetIndex + (after ? 1 : 0))
        projects.insert(moving, at: insertionIndex)

        if projects.map(\.id) != previousOrder {
            scheduleStateSave()
        }
    }

    /// Display string for a session's current binding (e.g.
    /// "Claude Sonnet 4.6 · es2-relay"). Falls back gracefully if the
    /// profile / model has been deleted.
    func sessionHeadline(_ session: Session) -> String {
        sessionHeadline(profileId: session.profileId)
    }

    func sessionHeadline(_ session: SidebarSession) -> String {
        sessionHeadline(profileId: session.profileId)
    }

    private func sessionHeadline(profileId: UUID) -> String {
        guard let p = profile(profileId) else { return "—" }
        guard let m = model(p.primaryModelId) else { return p.name }
        return m.label + " · " + p.name
    }

    private static func sidebarSessions(from sessions: [Session]) -> [SidebarSession] {
        sessions.filter { !$0.isDraft }.map(SidebarSession.init)
    }

    private func upsertSidebarSession(for session: Session) {
        if session.isDraft {
            removeSidebarSession(session.id)
            return
        }

        let row = SidebarSession(session)
        if let idx = sidebarSessions.firstIndex(where: { $0.id == session.id }) {
            guard sidebarSessions[idx] != row else { return }
            sidebarSessions[idx] = row
        } else {
            sidebarSessions.append(row)
        }
    }

    private func removeSidebarSession(_ sessionId: UUID) {
        sidebarSessions.removeAll { $0.id == sessionId }
    }

    // MARK: - Project scheduler

    func schedulerState(for projectId: UUID) -> ProjectSchedulerState {
        projectSchedulers.first { $0.projectId == projectId }
            ?? ProjectSchedulerState(projectId: projectId)
    }

    func schedulerTasks(in projectId: UUID) -> [ProjectSchedulerTask] {
        schedulerState(for: projectId).tasks.sorted { lhs, rhs in
            if lhs.phase == rhs.phase { return lhs.updatedAt > rhs.updatedAt }
            return phaseSortIndex(lhs.phase) < phaseSortIndex(rhs.phase)
        }
    }

    func unresolvedHumanActions(in projectId: UUID) -> [ProjectSchedulerHumanAction] {
        schedulerState(for: projectId).humanActions
            .filter { !$0.isResolved }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func unmanagedProjectSessions(in projectId: UUID) -> [Session] {
        let state = schedulerState(for: projectId)
        var managedSessionIds = Set(state.tasks.compactMap(\.sessionId))
        if let schedulerSessionId = state.schedulerSessionId {
            managedSessionIds.insert(schedulerSessionId)
        }
        return sessions(in: projectId)
            .filter { !managedSessionIds.contains($0.id) }
            .sorted { lhs, rhs in
                let lhsRunning = isSessionStreaming(lhs.id)
                let rhsRunning = isSessionStreaming(rhs.id)
                if lhsRunning != rhsRunning { return lhsRunning }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    func schedulerTask(for sessionId: UUID) -> ProjectSchedulerTask? {
        projectSchedulers
            .lazy
            .flatMap(\.tasks)
            .first { $0.sessionId == sessionId }
    }

    func schedulerTaskCount(in projectId: UUID,
                            phase: ProjectSchedulerTaskPhase? = nil) -> Int {
        let tasks = schedulerState(for: projectId).tasks
        guard let phase else { return tasks.count }
        return tasks.filter { $0.phase == phase }.count
    }

    func setSchedulerProfile(_ profileId: UUID, for projectId: UUID) {
        guard let profile = profile(profileId) else { return }
        let idx = ensureSchedulerStateIndex(for: projectId)
        projectSchedulers[idx].schedulerProfileId = profileId
        if let sessionId = projectSchedulers[idx].schedulerSessionId,
           let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }),
           !isSessionStreaming(sessionId),
           sessions[sessionIndex].transcript.isEmpty {
            let runConfiguration = SessionRunConfiguration.defaults(for: profile)
            sessions[sessionIndex].profileId = profileId
            sessions[sessionIndex].claudePermissionMode = runConfiguration.claudePermissionMode
            sessions[sessionIndex].codexSandboxMode = runConfiguration.codexSandboxMode
            sessions[sessionIndex].codexApprovalMode = runConfiguration.codexApprovalMode
            sessions[sessionIndex].claudeEffort = runConfiguration.claudeEffort
            sessions[sessionIndex].codexEffort = runConfiguration.codexEffort
            upsertSidebarSession(for: sessions[sessionIndex])
        }
        projectSchedulers[idx].updatedAt = Date()
        scheduleStateSave()
    }

    func setDefaultWorkerProfile(_ profileId: UUID, for projectId: UUID) {
        guard profile(profileId) != nil else { return }
        let idx = ensureSchedulerStateIndex(for: projectId)
        projectSchedulers[idx].defaultWorkerProfileId = profileId
        projectSchedulers[idx].updatedAt = Date()
        scheduleStateSave()
    }

    func schedulerProfile(for projectId: UUID) -> Profile? {
        let state = schedulerState(for: projectId)
        return state.schedulerProfileId.flatMap(profile)
            ?? profiles(for: .codex).first
            ?? profiles.first
    }

    func defaultWorkerProfile(for projectId: UUID) -> Profile? {
        let state = schedulerState(for: projectId)
        return state.defaultWorkerProfileId.flatMap(profile)
            ?? profiles(for: .codex).first
            ?? profiles.first
    }

    @discardableResult
    func openSchedulerSession(for projectId: UUID) -> UUID? {
        guard let project = projects.first(where: { $0.id == projectId }),
              let schedulerProfile = schedulerProfile(for: projectId)
        else { return nil }
        let idx = ensureSchedulerStateIndex(for: projectId)
        if let sessionId = projectSchedulers[idx].schedulerSessionId,
           sessions.contains(where: { $0.id == sessionId }) {
            selectedSessionId = sessionId
            return sessionId
        }

        let sessionId = createSession(in: projectId,
                                      title: "Scheduler · \(project.name)",
                                      profileId: schedulerProfile.id,
                                      isDraft: false,
                                      select: true)
        projectSchedulers[idx].schedulerSessionId = sessionId
        projectSchedulers[idx].schedulerProfileId = schedulerProfile.id
        projectSchedulers[idx].updatedAt = Date()
        scheduleStateSave()
        return sessionId
    }

    @discardableResult
    func submitProjectIdea(_ text: String,
                           projectId: UUID,
                           workerProfileId: UUID? = nil,
                           runConfiguration: SessionRunConfiguration? = nil) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              projects.contains(where: { $0.id == projectId })
        else { return nil }
        let workerProfile = workerProfileId.flatMap(profile)
            ?? defaultWorkerProfile(for: projectId)
        guard let workerProfile else { return nil }

        let now = Date()
        let title = Self.title(for: trimmed, attachments: [], maxLength: 48)
        guard let sessionId = createSession(in: projectId,
                                            title: title,
                                            profileId: workerProfile.id,
                                            isDraft: false,
                                            select: false,
                                            runConfiguration: runConfiguration ?? .defaults(for: workerProfile))
        else { return nil }
        let taskId = UUID()
        let inboxItem = ProjectSchedulerInboxItem(
            id: UUID(),
            text: trimmed,
            createdAt: now,
            status: .accepted,
            taskId: taskId
        )
        let task = ProjectSchedulerTask(
            id: taskId,
            title: title,
            idea: trimmed,
            sessionId: sessionId,
            phase: .planned,
            summary: "Worker session created. Start it when this task is next in the project plan.",
            dependencies: [],
            resourceNotes: [],
            worktreeHint: worktreeHint(for: title, projectId: projectId),
            createdAt: now,
            updatedAt: now
        )
        let action = ProjectSchedulerHumanAction(
            id: UUID(),
            taskId: taskId,
            kind: .startTask,
            title: "Start \(title)",
            detail: "A worker session is ready for this inbox idea.",
            createdAt: now,
            resolvedAt: nil
        )
        let idx = ensureSchedulerStateIndex(for: projectId)
        projectSchedulers[idx].inbox.insert(inboxItem, at: 0)
        projectSchedulers[idx].tasks.insert(task, at: 0)
        projectSchedulers[idx].humanActions.insert(action, at: 0)
        projectSchedulers[idx].defaultWorkerProfileId = workerProfile.id
        projectSchedulers[idx].updatedAt = now
        selectedProjectId = projectId
        scheduleStateSave()
        return taskId
    }

    @discardableResult
    func adoptSessionIntoScheduler(_ sessionId: UUID, projectId: UUID) -> UUID? {
        guard let session = sessions.first(where: { $0.id == sessionId && $0.projectId == projectId && !$0.isDraft }),
              schedulerTask(for: sessionId) == nil
        else { return nil }
        let idx = ensureSchedulerStateIndex(for: projectId)
        if projectSchedulers[idx].schedulerSessionId == sessionId { return nil }

        let now = Date()
        let taskId = UUID()
        let isRunning = isSessionStreaming(sessionId)
        let phase: ProjectSchedulerTaskPhase = isRunning ? .running : .needsReview
        let task = ProjectSchedulerTask(
            id: taskId,
            title: session.title,
            idea: "Imported existing session \"\(session.title)\" so the project scheduler can track its next step.",
            sessionId: sessionId,
            phase: phase,
            summary: isRunning
                ? "Existing session is running and is now tracked by the project scheduler."
                : "Existing session is idle. Review whether it should continue, merge, complete, or be discarded.",
            dependencies: [],
            resourceNotes: ["Imported from an existing session."],
            worktreeHint: nil,
            createdAt: now,
            updatedAt: now
        )
        projectSchedulers[idx].tasks.insert(task, at: 0)
        if !isRunning {
            projectSchedulers[idx].humanActions.insert(ProjectSchedulerHumanAction(
                id: UUID(),
                taskId: taskId,
                kind: .reviewResult,
                title: "Triage \(session.title)",
                detail: "This existing session is idle but not marked complete.",
                createdAt: now,
                resolvedAt: nil
            ), at: 0)
        }
        projectSchedulers[idx].updatedAt = now
        scheduleStateSave()
        return taskId
    }

    func startSchedulerTask(_ taskId: UUID, projectId: UUID) {
        let idx = ensureSchedulerStateIndex(for: projectId)
        guard let taskIndex = projectSchedulers[idx].tasks.firstIndex(where: { $0.id == taskId }) else { return }
        guard let sessionId = ensureWorkerSession(forTaskAt: taskIndex,
                                                  schedulerIndex: idx,
                                                  projectId: projectId)
        else { return }
        guard !isSessionStreaming(sessionId) else { return }

        let task = projectSchedulers[idx].tasks[taskIndex]
        let prompt = Self.workerPrompt(for: task)
        send(prompt,
             displayParts: [.text(prompt)],
             attachments: [],
             sessionId: sessionId)
    }

    func openSchedulerTaskSession(_ taskId: UUID, projectId: UUID) {
        let state = schedulerState(for: projectId)
        guard let task = state.tasks.first(where: { $0.id == taskId }),
              let sessionId = task.sessionId,
              sessions.contains(where: { $0.id == sessionId })
        else { return }
        selectedSessionId = sessionId
    }

    func resolveHumanAction(_ actionId: UUID, projectId: UUID) {
        let idx = ensureSchedulerStateIndex(for: projectId)
        guard let actionIndex = projectSchedulers[idx].humanActions.firstIndex(where: { $0.id == actionId }) else { return }
        projectSchedulers[idx].humanActions[actionIndex].resolvedAt = Date()
        projectSchedulers[idx].updatedAt = Date()
        scheduleStateSave()
    }

    func markSchedulerTask(_ taskId: UUID,
                           projectId: UUID,
                           phase: ProjectSchedulerTaskPhase) {
        let idx = ensureSchedulerStateIndex(for: projectId)
        guard let taskIndex = projectSchedulers[idx].tasks.firstIndex(where: { $0.id == taskId }) else { return }
        projectSchedulers[idx].tasks[taskIndex].phase = phase
        projectSchedulers[idx].tasks[taskIndex].updatedAt = Date()
        if phase == .readyToMerge || phase == .done {
            resolveHumanActions(projectId: projectId, taskId: taskId, kind: nil)
        }
        projectSchedulers[idx].updatedAt = Date()
        scheduleStateSave()
    }

    private func ensureSchedulerStateIndex(for projectId: UUID) -> Int {
        if let idx = projectSchedulers.firstIndex(where: { $0.projectId == projectId }) {
            return idx
        }
        projectSchedulers.append(ProjectSchedulerState(projectId: projectId))
        return projectSchedulers.count - 1
    }

    private func ensureWorkerSession(forTaskAt taskIndex: Int,
                                     schedulerIndex: Int,
                                     projectId: UUID) -> UUID? {
        if let sessionId = projectSchedulers[schedulerIndex].tasks[taskIndex].sessionId,
           sessions.contains(where: { $0.id == sessionId }) {
            return sessionId
        }
        guard let workerProfile = defaultWorkerProfile(for: projectId) else { return nil }
        let task = projectSchedulers[schedulerIndex].tasks[taskIndex]
        let sessionId = createSession(in: projectId,
                                      title: task.title,
                                      profileId: workerProfile.id,
                                      isDraft: false,
                                      select: false)
        projectSchedulers[schedulerIndex].tasks[taskIndex].sessionId = sessionId
        projectSchedulers[schedulerIndex].tasks[taskIndex].updatedAt = Date()
        return sessionId
    }

    private func markManagedSessionRunning(_ sessionId: UUID) {
        guard let location = managedTaskLocation(for: sessionId) else { return }
        let now = Date()
        projectSchedulers[location.schedulerIndex].tasks[location.taskIndex].phase = .running
        projectSchedulers[location.schedulerIndex].tasks[location.taskIndex].summary = "Worker session is running."
        projectSchedulers[location.schedulerIndex].tasks[location.taskIndex].updatedAt = now
        projectSchedulers[location.schedulerIndex].updatedAt = now
        let taskId = projectSchedulers[location.schedulerIndex].tasks[location.taskIndex].id
        resolveHumanActions(projectId: projectSchedulers[location.schedulerIndex].projectId,
                            taskId: taskId,
                            kind: .startTask)
        scheduleStateSave()
    }

    private func markManagedSessionFinished(_ sessionId: UUID) {
        guard let location = managedTaskLocation(for: sessionId) else { return }
        let now = Date()
        let task = projectSchedulers[location.schedulerIndex].tasks[location.taskIndex]
        guard task.phase == .running || task.phase == .waiting || task.phase == .planned else { return }
        projectSchedulers[location.schedulerIndex].tasks[location.taskIndex].phase = .needsReview
        projectSchedulers[location.schedulerIndex].tasks[location.taskIndex].summary = "Worker session finished. Review the transcript and decide the next scheduler step."
        projectSchedulers[location.schedulerIndex].tasks[location.taskIndex].updatedAt = now
        projectSchedulers[location.schedulerIndex].humanActions.insert(ProjectSchedulerHumanAction(
            id: UUID(),
            taskId: task.id,
            kind: .reviewResult,
            title: "Review \(task.title)",
            detail: "The worker session has stopped and needs a human check.",
            createdAt: now,
            resolvedAt: nil
        ), at: 0)
        projectSchedulers[location.schedulerIndex].updatedAt = now
        scheduleStateSave()
    }

    private func managedTaskLocation(for sessionId: UUID) -> (schedulerIndex: Int, taskIndex: Int)? {
        for schedulerIndex in projectSchedulers.indices {
            if let taskIndex = projectSchedulers[schedulerIndex].tasks.firstIndex(where: { $0.sessionId == sessionId }) {
                return (schedulerIndex, taskIndex)
            }
        }
        return nil
    }

    private func resolveHumanActions(projectId: UUID,
                                     taskId: UUID,
                                     kind: ProjectSchedulerHumanActionKind?) {
        let idx = ensureSchedulerStateIndex(for: projectId)
        let now = Date()
        for actionIndex in projectSchedulers[idx].humanActions.indices {
            guard projectSchedulers[idx].humanActions[actionIndex].taskId == taskId,
                  !projectSchedulers[idx].humanActions[actionIndex].isResolved
            else { continue }
            if let kind,
               projectSchedulers[idx].humanActions[actionIndex].kind != kind {
                continue
            }
            projectSchedulers[idx].humanActions[actionIndex].resolvedAt = now
        }
    }

    private func phaseSortIndex(_ phase: ProjectSchedulerTaskPhase) -> Int {
        switch phase {
        case .needsReview: return 0
        case .running: return 1
        case .waiting: return 2
        case .planned: return 3
        case .readyToMerge: return 4
        case .done: return 5
        }
    }

    private func worktreeHint(for title: String, projectId: UUID) -> String? {
        guard let project = projects.first(where: { $0.id == projectId }),
              case .local(let path) = project.location
        else { return nil }
        let slug = title
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
        let compactSlug = String(slug).split(separator: "-").prefix(5).joined(separator: "-")
        guard !compactSlug.isEmpty else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        let projectName = (path as NSString).lastPathComponent
        return "\(parent)/\(projectName)-worktrees/\(compactSlug)"
    }

    private static func workerPrompt(for task: ProjectSchedulerTask) -> String {
        """
        You are working on this project task under Helm's project scheduler.

        Task: \(task.title)

        Idea:
        \(task.idea)

        Keep the implementation scoped to this task. If you need validation resources such as browser, Computer Use, a port, or a worktree merge, state that clearly in your result so the project scheduler can queue the next step.
        """
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
        projectSchedulers.append(ProjectSchedulerState(projectId: project.id))
        selectedProjectId = project.id
        scheduleStateSave()
        return project.id
    }

    @discardableResult
    func addSSHProject(host: String, path: String, name: String) -> UUID? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !path.isEmpty else { return nil }

        let project = Project(
            id: UUID(),
            name: name.isEmpty ? Self.defaultSSHProjectName(host: host, path: path) : name,
            location: .ssh(host: host, path: path, status: .connecting)
        )
        projects.append(project)
        projectSchedulers.append(ProjectSchedulerState(projectId: project.id))
        selectedProjectId = project.id
        scheduleStateSave()
        Task { @MainActor [weak self] in
            await self?.probeSSHProject(project.id)
        }
        return project.id
    }

    func probeSSHProject(_ projectId: UUID) async {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }),
              case .ssh(let host, let path, _) = projects[idx].location
        else { return }
        guard !probingSSHProjectIds.contains(projectId) else { return }
        probingSSHProjectIds.insert(projectId)
        defer { probingSSHProjectIds.remove(projectId) }
        projects[idx].location = projects[idx].location.withSSHStatus(.connecting)
        NSLog("[helm.ssh] probe start host=%@ path=%@", host, path)
        let status = await SSHProbe.check(host: host, path: path)
        guard let latestIdx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[latestIdx].location = projects[latestIdx].location.withSSHStatus(status)
        NSLog("[helm.ssh] probe result host=%@ status=%@",
              host, status.helpText)
    }

    func retrySSHProject(_ projectId: UUID) {
        Task { @MainActor [weak self] in
            await self?.probeSSHProject(projectId)
        }
    }

    func retrySelectedSSHProject() {
        guard let project = selectedProject,
              case .ssh = project.location
        else { return }
        retrySSHProject(project.id)
    }

    private static func defaultSSHProjectName(host: String, path: String) -> String {
        let expandedTail = (path as NSString).lastPathComponent
        guard !expandedTail.isEmpty,
              expandedTail != ".",
              expandedTail != "/",
              expandedTail != "~"
        else { return host }
        return "\(host):\(expandedTail)"
    }

    /// Creates a new session in the given project, defaulting to the first
    /// available profile (preferring Claude). Returns nil if no profiles exist.
    @discardableResult
    func newSession(in projectId: UUID,
                    vendor: Vendor? = nil,
                    profileId: UUID? = nil) -> UUID? {
        createSession(in: projectId,
                      title: "New chat",
                      vendor: vendor,
                      profileId: profileId,
                      isDraft: true,
                      select: true)
    }

    @discardableResult
    private func createSession(in projectId: UUID,
                               title: String,
                               vendor: Vendor? = nil,
                               profileId: UUID? = nil,
                               isDraft: Bool,
                               select: Bool,
                               runConfiguration: SessionRunConfiguration? = nil) -> UUID? {
        guard projects.contains(where: { $0.id == projectId }) else { return nil }
        let pickedProfile: Profile? = {
            if let id = profileId, let p = profile(id) { return p }
            if let v = vendor, let p = profiles(for: v).first { return p }
            return profiles(for: .claude).first ?? profiles.first
        }()
        guard let profile = pickedProfile else { return nil }
        // Session runtime knobs are stored on the session so Project Inbox can
        // create a real worker with the same per-send choices as the composer.
        let resolvedRunConfiguration = runConfiguration ?? .defaults(for: profile)
        var session = Session(
            id: UUID(),
            projectId: projectId,
            title: "New chat",
            profileId: profile.id,
            claudePermissionMode: resolvedRunConfiguration.claudePermissionMode,
            codexSandboxMode: resolvedRunConfiguration.codexSandboxMode,
            codexApprovalMode: resolvedRunConfiguration.codexApprovalMode,
            claudeEffort: resolvedRunConfiguration.claudeEffort,
            codexEffort: resolvedRunConfiguration.codexEffort,
            lastUpdate: "now",
            isDraft: true
        )
        session.title = title
        session.isDraft = isDraft
        sessions.append(session)
        if !isDraft {
            upsertSidebarSession(for: session)
        }
        if select {
            selectedSessionId = session.id  // didSet schedules state save + history load
        } else {
            selectedProjectId = projectId
            scheduleStateSave()
        }
        return session.id
    }

    /// Switch the current session to a different profile. Draft sessions can
    /// still pick any vendor; once the first message is sent, vendor is locked
    /// and only same-vendor profiles are allowed.
    func setProfile(_ profile: Profile, on sessionId: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let currentVendor = self.profile(sessions[idx].profileId)?.vendor
        let canCrossVendor = sessions[idx].isDraft
        guard sessions[idx].profileId == profile.id ||
              currentVendor == profile.vendor ||
              canCrossVendor
        else { return }
        sessions[idx].profileId = profile.id
        if profile.vendor == .codex {
            sessions[idx].codexSandboxMode = profile.sandboxMode ?? .workspace
            sessions[idx].codexEffort = profile.reasoningEffort ?? .medium
        }
        upsertSidebarSession(for: sessions[idx])
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
              let profile = profile(sessions[sIdx].profileId),
              let project = projects.first(where: { $0.id == sessions[sIdx].projectId }),
              let store = sessionStores[profile.vendor]
        else { return }
        guard !loadingHistorySessionIds.contains(sessionId) else { return }

        if sessions[sIdx].transcript.isEmpty {
            restoreTranscriptSnapshotIfNeeded(for: sessionId)
        } else {
            return
        }

        loadingHistorySessionIds.insert(sessionId)
        defer { loadingHistorySessionIds.remove(sessionId) }
        // Use the vendor session id if we have one; otherwise our session.id
        // doubles as the vendor id for Claude (we passed it via --session-id).
        let vendorId = sessions[sIdx].vendorSessionId
            ?? sessions[sIdx].id.uuidString.lowercased()
        NSLog("[helm.history] loading %@ for %@", vendorId, sessionId.uuidString)
        do {
            let items = try await Task.detached(priority: .userInitiated) {
                try await store.history(sessionId: vendorId, project: project)
            }.value
            guard !items.isEmpty else { return }
            guard let stillIdx = sessions.firstIndex(where: { $0.id == sessionId }),
                  !isSessionStreaming(sessionId) else { return }
            let currentCount = sessions[stillIdx].transcript.count
            guard currentCount == 0 || items.count >= currentCount else { return }
            sessions[stillIdx].transcript = items
            persistTranscriptSnapshot(for: sessionId)
            NSLog("[helm.history] loaded %ld items for %@",
                  items.count, vendorId)
        } catch {
            NSLog("[helm.history] load failed for %@: %@",
                  vendorId, error.localizedDescription)
        }
    }

    @discardableResult
    private func restoreTranscriptSnapshotIfNeeded(for sessionId: UUID) -> Bool {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }),
              sessions[idx].transcript.isEmpty
        else { return false }

        let rawSnapshot = TranscriptSnapshotStore.load(sessionId: sessionId)
        let snapshot = Self.removingRecoverableResumeErrors(from: rawSnapshot)
        guard !snapshot.isEmpty else { return false }

        sessions[idx].transcript = snapshot
        if snapshot.count != rawSnapshot.count {
            TranscriptSnapshotStore.save(sessionId: sessionId, items: snapshot)
        }
        NSLog("[helm.history] restored %ld snapshot items for %@",
              snapshot.count, sessionId.uuidString)
        return true
    }

    // MARK: - Agent invocation

    private struct ActiveRun {
        var runId: UUID
        var assistantId: UUID
        var adapter: AgentAdapter
        var task: Task<Void, Never>?
        var startedAt: Date
        var toolMap: [String: UUID] = [:]
        var pendingAssistantText = ""
        var assistantTextFlushTask: Task<Void, Never>?
    }

    private struct PendingApprovalEntry: Identifiable {
        var sessionId: UUID
        var request: AgentApprovalRequest

        var id: String { key }
        var key: String { "\(sessionId.uuidString.lowercased()):\(request.id)" }
    }

    /// Per-session run state. Each active conversation owns its adapter,
    /// stream task, and vendor tool-id mapping so sessions can run together.
    @ObservationIgnored
    private var activeRuns: [UUID: ActiveRun] = [:]
    private var runningSessionIds: Set<UUID> = []
    private var activeRunStartedAts: [UUID: Date] = [:]
    private var pendingApprovalQueue: [PendingApprovalEntry] = []
    private static let assistantTextFlushDelayNanos: UInt64 = 50_000_000

    func send(_ prompt: String,
              displayParts: [Part]? = nil,
              attachments: [ImageAttachment] = [],
              agentPrompt: String? = nil,
              preUserEvents: [SessionEvent] = [],
              sessionId targetSessionId: UUID? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptForAgent = (agentPrompt ?? prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptForAgent.isEmpty || !attachments.isEmpty else { return }
        let targetSessionId = targetSessionId ?? selectedSessionId
        guard let sIdx = sessions.firstIndex(where: { $0.id == targetSessionId }) else { return }
        guard !isSessionStreaming(sessions[sIdx].id) else { return }
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
        upsertSidebarSession(for: sessions[sIdx])
        guard let project = projects.first(where: { $0.id == sessions[sIdx].projectId }) else {
            appendError(to: sIdx, "Session has no project (id=\(sessions[sIdx].projectId))."); return
        }
        guard let profile = profile(sessions[sIdx].profileId) else {
            appendError(to: sIdx, "Session's profile is missing — open Profiles and bind one."); return
        }

        let session = sessions[sIdx]

        let runConfig: RunConfig
        do {
            runConfig = try RunConfigResolver.resolve(profile: profile,
                                                     session: session,
                                                     isRemoteProject: project.location.isSSH,
                                                     providers: providers,
                                                     models: models)
        } catch {
            appendError(to: sIdx, error.localizedDescription)
            return
        }

        var userParts: [Part] = displayParts ?? []
        if userParts.isEmpty, !trimmed.isEmpty {
            userParts.append(.text(trimmed))
        }
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
        for event in preUserEvents {
            sessions[sIdx].transcript.append(.event(event))
        }
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

        let runId = UUID()
        let adapter: AgentAdapter
        switch profile.vendor {
        case .claude: adapter = ClaudeLocalAdapter()
        case .codex: adapter = codexAdapter(project: project, runConfig: runConfig)
        }
        let startedAt = Date()
        activeRuns[sessionId] = ActiveRun(
            runId: runId,
            assistantId: assistantId,
            adapter: adapter,
            task: nil,
            startedAt: startedAt
        )
        markManagedSessionRunning(sessionId)
        runningSessionIds.insert(sessionId)
        activeRunStartedAts[sessionId] = startedAt

        do {
            let stream = try adapter.start(prompt: promptForAgent, attachments: attachments, session: session, run: runConfig, project: project)
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.consumeAgentStream(stream,
                                              runId: runId,
                                              sessionId: sessionId,
                                              assistantId: assistantId,
                                              prompt: promptForAgent,
                                              attachments: attachments,
                                              project: project,
                                              profile: profile,
                                              runConfig: runConfig,
                                              retryCount: 0)
            }
            if var run = activeRuns[sessionId] {
                run.task = task
                activeRuns[sessionId] = run
            }
        } catch {
            appendError(to: sIdx, "Failed to start agent: \(error.localizedDescription)")
            finishStreaming(sessionId: sessionId, runId: runId)
        }
    }

    func cancelStreaming() {
        guard let selectedSessionId else { return }
        cancelStreaming(sessionId: selectedSessionId)
    }

    func cancelStreaming(sessionId: UUID) {
        guard let run = activeRuns[sessionId] else { return }
        activeRuns[sessionId]?.assistantTextFlushTask?.cancel()
        flushAssistantTextBuffer(sessionId: sessionId,
                                 runId: run.runId,
                                 assistantId: run.assistantId)
        markRunStopped(sessionId: sessionId, assistantId: run.assistantId)
        finishStreaming(sessionId: sessionId, runId: run.runId)
        run.task?.cancel()
        run.adapter.cancel()
    }

    private func finishStreaming(sessionId: UUID, runId: UUID? = nil) {
        guard let run = activeRuns[sessionId] else { return }
        if let runId, run.runId != runId { return }
        activeRuns[sessionId]?.assistantTextFlushTask?.cancel()
        flushAssistantTextBuffer(sessionId: sessionId,
                                 runId: run.runId,
                                 assistantId: run.assistantId)
        persistTranscriptSnapshot(for: sessionId)
        markManagedSessionFinished(sessionId)
        activeRuns[sessionId] = nil
        runningSessionIds.remove(sessionId)
        activeRunStartedAts[sessionId] = nil
        pendingApprovalQueue.removeAll { $0.sessionId == sessionId }
    }

    func respondToApproval(_ decision: AgentApprovalDecision) {
        guard let entry = currentPendingApprovalEntry else { return }
        activeRuns[entry.sessionId]?.adapter.respondToApproval(id: entry.request.id,
                                                               decision: decision)
        pendingApprovalQueue.removeAll { $0.key == entry.key }
    }

    private func consumeAgentStream(_ stream: AsyncThrowingStream<AgentEvent, Error>,
                                    runId: UUID,
                                    sessionId: UUID,
                                    assistantId: UUID,
                                    prompt: String,
                                    attachments: [ImageAttachment],
                                    project: Project,
                                    profile: Profile,
                                    runConfig: RunConfig,
                                    retryCount: Int) async {
        var sawMissingConversation = false
        do {
            for try await event in stream {
                guard !Task.isCancelled else { break }
                if shouldRecoverMissingConversation(from: event, retryCount: retryCount) {
                    sawMissingConversation = true
                    continue
                }
                handle(event, runId: runId,
                       sessionId: sessionId,
                       assistantId: assistantId)
            }
        } catch {
            let event = AgentEvent.error(error.localizedDescription)
            if shouldRecoverMissingConversation(from: event, retryCount: retryCount) {
                sawMissingConversation = true
            } else {
                handle(event, runId: runId,
                       sessionId: sessionId,
                       assistantId: assistantId)
            }
        }

        if sawMissingConversation,
           retryCount == 0,
           await retryAfterMissingConversation(runId: runId,
                                               sessionId: sessionId,
                                               assistantId: assistantId,
                                               prompt: prompt,
                                               attachments: attachments,
                                               project: project,
                                               profile: profile,
                                               runConfig: runConfig) {
            return
        }

        finishStreaming(sessionId: sessionId, runId: runId)
    }

    private func shouldRecoverMissingConversation(from event: AgentEvent,
                                                  retryCount: Int) -> Bool {
        guard retryCount == 0 else { return false }
        switch event {
        case .error(let detail):
            return Self.isMissingConversationError(detail)
        case .finalResult(let text, let isError):
            return isError && Self.isMissingConversationError(text)
        default:
            return false
        }
    }

    private func retryAfterMissingConversation(runId: UUID,
                                               sessionId: UUID,
                                               assistantId: UUID,
                                               prompt: String,
                                               attachments: [ImageAttachment],
                                               project: Project,
                                               profile: Profile,
                                               runConfig: RunConfig) async -> Bool {
        guard activeRuns[sessionId]?.runId == runId,
              let sIdx = sessions.firstIndex(where: { $0.id == sessionId })
        else { return false }

        let staleVendorSessionId = sessions[sIdx].vendorSessionId
        sessions[sIdx].vendorSessionId = nil
        upsertSidebarSession(for: sessions[sIdx])
        removeRecoverableResumeErrors(from: sIdx)
        mutateAssistant(at: sIdx, id: assistantId) { msg in
            msg.role = .assistant(meta: "thinking…")
            msg.meta = "thinking…"
            msg.parts.removeAll { part in
                if case .text(let text) = part {
                    return Self.isRecoverableAgentErrorArtifact(text)
                }
                return false
            }
        }
        scheduleStateSave()
        NSLog("[helm.agent] stale vendor session %@ for %@; retrying without resume",
              staleVendorSessionId ?? "<nil>",
              sessionId.uuidString)

        let adapter: AgentAdapter
        switch profile.vendor {
        case .claude: adapter = ClaudeLocalAdapter()
        case .codex: adapter = codexAdapter(project: project, runConfig: runConfig)
        }
        if var run = activeRuns[sessionId], run.runId == runId {
            let restartedAt = Date()
            run.adapter = adapter
            run.startedAt = restartedAt
            run.toolMap = [:]
            activeRuns[sessionId] = run
            activeRunStartedAts[sessionId] = restartedAt
        }

        do {
            let retrySession = sessions[sIdx]
            let retryStream = try adapter.start(prompt: prompt,
                                                attachments: attachments,
                                                session: retrySession,
                                                run: runConfig,
                                                project: project)
            await consumeAgentStream(retryStream,
                                     runId: runId,
                                     sessionId: sessionId,
                                     assistantId: assistantId,
                                     prompt: prompt,
                                     attachments: attachments,
                                     project: project,
                                     profile: profile,
                                     runConfig: runConfig,
                                     retryCount: 1)
            return true
        } catch {
            handle(.error("Failed to restart agent after clearing stale session: \(error.localizedDescription)"),
                   runId: runId,
                   sessionId: sessionId,
                   assistantId: assistantId)
            return false
        }
    }

    private func handle(_ event: AgentEvent, runId: UUID,
                        sessionId: UUID, assistantId: UUID) {
        guard activeRuns[sessionId]?.runId == runId else { return }
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        if case .assistantTextDelta(let chunk) = event {
            enqueueAssistantTextDelta(chunk,
                                      sessionId: sessionId,
                                      runId: runId,
                                      assistantId: assistantId)
            return
        }
        flushAssistantTextBuffer(sessionId: sessionId,
                                 runId: runId,
                                 assistantId: assistantId)
        switch event {
        case .sessionId(let id):
            if sessions[sIdx].vendorSessionId != id {
                sessions[sIdx].vendorSessionId = id
                upsertSidebarSession(for: sessions[sIdx])
                scheduleStateSave()
            }

        case .assistantTextDelta:
            break

        case .toolCallStart(let vendorId, let name, let input):
            let call = ToolCall(id: UUID(), name: name, arg: input,
                                status: .running, meta: nil, body: nil)
            if var run = activeRuns[sessionId] {
                run.toolMap[vendorId] = call.id
                activeRuns[sessionId] = run
            }
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                msg.parts.append(.toolCall(call))
            }

        case .toolInputDelta(let vendorId, let fragment):
            guard let callId = activeRuns[sessionId]?.toolMap[vendorId] else { return }
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                guard let pIdx = msg.parts.firstIndex(where: {
                    if case .toolCall(let t) = $0 { return t.id == callId } else { return false }
                }), case .toolCall(var call) = msg.parts[pIdx] else { return }
                call.arg += fragment
                msg.parts[pIdx] = .toolCall(call)
            }

        case .toolResult(let vendorId, let output, let isError):
            guard let callId = activeRuns[sessionId]?.toolMap[vendorId] else { return }
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                guard let pIdx = msg.parts.firstIndex(where: {
                    if case .toolCall(let t) = $0 { return t.id == callId } else { return false }
                }), case .toolCall(var call) = msg.parts[pIdx] else { return }
                call.body = output
                call.status = isError ? .error(exit: 1) : .ok(exit: 0)
                msg.parts[pIdx] = .toolCall(call)
            }

        case .approvalRequest(let request):
            let entry = PendingApprovalEntry(sessionId: sessionId, request: request)
            pendingApprovalQueue.removeAll { $0.key == entry.key }
            pendingApprovalQueue.append(entry)

        case .approvalResolved(let id):
            pendingApprovalQueue.removeAll {
                $0.sessionId == sessionId && $0.request.id == id
            }

        case .messageStop:
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                if msg.meta == "streaming…" || msg.meta == "thinking…" {
                    msg.meta = nil
                }
            }

        case .finalResult(let text, let isError):
            var followupAnswer: Message?
            let runToClose = activeRuns[sessionId]
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                msg.role = .assistant(meta: isError ? "error" : "done")
                msg.meta = isError ? "error" : nil
                if !text.isEmpty {
                    let hasToolCall = msg.parts.contains { part in
                        if case .toolCall = part { return true }
                        return false
                    }
                    if !isError, hasToolCall {
                        if case .text(let existing) = msg.parts.last, existing == text {
                            msg.parts.removeLast()
                        }
                        followupAnswer = Message(
                            id: UUID(),
                            role: .assistant(meta: "done"),
                            who: msg.who,
                            meta: nil,
                            parts: [.text(text)]
                        )
                    } else if msg.parts.isEmpty {
                        msg.parts.append(.text(text))
                    } else if isError {
                        msg.parts.append(.text("⚠️ " + text))
                    }
                } else if isError, msg.parts.isEmpty {
                    msg.parts.append(.text("⚠️ Agent reported an error but produced no output. Check Console.app for `helm.claude` logs."))
                }
            }
            if let followupAnswer {
                sessions[sIdx].transcript.append(.message(followupAnswer))
            }
            finishStreaming(sessionId: sessionId, runId: runId)
            runToClose?.task?.cancel()
            runToClose?.adapter.cancel()

        case .error(let detail):
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                msg.meta = "error"
                msg.parts.append(.text("⚠️ " + detail))
            }
        }
    }

    private func enqueueAssistantTextDelta(_ chunk: String,
                                           sessionId: UUID,
                                           runId: UUID,
                                           assistantId: UUID) {
        guard !chunk.isEmpty,
              var run = activeRuns[sessionId],
              run.runId == runId
        else { return }

        run.pendingAssistantText += chunk
        if run.assistantTextFlushTask == nil {
            run.assistantTextFlushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.assistantTextFlushDelayNanos)
                self?.flushAssistantTextBuffer(sessionId: sessionId,
                                               runId: runId,
                                               assistantId: assistantId)
            }
        }
        activeRuns[sessionId] = run
    }

    private func flushAssistantTextBuffer(sessionId: UUID,
                                          runId: UUID,
                                          assistantId: UUID) {
        guard var run = activeRuns[sessionId],
              run.runId == runId
        else { return }

        let chunk = run.pendingAssistantText
        run.pendingAssistantText = ""
        run.assistantTextFlushTask = nil
        activeRuns[sessionId] = run

        guard !chunk.isEmpty,
              let sIdx = sessions.firstIndex(where: { $0.id == sessionId })
        else { return }

        mutateAssistant(at: sIdx, id: assistantId) { msg in
            msg.meta = "streaming…"
            if case .text(let existing) = msg.parts.last {
                msg.parts[msg.parts.count - 1] = .text(existing + chunk)
            } else {
                msg.parts.append(.text(chunk))
            }
        }
    }

    private func codexAdapter(project: Project, runConfig: RunConfig) -> AgentAdapter {
        if project.location.isSSH || runConfig.usesComputerUseMCP {
            return CodexLocalAdapter()
        }
        return CodexAppServerAdapter()
    }

    private static func isMissingConversationError(_ detail: String) -> Bool {
        detail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .contains("no conversation found with session id")
    }

    private static func isRecoverableAgentErrorArtifact(_ detail: String) -> Bool {
        let normalized = detail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.contains("no conversation found with session id")
            || normalized.contains("agent reported an error but produced no output")
    }

    private func removeRecoverableResumeErrors(from sIdx: Int) {
        let cleaned = Self.removingRecoverableResumeErrors(from: sessions[sIdx].transcript)
        guard cleaned.count != sessions[sIdx].transcript.count else { return }
        sessions[sIdx].transcript = cleaned
    }

    private static func removingRecoverableResumeErrors(from items: [TranscriptItem]) -> [TranscriptItem] {
        items.filter { item in
            guard case .message(let msg) = item,
                  case .assistant = msg.role,
                  msg.meta == "error",
                  msg.parts.count == 1,
                  case .text(let text) = msg.parts[0],
                  isRecoverableAgentErrorArtifact(text)
            else { return true }
            return false
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
        persistTranscriptSnapshot(for: sessions[sIdx].id)
    }

    private func persistTranscriptSnapshot(for sessionId: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionId }),
              !session.isDraft,
              !session.transcript.isEmpty
        else { return }
        TranscriptSnapshotStore.save(sessionId: session.id, items: session.transcript)
    }

    private func persistTranscriptSnapshots() {
        for session in sessions where !session.isDraft && !session.transcript.isEmpty {
            TranscriptSnapshotStore.save(sessionId: session.id, items: session.transcript)
        }
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

enum SSHProbe {
    static func check(host: String, path: String) async -> SSHStatus {
        await Task.detached(priority: .utility) {
            let command = "cd -- \(SSHRemote.shellPath(path)) && pwd -P"
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
                return .failed(reason: error.localizedDescription)
            }
            proc.waitUntilExit()
            let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
            let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
            guard proc.terminationStatus == 0 else {
                let reason = lastNonEmptyLine(stderrText) ?? lastNonEmptyLine(stdoutText)
                return .failed(reason: reason?.isEmpty == false ? reason! : "ssh exited \(proc.terminationStatus)")
            }
            let resolvedPath = lastNonEmptyLine(stdoutText) ?? path
            return .connected(path: resolvedPath)
        }.value
    }

    private static func lastNonEmptyLine(_ raw: String) -> String? {
        raw.split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
