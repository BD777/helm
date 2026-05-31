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
    var sshProfileAccess: [SSHProfileAccessState]
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
    var selectedSessionCanAppendPrompt: Bool {
        guard let selectedSessionId,
              isSessionStreaming(selectedSessionId)
        else { return false }
        return activeRuns[selectedSessionId]?.adapter.supportsPromptAppend ?? false
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

    private var schedulerWorkspaceLayouts: [UUID: ProjectSchedulerWorkspaceLayout] = [:]
    private var workflowResourceLocks: [String: UUID] = [:]

    /// Bumped each time the user sends a message. The chat list watches this
    /// to force a scroll-to-bottom after Send, regardless of where the user
    /// was previously parked. Distinct from the geometry-based stick-to-
    /// bottom: pressing Send is an explicit "show me what just landed" intent.
    var sendTick: Int = 0
    var appendTick: Int = 0

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
    private var pendingTargetSessionIndexSaveTask: Task<Void, Never>?
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

        // Caller-provided projects/sessions (previews / tests) win over disk.
        let profilesFile = profileStore.load()
        let stateFile = stateStore.load()
        let loadedProjects = projects.isEmpty ? stateFile.projects : projects
        let sshProjectIds = Set(loadedProjects.filter { $0.location.isSSH }.map(\.id))
        let scopedProviderIdsToDrop = Set(profilesFile.providers.filter { provider in
            provider.sshProjectId.map { !sshProjectIds.contains($0) } ?? false
        }.map(\.id))

        self.providers = profilesFile.providers.filter { provider in
            provider.sshProjectId.map { sshProjectIds.contains($0) } ?? true
        }
        // Skip Models that lack a providerModelId — those are partial drafts
        // that an earlier code path persisted before we added validation.
        // They have no value and they pollute pickers.
        let cleanModels = profilesFile.models.filter {
            !$0.providerModelId.isEmpty && !scopedProviderIdsToDrop.contains($0.providerId)
        }
        self.models = cleanModels
        self.profiles = profilesFile.profiles.filter { profile in
            profile.sshProjectId.map { sshProjectIds.contains($0) } ?? true
        }
        self.projects = loadedProjects
        var loadedSchedulers = stateFile.schedulers.filter { scheduler in
            loadedProjects.contains { $0.id == scheduler.projectId }
        }
        self.sshProfileAccess = stateFile.sshProfileAccess.filter { access in
            loadedProjects.contains { project in
                project.id == access.projectId && project.location.isSSH
            }
        }
        let managedWorkerSessionIds = Set(loadedSchedulers.flatMap { scheduler in
            scheduler.tasks.compactMap(\.sessionId)
        })
        // Drop sessions that were never sent. Keep sessions with either a
        // vendor-issued id or Helm's own transcript snapshot; a failed launch
        // can still produce useful chat context before the vendor reports an id.
        // Project Inbox worker sessions are also kept even before their
        // first run because the scheduler state owns them by reference.
        let cleanSessions = (sessions.isEmpty ? stateFile.sessions : sessions)
            .filter {
                $0.isArchived ||
                !$0.transcript.isEmpty ||
                $0.vendorSessionId != nil ||
                Self.hasRestorableTranscriptSnapshot(sessionId: $0.id) ||
                managedWorkerSessionIds.contains($0.id)
            }
        let removedSchedulerTaskIds = Self.removeSchedulerTasks(
            referencingMissingSessionsFrom: &loadedSchedulers,
            existingSessionIds: Set(cleanSessions.map(\.id)),
            updatedAt: Date()
        )
        self.projectSchedulers = loadedSchedulers
        self.sessions = cleanSessions
        self.sidebarSessions = Self.sidebarSessions(from: cleanSessions)
        let restoredSelection = selectedSessionId ?? stateFile.selectedSessionId
        self.selectedSessionId = cleanSessions.contains {
            $0.id == restoredSelection && !$0.isArchived
        }
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

        let localTargetIndex = TargetSessionIndexStore.loadLocal()
        var importedTargetSessions = false
        for project in self.projects where !project.location.isSSH {
            importedTargetSessions = importTargetSessionIndex(localTargetIndex,
                                                             for: project)
                || importedTargetSessions
        }

        // If we filtered any invalid records during load, persist the cleaned
        // table so the JSON on disk stops carrying the orphan.
        if cleanModels.count != profilesFile.models.count {
            scheduleProfilesSave()
        }
        if cleanSessions.count != stateFile.sessions.count ||
            importedTargetSessions ||
            !removedSchedulerTaskIds.isEmpty {
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

    var sshProjects: [Project] {
        projects.filter { $0.location.isSSH }
    }

    var globalProviders: [Provider] {
        providers.filter { $0.sshProjectId == nil }
    }

    var globalProfiles: [Profile] {
        profiles.filter { $0.sshProjectId == nil }
    }

    func remoteProviders(forSSHProject projectId: UUID) -> [Provider] {
        providers.filter { $0.sshProjectId == projectId }
    }

    func remoteProfiles(forSSHProject projectId: UUID) -> [Profile] {
        profiles.filter { $0.sshProjectId == projectId }
    }

    func profiles(for vendor: Vendor) -> [Profile] {
        globalProfiles.filter { $0.vendor == vendor }
    }

    func providers(for vendor: Vendor) -> [Provider] {
        globalProviders.filter { $0.vendor == vendor }
    }

    func models(in providerId: UUID) -> [Model] {
        models.filter { $0.providerId == providerId }
    }

    func availableProfiles(for projectId: UUID) -> [Profile] {
        guard let project = projects.first(where: { $0.id == projectId }) else { return [] }
        guard project.location.isSSH else { return globalProfiles }

        let allowed = Set(sshProfileAccessState(for: projectId).allowedGlobalProfileIds)
        return profiles.filter { profile in
            if profile.sshProjectId == projectId { return true }
            return profile.sshProjectId == nil && allowed.contains(profile.id)
        }
    }

    func availableProfiles(for projectId: UUID, vendor: Vendor) -> [Profile] {
        availableProfiles(for: projectId).filter { $0.vendor == vendor }
    }

    func isProfileAvailable(_ profileId: UUID, for projectId: UUID) -> Bool {
        availableProfiles(for: projectId).contains { $0.id == profileId }
    }

    func isGlobalProfileAllowed(_ profileId: UUID, inSSHProject projectId: UUID) -> Bool {
        sshProfileAccessState(for: projectId).allowedGlobalProfileIds.contains(profileId)
    }

    func setGlobalProfile(_ profileId: UUID, allowed: Bool, forSSHProject projectId: UUID) {
        guard globalProfiles.contains(where: { $0.id == profileId }),
              projects.contains(where: { $0.id == projectId && $0.location.isSSH })
        else { return }
        let idx = ensureSSHProfileAccessIndex(for: projectId)
        var ids = sshProfileAccess[idx].allowedGlobalProfileIds
        if allowed {
            if !ids.contains(profileId) { ids.append(profileId) }
        } else {
            ids.removeAll { $0 == profileId }
        }
        sshProfileAccess[idx].allowedGlobalProfileIds = ids
        scheduleStateSave()
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
        // Collect profile IDs that will be deleted so we can clean up references.
        let deletedProfileIds = Set(profiles
            .filter { p in
                p.providerId == id ||
                dropped.contains(p.primaryModelId) ||
                (p.opusModelId.map { dropped.contains($0) } ?? false) ||
                (p.sonnetModelId.map { dropped.contains($0) } ?? false) ||
                (p.haikuModelId.map { dropped.contains($0) } ?? false)
            }
            .map(\.id))
        profiles.removeAll { p in
            p.providerId == id ||
            dropped.contains(p.primaryModelId) ||
            (p.opusModelId.map { dropped.contains($0) } ?? false) ||
            (p.sonnetModelId.map { dropped.contains($0) } ?? false) ||
            (p.haikuModelId.map { dropped.contains($0) } ?? false)
        }
        cleanupReferences(toDeletedProfiles: deletedProfileIds)
        scheduleStateSave()
        scheduleProfilesSave()
    }

    func upsertModel(_ m: Model) {
        if let i = models.firstIndex(where: { $0.id == m.id }) { models[i] = m }
        else { models.append(m) }
        scheduleProfilesSave()
    }

    func deleteModel(_ id: UUID) {
        // Collect profile IDs that will be deleted so we can clean up references.
        let deletedProfileIds = Set(profiles
            .filter { p in
                p.primaryModelId == id ||
                p.opusModelId == id ||
                p.sonnetModelId == id ||
                p.haikuModelId == id
            }
            .map(\.id))
        models.removeAll { $0.id == id }
        // Profiles pointing at it become invalid; drop them rather than
        // leave dangling pointers.
        profiles.removeAll { p in
            p.primaryModelId == id ||
            p.opusModelId == id ||
            p.sonnetModelId == id ||
            p.haikuModelId == id
        }
        cleanupReferences(toDeletedProfiles: deletedProfileIds)
        scheduleStateSave()
        scheduleProfilesSave()
    }

    func upsertProfile(_ p: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p }
        else { profiles.append(p) }
        scheduleProfilesSave()
    }

    /// Cleans up scheduler default-worker references and archives orphaned
    /// sessions after a profile (or cascade of profiles) has been deleted.
    private func cleanupReferences(toDeletedProfiles deletedProfileIds: Set<UUID>) {
        guard !deletedProfileIds.isEmpty else { return }
        for idx in sshProfileAccess.indices {
            sshProfileAccess[idx].allowedGlobalProfileIds.removeAll { deletedProfileIds.contains($0) }
        }
        for idx in projectSchedulers.indices {
            if let wid = projectSchedulers[idx].defaultWorkerProfileId,
               deletedProfileIds.contains(wid) {
                projectSchedulers[idx].defaultWorkerProfileId = nil
            }
        }
        let orphanSessionIds = sessions
            .filter { deletedProfileIds.contains($0.profileId) && !$0.isArchived }
            .map(\.id)
        for sessionId in orphanSessionIds {
            if !isSessionStreaming(sessionId) {
                archiveSession(sessionId, archivedAt: Date(), schedulesSave: false)
            }
        }
    }

    func deleteProfile(_ id: UUID) {
        let removedProfile = profiles.first { $0.id == id }
        profiles.removeAll { $0.id == id }
        cleanupReferences(toDeletedProfiles: [id])
        // If the deleted profile is a remote one, clean up its provider if now unused.
        if let removedProfile, removedProfile.sshProjectId != nil {
            deleteRemoteProviderIfUnused(removedProfile.providerId)
        }
        scheduleStateSave()
        scheduleProfilesSave()
    }

    @discardableResult
    func createRemoteCodexProfile(_ candidate: RemoteCodexProfileCandidate,
                                  provider: RemoteCodexProviderCandidate,
                                  forSSHProject projectId: UUID) -> UUID? {
        guard projects.contains(where: { $0.id == projectId && $0.location.isSSH }) else { return nil }

        let remoteProviderKey = provider.remoteConfigKey
        let providerId: UUID
        if let existing = providers.first(where: {
            $0.sshProjectId == projectId &&
            $0.vendor == .codex &&
            $0.remoteCodexProviderKey == remoteProviderKey
        }) {
            providerId = existing.id
        } else {
            let p = Provider(
                id: UUID(),
                name: provider.displayName,
                vendor: .codex,
                sshProjectId: projectId,
                remoteCodexProviderKey: remoteProviderKey,
                baseURL: provider.baseURL,
                authToken: "",
                wireAPI: provider.wireAPI,
                httpHeaders: [:],
                requiresOpenAIAuth: provider.requiresOpenAIAuth,
                extraEnv: [:]
            )
            providers.append(p)
            providerId = p.id
        }

        let modelId: UUID
        if let existing = models.first(where: {
            $0.providerId == providerId && $0.providerModelId == candidate.modelId
        }) {
            modelId = existing.id
        } else {
            let model = Model(
                id: UUID(),
                providerId: providerId,
                providerModelId: candidate.modelId,
                alias: ""
            )
            models.append(model)
            modelId = model.id
        }

        if let existing = profiles.first(where: {
            $0.sshProjectId == projectId &&
            $0.vendor == .codex &&
            $0.providerId == providerId &&
            $0.primaryModelId == modelId &&
            $0.delegateVendorProfile == candidate.profileName
        }) {
            return existing.id
        }

        let profile = Profile(
            id: UUID(),
            name: candidate.displayName,
            vendor: .codex,
            sshProjectId: projectId,
            providerId: providerId,
            primaryModelId: modelId,
            commandPath: "",
            configRoot: nil,
            opusModelId: nil, sonnetModelId: nil, haikuModelId: nil,
            subagentModelId: nil,
            autoCompactWindow: nil,
            claudePermissionMode: nil,
            claudeEffort: nil,
            reasoningEffort: candidate.reasoningEffort,
            serviceTier: candidate.serviceTier,
            sandboxMode: candidate.sandboxMode,
            approvalMode: candidate.approvalMode,
            delegateVendorProfile: candidate.profileName
        )
        profiles.append(profile)
        scheduleProfilesSave()
        return profile.id
    }

    @discardableResult
    func createRemoteClaudeProfile(_ candidate: RemoteClaudeProviderCandidate,
                                   forSSHProject projectId: UUID) -> UUID? {
        guard projects.contains(where: { $0.id == projectId && $0.location.isSSH }) else { return nil }

        let providerId: UUID
        if let existing = providers.first(where: {
            $0.sshProjectId == projectId &&
            $0.vendor == .claude &&
            $0.name == candidate.displayName
        }) {
            providerId = existing.id
        } else {
            let provider = Provider(
                id: UUID(),
                name: candidate.displayName,
                vendor: .claude,
                sshProjectId: projectId,
                remoteCodexProviderKey: nil,
                baseURL: "",
                authToken: "",
                wireAPI: .responses,
                httpHeaders: [:],
                requiresOpenAIAuth: false,
                extraEnv: [:]
            )
            providers.append(provider)
            providerId = provider.id
        }

        let modelId: UUID
        if let existing = models.first(where: {
            $0.providerId == providerId &&
            $0.providerModelId == RemoteClaudeProviderCandidate.defaultModelId
        }) {
            modelId = existing.id
        } else {
            let model = Model(
                id: UUID(),
                providerId: providerId,
                providerModelId: RemoteClaudeProviderCandidate.defaultModelId,
                alias: "Default Claude Code model"
            )
            models.append(model)
            modelId = model.id
        }

        if let existing = profiles.first(where: {
            $0.sshProjectId == projectId &&
            $0.vendor == .claude &&
            $0.providerId == providerId &&
            $0.primaryModelId == modelId &&
            $0.commandPath == candidate.commandPath
        }) {
            return existing.id
        }

        let profile = Profile(
            id: UUID(),
            name: candidate.displayName,
            vendor: .claude,
            sshProjectId: projectId,
            providerId: providerId,
            primaryModelId: modelId,
            commandPath: candidate.commandPath,
            configRoot: nil,
            opusModelId: nil, sonnetModelId: nil, haikuModelId: nil,
            subagentModelId: nil,
            autoCompactWindow: nil,
            claudePermissionMode: nil,
            claudeEffort: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            sandboxMode: nil,
            approvalMode: nil,
            delegateVendorProfile: nil
        )
        profiles.append(profile)
        scheduleProfilesSave()
        return profile.id
    }

    private func sshProfileAccessState(for projectId: UUID) -> SSHProfileAccessState {
        sshProfileAccess.first { $0.projectId == projectId }
            ?? SSHProfileAccessState(projectId: projectId)
    }

    private func ensureSSHProfileAccessIndex(for projectId: UUID) -> Int {
        if let idx = sshProfileAccess.firstIndex(where: { $0.projectId == projectId }) {
            return idx
        }
        sshProfileAccess.append(SSHProfileAccessState(projectId: projectId))
        return sshProfileAccess.count - 1
    }

    private func deleteRemoteProviderIfUnused(_ providerId: UUID) {
        guard let provider = providers.first(where: { $0.id == providerId }),
              provider.sshProjectId != nil,
              !profiles.contains(where: { $0.providerId == providerId })
        else { return }
        providers.removeAll { $0.id == providerId }
        models.removeAll { $0.providerId == providerId }
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
            schedulers: projectSchedulers,
            sshProfileAccess: sshProfileAccess
        ))
        scheduleTargetSessionIndexSave()
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
            schedulers: projectSchedulers,
            sshProfileAccess: sshProfileAccess
        ))
        pendingTargetSessionIndexSaveTask?.cancel()
        pendingTargetSessionIndexSaveTask = nil
        let entriesByTarget = targetSessionIndexEntriesByTarget()
        if !entriesByTarget.isEmpty {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await TargetSessionIndexStore.upsert(entriesByTarget)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5)
        }
    }

    private func scheduleTargetSessionIndexSave() {
        pendingTargetSessionIndexSaveTask?.cancel()
        let entriesByTarget = targetSessionIndexEntriesByTarget()
        guard !entriesByTarget.isEmpty else { return }
        pendingTargetSessionIndexSaveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await TargetSessionIndexStore.upsert(entriesByTarget)
        }
    }

    private func targetSessionIndexEntriesByTarget() -> [TargetSessionIndexLocation: [TargetSessionIndexEntry]] {
        let updatedAt = TargetSessionIndexStore.timestamp()
        var grouped: [TargetSessionIndexLocation: [TargetSessionIndexEntry]] = [:]

        for session in sessions where !session.isDraft && !session.isArchived {
            guard let project = projects.first(where: { $0.id == session.projectId }),
                  let profile = profile(session.profileId),
                  let target = TargetSessionIndexStore.targetLocation(for: project),
                  let vendorSessionId = restorableVendorSessionId(for: session,
                                                                  vendor: profile.vendor)
            else { continue }

            let entry = TargetSessionIndexEntry(
                id: session.id,
                projectPath: TargetSessionIndexStore.canonicalProjectPath(for: project),
                projectName: project.name,
                vendor: profile.vendor,
                title: session.title,
                lastUpdate: session.lastUpdate,
                updatedAt: updatedAt,
                vendorSessionId: vendorSessionId,
                profileName: profile.name,
                claudePermissionMode: session.claudePermissionMode,
                codexSandboxMode: session.codexSandboxMode,
                codexApprovalMode: session.codexApprovalMode,
                claudeEffort: session.claudeEffort,
                codexEffort: session.codexEffort
            )
            grouped[target, default: []].append(entry)
        }
        return grouped
    }

    private func restorableVendorSessionId(for session: Session,
                                           vendor: Vendor) -> String? {
        if let vendorSessionId = session.vendorSessionId,
           !vendorSessionId.isEmpty {
            return vendorSessionId
        }
        switch vendor {
        case .claude:
            return session.id.uuidString.lowercased()
        case .codex:
            return nil
        }
    }

    @discardableResult
    private func importTargetSessionIndex(_ index: TargetSessionIndexFile,
                                          for project: Project) -> Bool {
        let projectPaths = TargetSessionIndexStore.projectPathCandidates(for: project)
        var imported = false

        for entry in index.sessions where projectPaths.contains(entry.projectPath) {
            if let existingIdx = sessions.firstIndex(where: { $0.id == entry.id }) {
                guard sessions[existingIdx].projectId == project.id,
                      profile(sessions[existingIdx].profileId)?.vendor == entry.vendor
                else { continue }
                var changed = false
                if sessions[existingIdx].vendorSessionId == nil {
                    sessions[existingIdx].vendorSessionId = entry.vendorSessionId
                    changed = true
                }
                if sessions[existingIdx].title == "New chat",
                   entry.title != "New chat" {
                    sessions[existingIdx].title = entry.title
                    changed = true
                }
                if changed {
                    upsertSidebarSession(for: sessions[existingIdx])
                    imported = true
                }
                continue
            }

            guard let profile = profileForImportedTargetSession(entry,
                                                                projectId: project.id)
            else { continue }

            let session = Session(
                id: entry.id,
                projectId: project.id,
                title: entry.title,
                profileId: profile.id,
                claudePermissionMode: entry.claudePermissionMode,
                codexSandboxMode: entry.codexSandboxMode,
                codexApprovalMode: entry.codexApprovalMode,
                claudeEffort: entry.claudeEffort,
                codexEffort: entry.codexEffort,
                lastUpdate: entry.lastUpdate,
                vendorSessionId: entry.vendorSessionId,
                isDraft: false
            )
            sessions.append(session)
            upsertSidebarSession(for: session)
            imported = true
        }

        if imported {
            NSLog("[helm.target-sessions] imported sessions for %@",
                  project.name)
        }
        return imported
    }

    private func profileForImportedTargetSession(_ entry: TargetSessionIndexEntry,
                                                 projectId: UUID) -> Profile? {
        let candidates = availableProfiles(for: projectId, vendor: entry.vendor)
        if let exact = candidates.first(where: { $0.name == entry.profileName }) {
            return exact
        }
        return candidates.first
    }

    private func importRemoteTargetSessionIndex(for project: Project) async -> Bool {
        guard case .ssh(let host, _, let status) = project.location,
              status.isConnected
        else { return false }
        do {
            let index = try await TargetSessionIndexStore.loadRemote(host: host)
            return importTargetSessionIndex(index, for: project)
        } catch {
            NSLog("[helm.target-sessions] remote load failed for %@: %@",
                  host, error.localizedDescription)
            return false
        }
    }

    private func removeTargetSessionIndexEntries(_ ids: [UUID],
                                                 for project: Project) {
        guard let target = TargetSessionIndexStore.targetLocation(for: project),
              !ids.isEmpty
        else { return }
        let idsByTarget = [target: ids]
        Task.detached {
            await TargetSessionIndexStore.remove(idsByTarget)
        }
    }

    // MARK: - Session helpers

    func session(_ id: UUID) -> Session? {
        sessions.first { $0.id == id }
    }

    var selectedSession: Session? {
        get { sessions.first { $0.id == selectedSessionId && !$0.isArchived } }
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
        sessions.filter { $0.projectId == projectId && !$0.isDraft && !$0.isArchived }
    }

    func sidebarSessions(in projectId: UUID) -> [SidebarSession] {
        sidebarSessions.filter { $0.projectId == projectId }
    }

    var archivedSessions: [Session] {
        sessions
            .filter(\.isArchived)
            .sorted {
                ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
            }
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

    @discardableResult
    func archiveSession(_ id: UUID) -> Bool {
        archiveSession(id, archivedAt: Date(), schedulesSave: true)
    }

    @discardableResult
    func unarchiveSession(_ id: UUID) -> Bool {
        guard let idx = sessions.firstIndex(where: { $0.id == id }),
              sessions[idx].isArchived
        else { return false }

        sessions[idx].archivedAt = nil
        upsertSidebarSession(for: sessions[idx])
        scheduleStateSave()
        return true
    }

    func deleteSession(_ id: UUID) {
        guard !isSessionStreaming(id),
              let idx = sessions.firstIndex(where: { $0.id == id })
        else { return }
        let projectId = sessions[idx].projectId
        if let project = projects.first(where: { $0.id == projectId }) {
            removeTargetSessionIndexEntries([id], for: project)
        }
        removeSchedulerEntries(referencingSession: id)
        let wasSelected = selectedSessionId == id
        sessions.remove(at: idx)
        removeSidebarSession(id)
        TranscriptSnapshotStore.delete(sessionId: id)
        if wasSelected {
            selectedSessionId = sessions.first {
                $0.projectId == projectId && !$0.isDraft && !$0.isArchived
            }?.id
        } else {
            scheduleStateSave()
        }
    }

    @discardableResult
    private func archiveSession(_ id: UUID,
                                archivedAt: Date,
                                schedulesSave: Bool) -> Bool {
        guard !isSessionStreaming(id),
              let idx = sessions.firstIndex(where: { $0.id == id })
        else { return false }

        if sessions[idx].archivedAt == archivedAt {
            return false
        }

        let projectId = sessions[idx].projectId
        if let project = projects.first(where: { $0.id == projectId }) {
            removeTargetSessionIndexEntries([id], for: project)
        }

        sessions[idx].isDraft = false
        sessions[idx].archivedAt = archivedAt
        removeSidebarSession(id)

        if selectedSessionId == id {
            selectedProjectId = projectId
            selectedSessionId = nil
        } else if schedulesSave {
            scheduleStateSave()
        }

        return true
    }

    func toggleCollapsed(_ projectId: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[i].collapsed.toggle()
        scheduleStateSave()
    }

    func deleteProject(_ projectId: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let removedSessionIds = sessions.filter { $0.projectId == projectId }.map(\.id)
        if removedSessionIds.contains(where: isSessionStreaming) { return }
        let removedProject = projects[idx]
        removeTargetSessionIndexEntries(removedSessionIds, for: removedProject)

        projects.remove(at: idx)
        sessions.removeAll { $0.projectId == projectId }
        sidebarSessions.removeAll { removedSessionIds.contains($0.id) }
        for sessionId in removedSessionIds {
            TranscriptSnapshotStore.delete(sessionId: sessionId)
        }
        projectSchedulers.removeAll { $0.projectId == projectId }
        sshProfileAccess.removeAll { $0.projectId == projectId }

        let removedProviderIds = Set(providers.filter { $0.sshProjectId == projectId }.map(\.id))
        providers.removeAll { $0.sshProjectId == projectId }
        models.removeAll { removedProviderIds.contains($0.providerId) }
        profiles.removeAll { $0.sshProjectId == projectId }

        if let sid = selectedSessionId, removedSessionIds.contains(sid) {
            selectedSessionId = nil
        }
        if selectedProjectId == projectId {
            selectedProjectId = projects.first?.id
        }
        if !removedProviderIds.isEmpty {
            scheduleProfilesSave()
        }
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
        sessions.filter { !$0.isDraft && !$0.isArchived }.map(SidebarSession.init)
    }

    private static func hasRestorableTranscriptSnapshot(sessionId: UUID) -> Bool {
        guard TranscriptSnapshotStore.exists(sessionId: sessionId) else { return false }

        let rawSnapshot = TranscriptSnapshotStore.load(sessionId: sessionId)
        let snapshot = removingRecoverableResumeErrors(from: rawSnapshot)
        guard !snapshot.isEmpty else {
            TranscriptSnapshotStore.delete(sessionId: sessionId)
            return false
        }

        if snapshot.count != rawSnapshot.count {
            TranscriptSnapshotStore.save(sessionId: sessionId, items: snapshot)
        }
        return true
    }

    private func upsertSidebarSession(for session: Session) {
        if session.isDraft || session.isArchived {
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

    private func removeSchedulerEntries(referencingSession sessionId: UUID) {
        let removedTaskIds = Self.removeSchedulerTasks(
            referencingMissingSessionsFrom: &projectSchedulers,
            existingSessionIds: Set(sessions.map(\.id)).subtracting([sessionId]),
            updatedAt: Date()
        )
        guard !removedTaskIds.isEmpty else { return }
        pendingApprovalQueue.removeAll { entry in
            entry.sessionId == sessionId
        }
    }

    @discardableResult
    private static func removeSchedulerTasks(referencingMissingSessionsFrom schedulers: inout [ProjectSchedulerState],
                                             existingSessionIds: Set<UUID>,
                                             updatedAt now: Date) -> Set<UUID> {
        var removedTaskIds: Set<UUID> = []

        for schedulerIndex in schedulers.indices {
            let staleTaskIds = Set(schedulers[schedulerIndex].tasks.compactMap { task -> UUID? in
                guard let sessionId = task.sessionId,
                      !existingSessionIds.contains(sessionId)
                else { return nil }
                return task.id
            })
            guard !staleTaskIds.isEmpty else { continue }

            schedulers[schedulerIndex].tasks.removeAll { task in
                staleTaskIds.contains(task.id)
            }
            schedulers[schedulerIndex].inbox.removeAll { item in
                item.taskId.map(staleTaskIds.contains) ?? false
            }
            schedulers[schedulerIndex].humanActions.removeAll { action in
                action.taskId.map(staleTaskIds.contains) ?? false
            }
            schedulers[schedulerIndex].workflowRuns.removeAll { run in
                staleTaskIds.contains(run.taskId)
            }
            schedulers[schedulerIndex].updatedAt = now
            removedTaskIds.formUnion(staleTaskIds)
        }

        return removedTaskIds
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

    func unmanagedProjectSessions(in projectId: UUID) -> [Session] {
        let state = schedulerState(for: projectId)
        let managedSessionIds = Set(state.tasks.compactMap(\.sessionId))
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

    func workflowRun(forTask taskId: UUID, projectId: UUID) -> ProjectWorkflowRun? {
        schedulerState(for: projectId).workflowRuns.first { $0.taskId == taskId }
    }

    @discardableResult
    func recordWorkflowArtifact(taskId: UUID,
                                projectId: UUID,
                                kind: ProjectWorkflowArtifactKind,
                                label: String,
                                value: String) -> Bool {
        let idx = ensureSchedulerStateIndex(for: projectId)
        guard let runIndex = projectSchedulers[idx].workflowRuns.firstIndex(where: { $0.taskId == taskId }) else {
            return false
        }
        projectSchedulers[idx].workflowRuns[runIndex].artifacts.append(
            ProjectWorkflowArtifact(kind: kind,
                                    label: label,
                                    value: value)
        )
        projectSchedulers[idx].workflowRuns[runIndex].updatedAt = Date()
        projectSchedulers[idx].updatedAt = Date()
        scheduleStateSave()
        return true
    }

    @discardableResult
    func acquireWorkflowResourceLock(taskId: UUID,
                                     projectId: UUID,
                                     resource: String) -> Bool {
        let idx = ensureSchedulerStateIndex(for: projectId)
        guard let workflowId = projectSchedulers[idx].workflowRuns.first(where: { $0.taskId == taskId })?.id else {
            return false
        }
        let key = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        if let owner = workflowResourceLocks[key],
           owner != workflowId {
            return false
        }
        workflowResourceLocks[key] = workflowId
        return recordWorkflowArtifact(taskId: taskId,
                                      projectId: projectId,
                                      kind: .note,
                                      label: "Resource lock",
                                      value: key)
    }

    func releaseWorkflowResourceLocks(taskId: UUID,
                                      projectId: UUID) {
        let state = schedulerState(for: projectId)
        guard let workflowId = state.workflowRuns.first(where: { $0.taskId == taskId })?.id else {
            return
        }
        workflowResourceLocks = Dictionary(uniqueKeysWithValues: workflowResourceLocks.filter { $0.value != workflowId })
    }

    func schedulerTaskCount(in projectId: UUID,
                            phase: ProjectSchedulerTaskPhase? = nil) -> Int {
        let tasks = schedulerState(for: projectId).tasks
        guard let phase else { return tasks.count }
        return tasks.filter { $0.phase == phase }.count
    }

    func schedulerRunningTaskCount(in projectId: UUID) -> Int {
        schedulerState(for: projectId).tasks.filter { task in
            task.sessionId.map(isSessionStreaming) ?? false
        }.count
    }

    func schedulerWaitingTaskCount(in projectId: UUID) -> Int {
        schedulerState(for: projectId).tasks.filter { task in
            task.phase != .done && !(task.sessionId.map(isSessionStreaming) ?? false)
        }.count
    }

    func setDefaultWorkerProfile(_ profileId: UUID, for projectId: UUID) {
        guard profile(profileId) != nil,
              isProfileAvailable(profileId, for: projectId)
        else { return }
        let idx = ensureSchedulerStateIndex(for: projectId)
        projectSchedulers[idx].defaultWorkerProfileId = profileId
        projectSchedulers[idx].updatedAt = Date()
        scheduleStateSave()
        startRunnableSchedulerTasks(projectId: projectId)
    }

    func defaultWorkerProfile(for projectId: UUID) -> Profile? {
        let state = schedulerState(for: projectId)
        let available = availableProfiles(for: projectId)
        return state.defaultWorkerProfileId.flatMap { id in
            available.first { $0.id == id }
        }
            ?? available.first { $0.vendor == .codex }
            ?? available.first
    }

    func canStartSchedulerTask(_ taskId: UUID, projectId: UUID) -> Bool {
        guard let schedulerIndex = projectSchedulers.firstIndex(where: { $0.projectId == projectId }),
              let project = projects.first(where: { $0.id == projectId }),
              let taskIndex = projectSchedulers[schedulerIndex].tasks.firstIndex(where: { $0.id == taskId })
        else { return false }
        return schedulerStartBlockers(forTaskAt: taskIndex,
                                      schedulerIndex: schedulerIndex,
                                      project: project).isEmpty
    }

    @discardableResult
    func submitProjectIdea(_ text: String,
                           displayParts: [Part]? = nil,
                           attachments: [ImageAttachment] = [],
                           projectId: UUID,
                           workerProfileId: UUID? = nil,
                           runConfiguration: SessionRunConfiguration? = nil) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty,
              let project = projects.first(where: { $0.id == projectId })
        else { return nil }
        let workerProfile = workerProfileId.flatMap(profile)
            ?? defaultWorkerProfile(for: projectId)
        guard let workerProfile else { return nil }

        let now = Date()
        let sessionId = UUID()
        let expectedAttachmentCount = Set(attachments.map(\.contentHash)).count
        let sessionAttachments = ComposerImagePasteboard.copyAttachments(
            attachments,
            to: AppPaths.imagesDir(for: sessionId),
            logPrefix: "[helm.project-inbox]"
        )
        if !attachments.isEmpty && sessionAttachments.count != expectedAttachmentCount {
            ComposerImagePasteboard.removeFiles(sessionAttachments)
            return nil
        }
        let title = Self.title(for: trimmed, attachments: sessionAttachments, maxLength: 48)
        let inboxText = trimmed.isEmpty ? title : trimmed
        let layout = schedulerWorkspaceLayout(for: project)
        guard createSession(in: projectId,
                            title: title,
                            profileId: workerProfile.id,
                            isDraft: false,
                            select: false,
                            runConfiguration: runConfiguration ?? .defaults(for: workerProfile),
                            id: sessionId) != nil
        else {
            ComposerImagePasteboard.removeFiles(sessionAttachments)
            return nil
        }
        let taskId = UUID()
        let inboxItem = ProjectSchedulerInboxItem(
            id: UUID(),
            text: inboxText,
            createdAt: now,
            status: .accepted,
            taskId: taskId
        )
        let task = ProjectSchedulerTask(
            id: taskId,
            title: title,
            idea: trimmed,
            displayParts: displayParts,
            attachments: sessionAttachments.isEmpty ? nil : sessionAttachments,
            sessionId: sessionId,
            phase: .planned,
            summary: "Waiting to start.",
            dependencies: [],
            resourceNotes: layout.workerNotes,
            worktreeHint: worktreeHint(for: title, layout: layout),
            createdAt: now,
            updatedAt: now
        )
        let workflowRun = Self.workflowRun(for: task,
                                           sessionId: sessionId,
                                           createdAt: now)
        let idx = ensureSchedulerStateIndex(for: projectId)
        projectSchedulers[idx].inbox.insert(inboxItem, at: 0)
        projectSchedulers[idx].tasks.insert(task, at: 0)
        projectSchedulers[idx].workflowRuns.insert(workflowRun, at: 0)
        projectSchedulers[idx].defaultWorkerProfileId = workerProfile.id
        projectSchedulers[idx].updatedAt = now
        selectedProjectId = projectId
        scheduleStateSave()
        refreshSchedulerWorkspaceLayoutIfNeeded(projectId: projectId)
        startRunnableSchedulerTasks(projectId: projectId)
        return taskId
    }

    @discardableResult
    func adoptSessionIntoScheduler(_ sessionId: UUID, projectId: UUID) -> UUID? {
        guard let session = sessions.first(where: {
            $0.id == sessionId && $0.projectId == projectId && !$0.isDraft && !$0.isArchived
        }),
              schedulerTask(for: sessionId) == nil
        else { return nil }
        let idx = ensureSchedulerStateIndex(for: projectId)

        let now = Date()
        let taskId = UUID()
        let isRunning = isSessionStreaming(sessionId)
        let phase: ProjectSchedulerTaskPhase = isRunning ? .running : .waiting
        let task = ProjectSchedulerTask(
            id: taskId,
            title: session.title,
            idea: "Imported existing session \"\(session.title)\" so the project scheduler can track its next step.",
            sessionId: sessionId,
            phase: phase,
            summary: isRunning
                ? "Existing session is running and is now tracked by the project scheduler."
                : "Waiting for review: existing session is idle but not marked done.",
            dependencies: [],
            resourceNotes: ["Imported from an existing session."],
            worktreeHint: nil,
            createdAt: now,
            updatedAt: now
        )
        projectSchedulers[idx].tasks.insert(task, at: 0)
        projectSchedulers[idx].updatedAt = now
        scheduleStateSave()
        return taskId
    }

    @discardableResult
    func startSchedulerTask(_ taskId: UUID, projectId: UUID) -> Bool {
        let idx = ensureSchedulerStateIndex(for: projectId)
        guard let project = projects.first(where: { $0.id == projectId }),
              let taskIndex = projectSchedulers[idx].tasks.firstIndex(where: { $0.id == taskId })
        else { return false }
        guard schedulerStartBlockers(forTaskAt: taskIndex,
                                     schedulerIndex: idx,
                                     project: project).isEmpty else {
            refreshSchedulerTaskWaitState(taskIndex: taskIndex,
                                          schedulerIndex: idx,
                                          project: project)
            scheduleStateSave()
            return false
        }
        guard let sessionId = ensureWorkerSession(forTaskAt: taskIndex,
                                                  schedulerIndex: idx,
                                                  projectId: projectId)
        else { return false }
        guard !isSessionStreaming(sessionId) else { return true }

        let task = projectSchedulers[idx].tasks[taskIndex]
        var workflow = ensureWorkflowRun(forTaskAt: taskIndex,
                                         schedulerIndex: idx,
                                         sessionId: sessionId)
        markWorkflowRunStarted(workflow.id, schedulerIndex: idx)
        workflow = projectSchedulers[idx].workflowRuns.first { $0.id == workflow.id } ?? workflow
        let prompt = task.idea
        let displayParts = task.displayParts ?? (prompt.isEmpty ? [] : [.text(prompt)])
        let didSend = send(prompt,
                           displayParts: displayParts,
                           attachments: task.attachments ?? [],
                           agentPrompt: Self.workerPrompt(for: task, workflow: workflow),
                           preUserEvents: [
                            .projectWorkflowStarted(id: UUID(),
                                                    workflowId: workflow.id,
                                                    title: workflow.title,
                                                    nodeCount: workflow.nodes.count,
                                                    startedAt: Date())
                           ],
                           sessionId: sessionId)
        if !didSend {
            markWorkflowRunWaiting(taskId: task.id,
                                   schedulerIndex: idx,
                                   updatedAt: Date())
            return false
        }
        return isSessionStreaming(sessionId)
    }

    func openSchedulerTaskSession(_ taskId: UUID, projectId: UUID) {
        let state = schedulerState(for: projectId)
        guard let task = state.tasks.first(where: { $0.id == taskId }),
              let sessionId = task.sessionId,
              sessions.contains(where: { $0.id == sessionId && !$0.isArchived })
        else { return }
        selectedSessionId = sessionId
    }

    func markSchedulerTask(_ taskId: UUID,
                           projectId: UUID,
                           phase: ProjectSchedulerTaskPhase) {
        let idx = ensureSchedulerStateIndex(for: projectId)
        guard let taskIndex = projectSchedulers[idx].tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let now = Date()
        projectSchedulers[idx].tasks[taskIndex].phase = phase
        projectSchedulers[idx].tasks[taskIndex].updatedAt = now
        if phase == .readyToMerge || phase == .done {
            resolveHumanActions(projectId: projectId, taskId: taskId, kind: nil)
        }
        if phase == .done {
            markWorkflowRunPassed(taskId: taskId, schedulerIndex: idx)
            releaseWorkflowResourceLocks(taskId: taskId, projectId: projectId)
            if let sessionId = projectSchedulers[idx].tasks[taskIndex].sessionId {
                archiveSession(sessionId, archivedAt: now, schedulesSave: false)
            }
            if let inboxIndex = projectSchedulers[idx].inbox.firstIndex(where: { $0.taskId == taskId }) {
                projectSchedulers[idx].inbox[inboxIndex].status = .archived
            }
        }
        projectSchedulers[idx].updatedAt = now
        scheduleStateSave()
        if phase == .done {
            startRunnableSchedulerTasks(projectId: projectId)
        }
    }

    private func ensureSchedulerStateIndex(for projectId: UUID) -> Int {
        if let idx = projectSchedulers.firstIndex(where: { $0.projectId == projectId }) {
            return idx
        }
        projectSchedulers.append(ProjectSchedulerState(projectId: projectId))
        return projectSchedulers.count - 1
    }

    private enum ProjectSchedulerWorkspaceLayout: Equatable {
        case singleGitRepo(root: String, isRemote: Bool)
        case multipleGitRepos(roots: [String], isRemote: Bool)
        case notGitRepository(isRemote: Bool)
        case unknown(isRemote: Bool)

        var singleGitRoot: String? {
            if case .singleGitRepo(let root, _) = self { return root }
            return nil
        }

        var workerNotes: [String] {
            switch self {
            case .singleGitRepo:
                return []
            case .multipleGitRepos(let roots, let isRemote):
                let names = roots
                    .prefix(4)
                    .map { ($0 as NSString).lastPathComponent }
                    .joined(separator: ", ")
                let suffix = roots.count > 4 ? ", ..." : ""
                return [
                    "\(isRemote ? "This SSH project contains" : "This project contains") multiple Git repositories\(names.isEmpty ? "" : " (\(names)\(suffix))"). Identify the repo(s) you need and use task-scoped worktrees for code edits."
                ]
            case .notGitRepository(let isRemote):
                return [
                    "\(isRemote ? "No Git repository was detected for this SSH project" : "This project is not a Git repository"). Helm may run independent inbox work concurrently; inspect before editing and report conflicts instead of overwriting another worker's changes."
                ]
            case .unknown(let isRemote):
                return [
                    "\(isRemote ? "Helm has not finished discovering this SSH project's Git layout" : "Helm could not determine this project's Git layout"). Proceed concurrently, inspect the workspace before editing, and report conflicts."
                ]
            }
        }
    }

    private func startRunnableSchedulerTasks(projectId: UUID) {
        let schedulerIndex = ensureSchedulerStateIndex(for: projectId)
        guard let project = projects.first(where: { $0.id == projectId }) else { return }

        var startedAny = false
        var attemptedTaskIds: Set<UUID> = []
        while true {
            guard let taskIndex = projectSchedulers[schedulerIndex].tasks.indices.first(where: { index in
                let task = projectSchedulers[schedulerIndex].tasks[index]
                guard task.phase == .planned,
                      !attemptedTaskIds.contains(task.id),
                      task.sessionId.map({ !isSessionStreaming($0) }) ?? true
                else { return false }
                return schedulerStartBlockers(forTaskAt: index,
                                              schedulerIndex: schedulerIndex,
                                              project: project).isEmpty
            }) else { break }
            let taskId = projectSchedulers[schedulerIndex].tasks[taskIndex].id
            attemptedTaskIds.insert(taskId)
            if startSchedulerTask(taskId, projectId: projectId) {
                startedAny = true
            }
        }

        for taskIndex in projectSchedulers[schedulerIndex].tasks.indices {
            refreshSchedulerTaskWaitState(taskIndex: taskIndex,
                                          schedulerIndex: schedulerIndex,
                                          project: project)
        }
        if startedAny || projectSchedulers[schedulerIndex].tasks.contains(where: { $0.phase == .planned }) {
            projectSchedulers[schedulerIndex].updatedAt = Date()
            scheduleStateSave()
        }
    }

    private func schedulerStartBlockers(forTaskAt taskIndex: Int,
                                        schedulerIndex: Int,
                                        project: Project) -> [ProjectSchedulerTask] {
        guard projectSchedulers[schedulerIndex].tasks.indices.contains(taskIndex) else { return [] }
        let task = projectSchedulers[schedulerIndex].tasks[taskIndex]
        guard task.phase == .planned else { return [task] }
        guard defaultWorkerProfile(for: project.id) != nil else { return [task] }
        if case .ssh(_, _, let status) = project.location,
           !status.isConnected {
            return [task]
        }
        return []
    }

    private func refreshSchedulerTaskWaitState(taskIndex: Int,
                                               schedulerIndex: Int,
                                               project: Project) {
        guard projectSchedulers[schedulerIndex].tasks.indices.contains(taskIndex) else { return }
        let task = projectSchedulers[schedulerIndex].tasks[taskIndex]
        guard task.phase == .planned else { return }
        let blockers = schedulerStartBlockers(forTaskAt: taskIndex,
                                              schedulerIndex: schedulerIndex,
                                              project: project)
        let now = Date()
        let newSummary: String
        if defaultWorkerProfile(for: project.id) == nil {
            newSummary = "Waiting for a worker profile."
        } else if case .ssh(_, _, let status) = project.location,
                  !status.isConnected {
            newSummary = "Waiting for SSH connection: \(status.shortLabel)."
        } else {
            newSummary = "Waiting to start."
        }
        let dependencyIds = blockers
            .filter { $0.id != task.id }
            .map(\.id)
        if projectSchedulers[schedulerIndex].tasks[taskIndex].summary != newSummary ||
            projectSchedulers[schedulerIndex].tasks[taskIndex].dependencies != dependencyIds {
            projectSchedulers[schedulerIndex].tasks[taskIndex].summary = newSummary
            projectSchedulers[schedulerIndex].tasks[taskIndex].dependencies = dependencyIds
            projectSchedulers[schedulerIndex].tasks[taskIndex].updatedAt = now
        }
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
        projectSchedulers[location.schedulerIndex].tasks[location.taskIndex].phase = .waiting
        projectSchedulers[location.schedulerIndex].tasks[location.taskIndex].summary = "Waiting for review: worker session stopped."
        projectSchedulers[location.schedulerIndex].tasks[location.taskIndex].updatedAt = now
        markWorkflowRunWaiting(taskId: task.id,
                               schedulerIndex: location.schedulerIndex,
                               updatedAt: now)
        projectSchedulers[location.schedulerIndex].updatedAt = now
        scheduleStateSave()
        startRunnableSchedulerTasks(projectId: projectSchedulers[location.schedulerIndex].projectId)
    }

    private func managedTaskLocation(for sessionId: UUID) -> (schedulerIndex: Int, taskIndex: Int)? {
        for schedulerIndex in projectSchedulers.indices {
            if let taskIndex = projectSchedulers[schedulerIndex].tasks.firstIndex(where: { $0.sessionId == sessionId }) {
                return (schedulerIndex, taskIndex)
            }
        }
        return nil
    }

    private func ensureWorkflowRun(forTaskAt taskIndex: Int,
                                   schedulerIndex: Int,
                                   sessionId: UUID) -> ProjectWorkflowRun {
        let task = projectSchedulers[schedulerIndex].tasks[taskIndex]
        if let runIndex = projectSchedulers[schedulerIndex].workflowRuns.firstIndex(where: { $0.taskId == task.id }) {
            if projectSchedulers[schedulerIndex].workflowRuns[runIndex].sessionId != sessionId {
                projectSchedulers[schedulerIndex].workflowRuns[runIndex].sessionId = sessionId
                projectSchedulers[schedulerIndex].workflowRuns[runIndex].updatedAt = Date()
            }
            return projectSchedulers[schedulerIndex].workflowRuns[runIndex]
        }

        let run = Self.workflowRun(for: task,
                                   sessionId: sessionId,
                                   createdAt: Date())
        projectSchedulers[schedulerIndex].workflowRuns.insert(run, at: 0)
        projectSchedulers[schedulerIndex].updatedAt = Date()
        return run
    }

    private func markWorkflowRunStarted(_ workflowId: UUID,
                                        schedulerIndex: Int) {
        guard let runIndex = projectSchedulers[schedulerIndex].workflowRuns.firstIndex(where: { $0.id == workflowId }) else {
            return
        }
        let now = Date()
        projectSchedulers[schedulerIndex].workflowRuns[runIndex].status = .running
        projectSchedulers[schedulerIndex].workflowRuns[runIndex].updatedAt = now
        if let firstPlannedIndex = projectSchedulers[schedulerIndex].workflowRuns[runIndex].nodes.firstIndex(where: {
            $0.status == .planned
        }) {
            projectSchedulers[schedulerIndex].workflowRuns[runIndex].nodes[firstPlannedIndex].status = .running
            projectSchedulers[schedulerIndex].workflowRuns[runIndex].nodes[firstPlannedIndex].startedAt = now
        }
    }

    private func markWorkflowRunWaiting(taskId: UUID,
                                        schedulerIndex: Int,
                                        updatedAt now: Date) {
        guard let runIndex = projectSchedulers[schedulerIndex].workflowRuns.firstIndex(where: { $0.taskId == taskId }) else {
            return
        }
        projectSchedulers[schedulerIndex].workflowRuns[runIndex].status = .waiting
        projectSchedulers[schedulerIndex].workflowRuns[runIndex].updatedAt = now
        for nodeIndex in projectSchedulers[schedulerIndex].workflowRuns[runIndex].nodes.indices {
            switch projectSchedulers[schedulerIndex].workflowRuns[runIndex].nodes[nodeIndex].status {
            case .running:
                projectSchedulers[schedulerIndex].workflowRuns[runIndex].nodes[nodeIndex].status = .waiting
                projectSchedulers[schedulerIndex].workflowRuns[runIndex].nodes[nodeIndex].endedAt = now
            case .planned:
                projectSchedulers[schedulerIndex].workflowRuns[runIndex].nodes[nodeIndex].status = .waiting
            case .waiting, .passed, .failed, .skipped:
                break
            }
        }
    }

    private func markWorkflowRunPassed(taskId: UUID,
                                       schedulerIndex: Int) {
        guard let runIndex = projectSchedulers[schedulerIndex].workflowRuns.firstIndex(where: { $0.taskId == taskId }) else {
            return
        }
        let now = Date()
        projectSchedulers[schedulerIndex].workflowRuns[runIndex].status = .passed
        projectSchedulers[schedulerIndex].workflowRuns[runIndex].updatedAt = now
        for nodeIndex in projectSchedulers[schedulerIndex].workflowRuns[runIndex].nodes.indices {
            switch projectSchedulers[schedulerIndex].workflowRuns[runIndex].nodes[nodeIndex].status {
            case .failed, .skipped:
                break
            case .planned, .running, .waiting, .passed:
                projectSchedulers[schedulerIndex].workflowRuns[runIndex].nodes[nodeIndex].status = .passed
                if projectSchedulers[schedulerIndex].workflowRuns[runIndex].nodes[nodeIndex].endedAt == nil {
                    projectSchedulers[schedulerIndex].workflowRuns[runIndex].nodes[nodeIndex].endedAt = now
                }
            }
        }
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
        case .running: return 0
        case .planned: return 1
        case .waiting, .needsReview, .readyToMerge: return 2
        case .done: return 5
        }
    }

    private func schedulerWorkspaceLayout(for project: Project) -> ProjectSchedulerWorkspaceLayout {
        if let cached = schedulerWorkspaceLayouts[project.id] {
            return cached
        }
        switch project.location {
        case .ssh:
            return .unknown(isRemote: true)
        case .local(let path):
            let layout = Self.localWorkspaceLayout(path: path)
            schedulerWorkspaceLayouts[project.id] = layout
            return layout
        }
    }

    private func refreshSchedulerWorkspaceLayoutIfNeeded(projectId: UUID) {
        guard let project = projects.first(where: { $0.id == projectId }),
              case .ssh(_, _, let status) = project.location,
              status.isConnected,
              schedulerWorkspaceLayouts[projectId] == nil
        else { return }
        Task { @MainActor [weak self] in
            await self?.refreshSchedulerWorkspaceLayout(projectId: projectId)
        }
    }

    private func refreshSchedulerWorkspaceLayout(projectId: UUID) async {
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        let layout: ProjectSchedulerWorkspaceLayout
        switch project.location {
        case .local(let path):
            layout = Self.localWorkspaceLayout(path: path)
        case .ssh(let host, let path, let status):
            guard status.isConnected else {
                schedulerWorkspaceLayouts[projectId] = .unknown(isRemote: true)
                return
            }
            layout = await Self.remoteWorkspaceLayout(host: host,
                                                      path: status.resolvedPath?.isEmpty == false ? status.resolvedPath! : path)
        }
        schedulerWorkspaceLayouts[projectId] = layout
        refreshSchedulerTaskCoordination(projectId: projectId, layout: layout)
        startRunnableSchedulerTasks(projectId: projectId)
    }

    private func refreshSchedulerTaskCoordination(projectId: UUID,
                                                  layout: ProjectSchedulerWorkspaceLayout) {
        let idx = ensureSchedulerStateIndex(for: projectId)
        let now = Date()
        var changed = false
        for taskIndex in projectSchedulers[idx].tasks.indices {
            guard projectSchedulers[idx].tasks[taskIndex].phase == .planned else { continue }
            let title = projectSchedulers[idx].tasks[taskIndex].title
            let notes = layout.workerNotes
            let hint = worktreeHint(for: title, layout: layout)
            if projectSchedulers[idx].tasks[taskIndex].resourceNotes != notes ||
                projectSchedulers[idx].tasks[taskIndex].worktreeHint != hint {
                projectSchedulers[idx].tasks[taskIndex].resourceNotes = notes
                projectSchedulers[idx].tasks[taskIndex].worktreeHint = hint
                projectSchedulers[idx].tasks[taskIndex].updatedAt = now
                changed = true
            }
        }
        if changed {
            projectSchedulers[idx].updatedAt = now
            scheduleStateSave()
        }
    }

    private static func localWorkspaceLayout(path: String) -> ProjectSchedulerWorkspaceLayout {
        if let root = enclosingGitRoot(for: path) {
            return .singleGitRepo(root: root, isRemote: false)
        }
        let nested = nestedGitRepositories(under: path)
        if nested.count == 1, let root = nested.first {
            return .singleGitRepo(root: root, isRemote: false)
        }
        if nested.count > 1 {
            return .multipleGitRepos(roots: nested, isRemote: false)
        }
        return .notGitRepository(isRemote: false)
    }

    private static func remoteWorkspaceLayout(host: String,
                                              path: String) async -> ProjectSchedulerWorkspaceLayout {
        let command = remoteWorkspaceLayoutCommand(path: path)
        let task = Task.detached(priority: .utility) { () -> ProjectSchedulerWorkspaceLayout in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: SSHRemote.executable)
            proc.arguments = SSHRemote.arguments(host: host,
                                                 remoteCommand: command,
                                                 batchMode: true,
                                                 connectTimeout: 8)

            let stdout = Pipe()
            proc.standardOutput = stdout
            proc.standardError = Pipe()

            do {
                try proc.run()
            } catch {
                return .unknown(isRemote: true)
            }
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return .unknown(isRemote: true) }
            let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
            let lines = stdoutText
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            guard let kindLine = lines.first else { return .unknown(isRemote: true) }
            if kindLine.hasPrefix("single\t") {
                let root = String(kindLine.dropFirst("single\t".count))
                return root.isEmpty ? .unknown(isRemote: true) : .singleGitRepo(root: root, isRemote: true)
            }
            if kindLine == "multiple" {
                let roots = Array(lines.dropFirst()).sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
                return roots.isEmpty ? .notGitRepository(isRemote: true) : .multipleGitRepos(roots: roots, isRemote: true)
            }
            if kindLine == "none" {
                return .notGitRepository(isRemote: true)
            }
            return .unknown(isRemote: true)
        }
        return await task.value
    }

    private static func remoteWorkspaceLayoutCommand(path: String) -> String {
        """
        cd -- \(SSHRemote.shellPath(path)) && \
        if root=$(git rev-parse --show-toplevel 2>/dev/null); then
          printf 'single\\t%s\\n' "$root"
        elif command -v python3 >/dev/null 2>&1; then
          python3 - <<'PY'
        \(remoteGitLayoutScript)
        PY
        elif command -v python >/dev/null 2>&1; then
          python - <<'PY'
        \(remoteGitLayoutScript)
        PY
        else
          printf 'none\\n'
        fi
        """
    }

    private static let remoteGitLayoutScript = #"""
import os

skip = {
    "build", "DerivedData", "node_modules", "Pods", ".build",
    ".swiftpm", ".venv", "venv", "dist", "out",
}
root = os.path.realpath(os.getcwd())
found = []

def is_git_repo(path):
    return os.path.exists(os.path.join(path, ".git"))

def walk(path, depth):
    if depth > 2:
        return
    try:
        entries = list(os.scandir(path))
    except Exception:
        return
    for entry in entries:
        if not entry.is_dir(follow_symlinks=False) or entry.name in skip:
            continue
        child = entry.path
        if is_git_repo(child):
            found.append(os.path.realpath(child))
        else:
            walk(child, depth + 1)

walk(root, 0)
if found:
    print("multiple")
    for item in sorted(set(found), key=str.lower):
        print(item)
else:
    print("none")
"""#

    private static func enclosingGitRoot(for path: String) -> String? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        let fileManager = FileManager.default
        while true {
            if isGitRepository(at: url.path, fileManager: fileManager) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    private static func nestedGitRepositories(under path: String,
                                              maxDepth: Int = 2) -> [String] {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let fileManager = FileManager.default
        var results: [String] = []

        func walk(_ url: URL, depth: Int) {
            guard depth <= maxDepth,
                  let children = try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                  )
            else { return }

            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      !shouldSkipGitLayoutScanDirectory(child.lastPathComponent)
                else { continue }
                if isGitRepository(at: child.path, fileManager: fileManager) {
                    results.append(child.path)
                } else {
                    walk(child, depth: depth + 1)
                }
            }
        }

        walk(root, depth: 0)
        return results.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private static func isGitRepository(at path: String,
                                        fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    private static func shouldSkipGitLayoutScanDirectory(_ name: String) -> Bool {
        let skipped: Set<String> = [
            "build", "DerivedData", "node_modules", "Pods", ".build",
            ".swiftpm", ".venv", "venv", "dist", "out"
        ]
        return skipped.contains(name)
    }

    private func worktreeHint(for title: String,
                              layout: ProjectSchedulerWorkspaceLayout) -> String? {
        guard let root = layout.singleGitRoot else { return nil }
        let slug = title
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
        let compactSlug = String(slug).split(separator: "-").prefix(5).joined(separator: "-")
        guard !compactSlug.isEmpty else { return nil }
        let parent = (root as NSString).deletingLastPathComponent
        let projectName = (root as NSString).lastPathComponent
        return "\(parent)/\(projectName)-worktrees/\(compactSlug)"
    }

    private static func workflowRun(for task: ProjectSchedulerTask,
                                    sessionId: UUID,
                                    createdAt now: Date) -> ProjectWorkflowRun {
        ProjectWorkflowRun(
            taskId: task.id,
            sessionId: sessionId,
            title: "\(task.title) workflow",
            templateName: "Project Inbox native-subagent workflow",
            nodes: workflowNodes(for: task, createdAt: now),
            createdAt: now,
            updatedAt: now
        )
    }

    private static func workflowNodes(for task: ProjectSchedulerTask,
                                      createdAt now: Date) -> [ProjectWorkflowNodeRun] {
        let prePrompt = task.worktreeHint.map {
            "Fetch origin/main and create or reuse a task-scoped worktree at \($0). Work only inside that worktree unless you explain why that is impossible."
        } ?? "Prepare an isolated workspace for this task. If this is a Git repository with origin/main, create a task-scoped worktree from origin/main; otherwise document the safest available workspace."
        let processPrompt = task.idea.isEmpty
            ? "Implement the submitted Project Inbox task using the prepared workspace."
            : task.idea
        let validatePrompt = "Run project-appropriate build and validation. If this is the Helm macOS app, build a Debug app, launch only that app, record its PID and app/package path, and use Computer Use to validate the changed behavior."
        let cleanupPrompt = "Clean up only artifacts this workflow created: terminate recorded PIDs after verifying their command path, and remove only recorded debug packages or temporary bundles."
        let mergePrompt = "If validation passed and project policy allows direct merge, merge the task branch or worktree result back to origin/main, resolve conflicts, rerun required validation, commit, and push. If policy is unclear or conflicts cannot be resolved safely, stop and report the gate."

        let pre = ProjectWorkflowNodeRun(
            key: "pre_process.workspace",
            title: "Prepare workspace",
            kind: .preProcess,
            executor: .mainAgent,
            prompt: prePrompt,
            createdAt: now
        )
        let process = ProjectWorkflowNodeRun(
            key: "process.implementation",
            title: "Implement task",
            kind: .process,
            executor: .nativeSubagent,
            prompt: processPrompt,
            dependencies: [pre.id],
            createdAt: now
        )
        let validate = ProjectWorkflowNodeRun(
            key: "post_process.validate",
            title: "Build and verify",
            kind: .postProcess,
            executor: .nativeSubagent,
            prompt: validatePrompt,
            dependencies: [process.id],
            createdAt: now
        )
        let cleanup = ProjectWorkflowNodeRun(
            key: "post_process.cleanup",
            title: "Cleanup artifacts",
            kind: .cleanup,
            executor: .mainAgent,
            prompt: cleanupPrompt,
            dependencies: [validate.id],
            createdAt: now
        )
        let merge = ProjectWorkflowNodeRun(
            key: "post_process.merge",
            title: "Merge and push",
            kind: .gate,
            executor: .nativeSubagent,
            prompt: mergePrompt,
            dependencies: [cleanup.id],
            createdAt: now
        )
        return [pre, process, validate, cleanup, merge]
    }

    private static func workerPrompt(for task: ProjectSchedulerTask,
                                     workflow: ProjectWorkflowRun?) -> String {
        var prompt = task.idea
        var coordination: [String] = []
        coordination.append("Run this as a single Project Inbox parent session. Do not ask Helm to create extra sidebar sessions or external threads for the workflow.")
        coordination.append("Use the provider's native subagent or workflow capability for independent nodes when it is available. Keep those child runs scoped inside this session and summarize their results back here. If native child agents are unavailable, run the workflow sequentially in the main agent and say so.")
        coordination.append("Other Project Inbox workers may be running in this project. Inspect the current workspace state before editing, preserve unrelated changes, and stop to report any conflict instead of overwriting another worker's work.")
        coordination.append(contentsOf: task.resourceNotes)
        if let worktreeHint = task.worktreeHint {
            coordination.append("For edits in this Git repository, create or reuse a task-scoped worktree such as \(worktreeHint); do not make broad edits directly in the shared project checkout.")
        }
        coordination.append("Track workflow artifacts explicitly in your final response: worktree path, debug app/package path, PIDs you started, validation evidence, cleanup actions, git base/head, commit hash, and push result when available.")
        coordination.append("End with a concise workflow recap: node outcomes, what changed, validation evidence, cleanup status, and whether anything remains blocked or conflicted.")
        if let workflow {
            coordination.append("Workflow id: \(workflow.id.uuidString.lowercased()). Template: \(workflow.templateName).")
            coordination.append("Workflow nodes:\n\(workflow.nodes.map(Self.workflowNodeLine).joined(separator: "\n"))")
        }
        if !coordination.isEmpty {
            prompt += "\n\nProject Inbox coordination:\n"
            prompt += coordination.map { "- \($0)" }.joined(separator: "\n")
        }
        return prompt
    }

    private static func workflowNodeLine(_ node: ProjectWorkflowNodeRun) -> String {
        "  - \(node.key) [\(node.kind.displayName), preferred executor: \(node.executor.displayName)]: \(node.prompt)"
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
        _ = importTargetSessionIndex(TargetSessionIndexStore.loadLocal(),
                                     for: project)
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
        sshProfileAccess.append(SSHProfileAccessState(projectId: project.id))
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
        if status.isConnected {
            let imported = await importRemoteTargetSessionIndex(for: projects[latestIdx])
            if imported {
                scheduleStateSave()
            } else {
                scheduleTargetSessionIndexSave()
            }
            await refreshSchedulerWorkspaceLayout(projectId: projectId)
        }
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
                               runConfiguration: SessionRunConfiguration? = nil,
                               id: UUID = UUID()) -> UUID? {
        guard projects.contains(where: { $0.id == projectId }) else { return nil }
        let projectProfiles = availableProfiles(for: projectId)
        let pickedProfile: Profile? = {
            if let id = profileId,
               let p = projectProfiles.first(where: { $0.id == id }) { return p }
            if let v = vendor,
               let p = projectProfiles.first(where: { $0.vendor == v }) { return p }
            return projectProfiles.first { $0.vendor == .claude } ?? projectProfiles.first
        }()
        guard let profile = pickedProfile else { return nil }
        // Session runtime knobs are stored on the session so Project Inbox can
        // create a real worker with the same per-send choices as the composer.
        let resolvedRunConfiguration = runConfiguration ?? .defaults(for: profile)
        var session = Session(
            id: id,
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
        guard isProfileAvailable(profile.id, for: sessions[idx].projectId) else { return }
        let currentVendor = self.profile(sessions[idx].profileId)?.vendor
        let canCrossVendor = sessions[idx].isDraft
        guard sessions[idx].profileId == profile.id ||
              currentVendor == profile.vendor ||
              canCrossVendor
        else { return }
        sessions[idx].profileId = profile.id
        if profile.vendor == .codex {
            sessions[idx].codexSandboxMode = profile.sandboxMode ?? .workspace
            sessions[idx].codexApprovalMode = profile.approvalMode ?? .onRequest
            sessions[idx].codexEffort = profile.reasoningEffort ?? .medium
        }
        if profile.vendor == .claude {
            sessions[idx].claudePermissionMode = profile.claudePermissionMode ?? .defaultMode
            sessions[idx].claudeEffort = profile.claudeEffort ?? .medium
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
        guard !snapshot.isEmpty else {
            if !rawSnapshot.isEmpty {
                TranscriptSnapshotStore.delete(sessionId: sessionId)
            }
            return false
        }

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

    @discardableResult
    func send(_ prompt: String,
              displayParts: [Part]? = nil,
              attachments: [ImageAttachment] = [],
              agentPrompt: String? = nil,
              preUserEvents: [SessionEvent] = [],
              sessionId targetSessionId: UUID? = nil) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptForAgent = (agentPrompt ?? prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptForAgent.isEmpty || !attachments.isEmpty else { return false }
        let targetSessionId = targetSessionId ?? selectedSessionId
        guard let sIdx = sessions.firstIndex(where: { $0.id == targetSessionId }) else { return false }
        if isSessionStreaming(sessions[sIdx].id) {
            return appendToActiveRun(prompt: promptForAgent,
                                     displayParts: displayParts,
                                     fallbackDisplayText: trimmed,
                                     attachments: attachments,
                                     preUserEvents: preUserEvents,
                                     sessionIndex: sIdx)
        }
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
            appendError(to: sIdx, "Session has no project (id=\(sessions[sIdx].projectId))."); return false
        }
        guard let profile = profile(sessions[sIdx].profileId) else {
            appendError(to: sIdx, "Session's profile is missing — open Profiles and bind one."); return false
        }
        guard isProfileAvailable(profile.id, for: project.id) else {
            appendError(to: sIdx, "This profile is not enabled for this SSH connection. Open Profiles and enable it under the SSH project's settings.")
            return false
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
            return false
        }

        let userParts = makeUserParts(displayParts: displayParts,
                                      fallbackText: trimmed,
                                      attachments: attachments)
        let userMsg = Message(
            id: UUID(), role: .user, who: "you", meta: nil,
            parts: userParts
        )
        let startedAt = Date()
        let assistantMsg = Message(
            id: UUID(),
            role: .assistant(meta: "thinking…"),
            who: runConfig.headlineModel,
            meta: "thinking…",
            parts: [],
            startedAt: startedAt
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
        appendImageManifestEntries(sessionIndex: sIdx,
                                   userMessageId: userMsg.id,
                                   attachments: attachments)

        let runId = UUID()
        let adapter: AgentAdapter
        switch profile.vendor {
        case .claude: adapter = ClaudeLocalAdapter()
        case .codex: adapter = codexAdapter(project: project, runConfig: runConfig)
        }
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
        return true
    }

    private func appendToActiveRun(prompt: String,
                                   displayParts: [Part]?,
                                   fallbackDisplayText: String,
                                   attachments: [ImageAttachment],
                                   preUserEvents: [SessionEvent],
                                   sessionIndex sIdx: Int) -> Bool {
        let sessionId = sessions[sIdx].id
        guard let run = activeRuns[sessionId] else { return false }
        guard run.adapter.supportsPromptAppend else {
            appendError(to: sIdx, "This agent cannot accept more input while a response is running.")
            return false
        }

        do {
            try run.adapter.append(prompt: prompt, attachments: attachments)
        } catch {
            appendError(to: sIdx, error.localizedDescription)
            return false
        }

        let userMsg = Message(
            id: UUID(),
            role: .user,
            who: "you",
            meta: nil,
            parts: makeUserParts(displayParts: displayParts,
                                 fallbackText: fallbackDisplayText,
                                 attachments: attachments)
        )
        let insertionIndex = sessions[sIdx].transcript.firstIndex {
            $0.message?.id == run.assistantId
        } ?? sessions[sIdx].transcript.count
        let insertedItems = preUserEvents.map(TranscriptItem.event)
            + [.event(.promptAppended(id: UUID(), appendedAt: Date()))]
            + [.message(userMsg)]
        sessions[sIdx].transcript.insert(contentsOf: insertedItems, at: insertionIndex)
        sessions[sIdx].lastUpdate = "now"
        upsertSidebarSession(for: sessions[sIdx])
        appendImageManifestEntries(sessionIndex: sIdx,
                                   userMessageId: userMsg.id,
                                   attachments: attachments)
        appendTick &+= 1
        persistTranscriptSnapshot(for: sessionId)
        return true
    }

    private func makeUserParts(displayParts: [Part]?,
                               fallbackText: String,
                               attachments: [ImageAttachment]) -> [Part] {
        var userParts: [Part] = displayParts ?? []
        if userParts.isEmpty, !fallbackText.isEmpty {
            userParts.append(.text(fallbackText))
        }
        for attachment in attachments {
            userParts.append(.image(attachment.fileURL))
        }
        return userParts
    }

    private func appendImageManifestEntries(sessionIndex sIdx: Int,
                                            userMessageId: UUID,
                                            attachments: [ImageAttachment]) {
        guard !attachments.isEmpty,
              let userOrdinal = userMessageOrdinal(sessionIndex: sIdx,
                                                   userMessageId: userMessageId)
        else { return }

        ImageManifestStore.append(sessionId: sessions[sIdx].id,
                                  userMessageOrdinal: userOrdinal,
                                  filenames: attachments.map { $0.fileURL.lastPathComponent })
    }

    private func userMessageOrdinal(sessionIndex sIdx: Int,
                                    userMessageId: UUID) -> Int? {
        var ordinal = 0
        for item in sessions[sIdx].transcript {
            guard let message = item.message,
                  case .user = message.role
            else { continue }
            if message.id == userMessageId {
                return ordinal
            }
            ordinal += 1
        }
        return nil
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
        activeRuns[sessionId] = nil
        runningSessionIds.remove(sessionId)
        activeRunStartedAts[sessionId] = nil
        pendingApprovalQueue.removeAll { $0.sessionId == sessionId }
        markManagedSessionFinished(sessionId)
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

        case .childRunStatus(let status):
            recordWorkflowChildRunStatus(status, sessionId: sessionId)

        case .messageStop:
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                if msg.meta == "streaming…" || msg.meta == "thinking…" {
                    msg.meta = nil
                }
            }

        case .finalResult(let text, let isError):
            var followupAnswer: Message?
            let runToClose = activeRuns[sessionId]
            let endedAt = Date()
            mutateAssistant(at: sIdx, id: assistantId) { msg in
                msg.role = .assistant(meta: isError ? "error" : "done")
                msg.meta = isError ? "error" : nil
                if msg.endedAt == nil {
                    msg.endedAt = endedAt
                }
                if msg.tokenUsage == nil {
                    msg.tokenUsage = estimateTokens(in: msg.parts)
                }
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
                if msg.endedAt == nil {
                    msg.endedAt = Date()
                }
                if msg.tokenUsage == nil {
                    msg.tokenUsage = estimateTokens(in: msg.parts)
                }
                msg.parts.append(.text("⚠️ " + detail))
            }
        }
    }

    private func recordWorkflowChildRunStatus(_ status: AgentChildRunStatus,
                                              sessionId: UUID) {
        guard let location = managedTaskLocation(for: sessionId) else { return }
        let task = projectSchedulers[location.schedulerIndex].tasks[location.taskIndex]
        guard let runIndex = projectSchedulers[location.schedulerIndex].workflowRuns.firstIndex(where: {
            $0.taskId == task.id
        }) else { return }
        let detail = [
            status.title,
            "id=\(status.id)",
            status.parentId.map { "parent=\($0)" },
            status.detail
        ].compactMap { $0 }.joined(separator: "\n")
        projectSchedulers[location.schedulerIndex].workflowRuns[runIndex].artifacts.append(
            ProjectWorkflowArtifact(kind: .note,
                                    label: "Child run \(status.state.rawValue)",
                                    value: detail)
        )
        projectSchedulers[location.schedulerIndex].workflowRuns[runIndex].updatedAt = Date()
        projectSchedulers[location.schedulerIndex].updatedAt = Date()
        scheduleStateSave()
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
        if msg.endedAt == nil {
            msg.endedAt = Date()
        }
        if msg.tokenUsage == nil {
            msg.tokenUsage = estimateTokens(in: msg.parts)
        }
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
