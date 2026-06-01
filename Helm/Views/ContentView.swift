import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < DS.sidebarAutoHideWidth

            HStack(spacing: 0) {
                sidebarContainer(isCompact: isCompact)
                mainSurface(isFloating: !isCompact)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color.helmSidebarBg)
            .animation(Self.sidebarAnimation, value: sidebarVisible)
            .animation(Self.sidebarAnimation, value: isCompact)
            .overlay {
                if let previewURL = store.imagePreviewURL {
                    ImagePreviewOverlay(url: previewURL) {
                        store.imagePreviewURL = nil
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    .zIndex(20)
                }
            }
            .overlay {
                if store.showQuickSwitcher {
                    QuickSwitcherView()
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                        .zIndex(30)
                }
            }
            .overlay {
                if let approval = store.pendingApproval {
                    ApprovalRequestOverlay(request: approval) { decision in
                        store.respondToApproval(decision)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    .zIndex(40)
                }
            }
            .animation(.easeOut(duration: 0.14), value: store.imagePreviewURL)
            .animation(.easeOut(duration: 0.12), value: store.showQuickSwitcher)
            .animation(.easeOut(duration: 0.12), value: store.pendingApprovalKey)
            .onAppear {
                HelmCommandCenter.shared.bind(store: store)
            }
        }
    }

    private func sidebarContainer(isCompact: Bool) -> some View {
        ZStack(alignment: .leading) {
            if !isCompact {
                if sidebarVisible {
                    SidebarView {
                        setSidebarVisible(false)
                    }
                    .frame(width: DS.sidebarWidth)
                    .transition(Self.sidebarTransition)
                } else {
                    CollapsedSidebarRail {
                        setSidebarVisible(true)
                    } onOpenSettings: {
                        store.showProfilesSheet = true
                    }
                    .transition(Self.sidebarTransition)
                }
            }
        }
        .frame(width: sidebarWidth(isCompact: isCompact), alignment: .leading)
        .frame(maxHeight: .infinity)
        .clipped()
        .opacity(isCompact ? 0 : 1)
    }

    private func mainSurface(isFloating: Bool) -> some View {
        detailPane
            .clipShape(RoundedRectangle(cornerRadius: isFloating ? DS.cornerRadiusLarge : 0,
                                        style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: isFloating ? DS.cornerRadiusLarge : 0,
                                 style: .continuous)
                    .stroke(Color.helmBorder, lineWidth: 1)
                    .opacity(isFloating ? 1 : 0)
            )
            .shadow(color: Color.black.opacity(isFloating ? 0.06 : 0),
                    radius: isFloating ? 12 : 0,
                    x: 0,
                    y: isFloating ? 4 : 0)
            .padding(.leading, isFloating ? 6 : 0)
            .padding(.trailing, isFloating ? 8 : 0)
            .padding(.vertical, isFloating ? 8 : 0)
            .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var detailPane: some View {
        Group {
            if store.selectedSession != nil {
                ChatView()
            } else if let project = store.selectedProject {
                ProjectSchedulerView(project: project)
            } else {
                EmptyChatView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.helmChatBg)
    }

    private func sidebarWidth(isCompact: Bool) -> CGFloat {
        if isCompact { return 0 }
        return sidebarVisible ? DS.sidebarWidth : DS.sidebarCollapsedRailWidth
    }

    private func setSidebarVisible(_ visible: Bool) {
        withAnimation(Self.sidebarAnimation) {
            sidebarVisible = visible
        }
    }

    private static let sidebarAnimation = Animation.interactiveSpring(
        response: 0.26,
        dampingFraction: 0.9,
        blendDuration: 0.04
    )

    private static let sidebarTransition = AnyTransition
        .asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
}

private struct ApprovalRequestOverlay: View {
    let request: AgentApprovalRequest
    let respond: (AgentApprovalDecision) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.14)
                .ignoresSafeArea()

            panel
        }
        .onExitCommand {
            respond(.cancel)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(request.message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if let detail = request.detail, !detail.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(detail)
                        .font(DS.monoFontSmall)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(10)
                .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            HStack(spacing: 8) {
                Button {
                    respond(.cancel)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    respond(.decline)
                } label: {
                    Label("Deny", systemImage: "hand.raised")
                }

                Spacer(minLength: 12)

                if request.allowsSessionApproval {
                    Button {
                        respond(.acceptForSession)
                    } label: {
                        Label("Session", systemImage: "checkmark.seal")
                    }
                }

                Button {
                    respond(.accept)
                } label: {
                    Label("Approve", systemImage: "checkmark")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(18)
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.cornerRadiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cornerRadiusLarge, style: .continuous)
                .stroke(Color.helmBorderStrong, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: 12)
        .padding(.horizontal, 28)
    }

    private var iconName: String {
        switch request.kind {
        case .command: return "terminal"
        case .fileChange: return "doc.text"
        case .mcpElicitation: return "app.connected.to.app.below.fill"
        case .permissions: return "lock.shield"
        case .userInput: return "questionmark.bubble"
        case .other: return "checkmark.shield"
        }
    }
}

private struct ProjectSchedulerView: View {
    @Environment(AppStore.self) private var store
    let project: Project

    @State private var ideaText = ""
    @State private var composerFocusRequest = 0
    @State private var looseSessionsExpanded = false
    @State private var completedExpanded = false
    @State private var showWorkflowSettings = false

    private let phaseColumns: [ProjectSchedulerTaskPhase] = [.running, .waiting]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    schedulerBoard
                    looseSessions
                    completedWork
                    inboxHistory
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            Divider()
            ProjectSchedulerComposer(project: project,
                                     text: $ideaText,
                                     focusRequest: composerFocusRequest,
                                     onSubmit: submitIdea)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .background(Color.helmChatBg)
        .onAppear {
            composerFocusRequest &+= 1
        }
        .onChange(of: project.id) { _, _ in
            ideaText = ""
            composerFocusRequest &+= 1
        }
        .sheet(isPresented: $showWorkflowSettings) {
            ProjectWorkflowSettingsSheet(project: project)
        }
    }

    private var state: ProjectSchedulerState {
        store.schedulerState(for: project.id)
    }

    private var tasks: [ProjectSchedulerTask] {
        store.schedulerTasks(in: project.id)
    }

    private var activeTasks: [ProjectSchedulerTask] {
        tasks.filter { effectivePhase($0) != .done }
    }

    private var completedTasks: [ProjectSchedulerTask] {
        tasks.filter { effectivePhase($0) == .done }
    }

    private var unmanagedSessions: [Session] {
        store.unmanagedProjectSessions(in: project.id)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text(project.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .lineLimit(1)
                    Text("Project Inbox")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(Color.helmHover, in: RoundedRectangle(cornerRadius: DS.cornerRadiusSmall))
                }
                Text(displayPath(for: project))
                    .font(DS.monoFontSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(displayPath(for: project))
            }

            Spacer(minLength: 0)

            workflowSelectionMenu

            Button {
                showWorkflowSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Manage Project Inbox workflows")

            metric("\(tasks.filter { effectivePhase($0) == .running }.count)", "Running")
            metric("\(activeTasks.filter { effectivePhase($0) == .waiting }.count)", "Waiting")
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 54, alignment: .trailing)
    }

    private var schedulerBoard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Work Queue", count: activeTasks.count)
            if activeTasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tasks.isEmpty ? "Inbox is empty" : "No active scheduler tasks")
                        .font(.system(size: 13, weight: .semibold))
                    Text(tasks.isEmpty
                         ? "Drop an idea below. Helm will start workers as soon as the basic project requirements are ready."
                         : "Completed work is tucked below; new or imported sessions will appear here when they are running or waiting.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(boardBackground)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(phaseColumns) { phase in
                        ProjectSchedulerPhaseColumn(
                            phase: phase,
                            tasks: activeTasks.filter { effectivePhase($0) == phase },
                            workflow: workflowSnapshot,
                            canStart: { task in
                                canStartTasks && store.canStartSchedulerTask(task.id, projectId: project.id)
                            },
                            onStart: { task in
                                store.startSchedulerTask(task.id, projectId: project.id)
                            },
                            onOpen: { task in
                                store.openSchedulerTaskSession(task.id, projectId: project.id)
                            },
                            onDone: { task in
                                store.markSchedulerTask(task.id,
                                                        projectId: project.id,
                                                        phase: .done)
                            }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var looseSessions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProjectSchedulerDisclosureHeader(title: "Loose Sessions",
                                             count: unmanagedSessions.count,
                                             isExpanded: looseSessionsExpanded) {
                withAnimation(.easeOut(duration: 0.12)) {
                    looseSessionsExpanded.toggle()
                }
            }
            if looseSessionsExpanded {
                if unmanagedSessions.isEmpty {
                    Text("All non-draft sessions in this project are already tracked by the scheduler.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 6) {
                        ForEach(unmanagedSessions) { session in
                            ProjectSchedulerSessionRecapRow(
                                session: session,
                                headline: store.sessionHeadline(session),
                                isRunning: store.isSessionStreaming(session.id),
                                onOpen: { store.selectedSessionId = session.id },
                                onTrack: {
                                    _ = store.adoptSessionIntoScheduler(session.id, projectId: project.id)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var completedWork: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProjectSchedulerDisclosureHeader(title: "Completed",
                                             count: completedTasks.count,
                                             isExpanded: completedExpanded) {
                withAnimation(.easeOut(duration: 0.12)) {
                    completedExpanded.toggle()
                }
            }
            if completedExpanded {
                if completedTasks.isEmpty {
                    Text("Completed scheduler tasks will collect here with their session recaps.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 6) {
                        ForEach(completedTasks) { task in
                            ProjectSchedulerCompletedTaskRow(
                                task: task,
                                headline: task.sessionId
                                    .flatMap { store.session($0) }
                                    .map { store.sessionHeadline($0) },
                                onOpen: {
                                    store.openSchedulerTaskSession(task.id, projectId: project.id)
                                }
                            )
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder
    private var inboxHistory: some View {
        let inbox = state.inbox.prefix(6)
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Recent Inbox", count: state.inbox.count)
            if inbox.isEmpty {
                Text("New project ideas will appear here after submission.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(inbox)) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .frame(width: 16)
                            Text(item.text)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(Self.relative(item.createdAt))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(Color.helmHover.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.cornerRadiusSmall))
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var canStartTasks: Bool {
        guard store.defaultWorkerProfile(for: project.id) != nil else { return false }
        if case .ssh(_, _, let status) = project.location {
            return status.isConnected
        }
        return true
    }

    private var boardBackground: some View {
        RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
            .fill(Color.helmCard)
            .overlay(
                RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                    .stroke(Color.helmBorder, lineWidth: 1)
            )
    }

    private func effectivePhase(_ task: ProjectSchedulerTask) -> ProjectSchedulerTaskPhase {
        if let sessionId = task.sessionId,
           store.isSessionStreaming(sessionId) {
            return .running
        }
        if task.phase == .done {
            return .done
        }
        return .waiting
    }

    private func submitIdea(prompt: String,
                            displayParts: [Part],
                            attachments: [ImageAttachment],
                            workerProfileId: UUID,
                            runConfiguration: SessionRunConfiguration) -> Bool {
        guard store.submitProjectIdea(prompt,
                                      displayParts: displayParts,
                                      attachments: attachments,
                                      projectId: project.id,
                                      workerProfileId: workerProfileId,
                                      workflowTemplateId: store.selectedWorkflowTemplateId(for: project.id),
                                      runConfiguration: runConfiguration) != nil else {
            store.showProfilesSheet = true
            return false
        }
        ideaText = ""
        composerFocusRequest &+= 1
        return true
    }

    private func displayPath(for project: Project) -> String {
        switch project.location {
        case .local(let path):
            return path
        case .ssh(let host, let path, let status):
            let resolved = status.resolvedPath?.isEmpty == false
                ? status.resolvedPath!
                : path
            return "\(host):\(resolved)"
        }
    }

    private var workflowSelectionMenu: some View {
        Menu {
            Button {
                store.setSelectedWorkflowTemplate(nil, projectId: project.id)
            } label: {
                workflowSelectionLabel("No workflow",
                                       selected: store.selectedWorkflowTemplateId(for: project.id) == nil)
            }

            let templates = store.workflowTemplates(for: project.id)
            if !templates.isEmpty {
                Divider()
                ForEach(templates) { template in
                    Button {
                        store.setSelectedWorkflowTemplate(template.id, projectId: project.id)
                    } label: {
                        workflowSelectionLabel(template.name,
                                               selected: store.selectedWorkflowTemplateId(for: project.id) == template.id)
                    }
                }
            }

            Divider()
            Button {
                showWorkflowSettings = true
            } label: {
                Label("Manage workflows...", systemImage: "slider.horizontal.3")
            }
        } label: {
            Label(workflowSelectionTitle, systemImage: "point.3.connected.trianglepath.dotted")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the workflow for new Project Inbox tasks")
    }

    private var workflowSelectionTitle: String {
        store.selectedWorkflowTemplate(for: project.id)?.name ?? "No workflow"
    }

    @ViewBuilder
    private func workflowSelectionLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func workflowSnapshot(for task: ProjectSchedulerTask) -> ProjectWorkflowStatusSnapshot? {
        guard let run = store.workflowRun(forTask: task.id, projectId: project.id) else { return nil }
        return ProjectWorkflowStatusSnapshot(run: run)
    }

    fileprivate static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct ProjectWorkflowSettingsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let project: Project

    @State private var templates: [ProjectWorkflowTemplate] = [.default]
    @State private var selectedTemplateId: UUID?
    @State private var editingTemplateId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                workflowList
                Divider()
                editorPane
            }
            Divider()
            footer
        }
        .frame(width: 780, height: 640)
        .background(Color.helmChatBg)
        .onAppear {
            templates = store.workflowTemplates(for: project.id)
            selectedTemplateId = store.selectedWorkflowTemplateId(for: project.id)
            editingTemplateId = selectedTemplateId
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Workflows")
                    .font(.system(size: 16, weight: .semibold))
                Text(project.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var workflowList: some View {
        VStack(alignment: .leading, spacing: 8) {
            workflowRow(title: "No workflow",
                        subtitle: "Send the task directly",
                        isSelected: selectedTemplateId == nil,
                        isEditing: editingTemplateId == nil) {
                selectedTemplateId = nil
                editingTemplateId = nil
            }

            Divider()
                .padding(.vertical, 2)

            ForEach(templates) { template in
                workflowRow(title: template.name,
                            subtitle: "Template",
                            isSelected: selectedTemplateId == template.id,
                            isEditing: editingTemplateId == template.id) {
                    selectedTemplateId = template.id
                    editingTemplateId = template.id
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button {
                    addTemplate()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Add workflow")

                Button {
                    duplicateTemplate()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(editingTemplateId == nil)
                .help("Duplicate workflow")

                Button {
                    deleteTemplate()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(editingTemplateId == nil || templates.count <= 1)
                .help("Delete workflow")
            }
        }
        .padding(12)
        .frame(width: 230)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.helmSidebarBg)
    }

    private func workflowRow(title: String,
                             subtitle: String,
                             isSelected: Bool,
                             isEditing: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.65))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.isEmpty ? "Untitled workflow" : title)
                        .font(.system(size: 12.5, weight: isEditing ? .semibold : .regular))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                    .fill(isEditing ? Color.helmSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var editorPane: some View {
        if let editingTemplateId,
           templates.contains(where: { $0.id == editingTemplateId }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Template", text: templateBinding(for: editingTemplateId).name)
                    promptEditor("Pre-process",
                                 text: templateBinding(for: editingTemplateId).preProcessPrompt,
                                 height: 150)
                    promptEditor("Post-process",
                                 text: templateBinding(for: editingTemplateId).postProcessPrompt,
                                 height: 230)
                }
                .padding(18)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("No workflow")
                    .font(.system(size: 14, weight: .semibold))
                Text("New Project Inbox tasks will be sent as normal worker sessions without workflow nodes or workflow skill invocation.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Reset") {
                templates = [.default]
                selectedTemplateId = ProjectWorkflowTemplate.defaultID
                editingTemplateId = ProjectWorkflowTemplate.defaultID
            }
            .help("Reset to the sample workflow")
            .controlSize(.small)
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .controlSize(.small)
            Button("Save") {
                store.updateWorkflowTemplates(templates,
                                              selectedTemplateId: selectedTemplateId,
                                              projectId: project.id)
                dismiss()
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func field(_ label: String,
                       text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    private func promptEditor(_ label: String,
                              text: Binding<String>,
                              height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            HelmPlainTextEditor(text: text)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall, style: .continuous)
                        .fill(Color.helmCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall, style: .continuous)
                                .stroke(Color.helmBorder, lineWidth: 1)
                        )
                )
        }
    }

    private func templateBinding(for id: UUID) -> Binding<ProjectWorkflowTemplate> {
        Binding(
            get: {
                templates.first { $0.id == id } ?? ProjectWorkflowTemplate.default
            },
            set: { updated in
                guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
                templates[index] = updated
            }
        )
    }

    private func addTemplate() {
        let template = ProjectWorkflowTemplate(
            name: "New workflow",
            preProcessPrompt: "",
            postProcessPrompt: ""
        )
        templates.append(template)
        selectedTemplateId = template.id
        editingTemplateId = template.id
    }

    private func duplicateTemplate() {
        guard let id = editingTemplateId,
              let template = templates.first(where: { $0.id == id }) else { return }
        var copy = template
        copy.id = UUID()
        copy.name = "\(template.name) Copy"
        templates.append(copy)
        selectedTemplateId = copy.id
        editingTemplateId = copy.id
    }

    private func deleteTemplate() {
        guard let id = editingTemplateId,
              templates.count > 1 else { return }
        templates.removeAll { $0.id == id }
        if selectedTemplateId == id {
            selectedTemplateId = nil
        }
        editingTemplateId = selectedTemplateId ?? templates.first?.id
    }
}

private struct ProjectSchedulerPhaseColumn: View {
    let phase: ProjectSchedulerTaskPhase
    let tasks: [ProjectSchedulerTask]
    var workflow: (ProjectSchedulerTask) -> ProjectWorkflowStatusSnapshot?
    var canStart: (ProjectSchedulerTask) -> Bool
    var onStart: (ProjectSchedulerTask) -> Void
    var onOpen: (ProjectSchedulerTask) -> Void
    var onDone: (ProjectSchedulerTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: phase.symbolName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(phase.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(tasks.count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(height: 22)

            if tasks.isEmpty {
                RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                    .fill(Color.helmHover.opacity(0.45))
                    .frame(height: 56)
                    .overlay {
                        Text("Empty")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
            } else {
                VStack(spacing: 7) {
                    ForEach(tasks) { task in
                        ProjectSchedulerTaskCard(
                            task: task,
                            displayPhase: phase,
                            workflow: workflow(task),
                            canStart: canStart(task),
                            onStart: { onStart(task) },
                            onOpen: { onOpen(task) },
                            onDone: { onDone(task) }
                        )
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(Color.helmCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                        .stroke(Color.helmBorder, lineWidth: 1)
                )
        )
    }
}

private struct ProjectWorkflowStatusSnapshot: Identifiable, Equatable {
    let id: UUID
    let templateName: String
    let status: ProjectWorkflowRunStatus
    let nodes: [ProjectWorkflowNodeRun]

    init(run: ProjectWorkflowRun) {
        self.id = run.id
        self.templateName = run.templateName
        self.status = run.status
        self.nodes = run.nodes
    }
}

private struct ProjectSchedulerTaskCard: View {
    let task: ProjectSchedulerTask
    let displayPhase: ProjectSchedulerTaskPhase
    let workflow: ProjectWorkflowStatusSnapshot?
    let canStart: Bool
    var onStart: () -> Void
    var onOpen: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(task.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(task.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let workflow {
                ProjectWorkflowStatusStrip(workflow: workflow)
            }
            if let worktreeHint = task.worktreeHint {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text((worktreeHint as NSString).lastPathComponent)
                        .font(DS.monoFontSmall)
                        .lineLimit(1)
                }
                .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                if task.sessionId != nil {
                    Button {
                        onOpen()
                    } label: {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Open session")
                }
                Spacer(minLength: 0)
                actionButtons
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(Color.helmChatBg)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                        .stroke(Color.helmBorder, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch displayPhase {
        case .planned, .waiting, .needsReview, .readyToMerge:
            if task.phase == .planned {
                Button {
                    onStart()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .opacity(canStart ? 1 : 0.45)
                .help(canStart ? "Start worker session" : "Cannot start yet")
            } else {
                Button {
                    onDone()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Mark done")
            }
        case .running:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.72)
                .frame(width: 22, height: 22)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
                .frame(width: 22, height: 22)
        }
    }
}

private struct ProjectWorkflowStatusStrip: View {
    let workflow: ProjectWorkflowStatusSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: statusIcon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 12)
                Text(workflow.status.displayName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(completedCount)/\(workflow.nodes.count)")
                    .font(DS.monoFontSmall)
                    .foregroundStyle(.tertiary)
            }
            .help(workflow.templateName)

            HStack(spacing: 4) {
                ForEach(workflow.nodes.prefix(5)) { node in
                    ProjectWorkflowNodePill(node: node)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var completedCount: Int {
        workflow.nodes.filter { $0.status == .passed || $0.status == .skipped }.count
    }

    private var statusIcon: String {
        switch workflow.status {
        case .planned: return "circle"
        case .running: return "play.circle"
        case .waiting: return "hourglass"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle"
        }
    }

    private var statusColor: Color {
        switch workflow.status {
        case .planned: return .secondary
        case .running: return .accentColor
        case .waiting: return .orange
        case .passed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}

private struct ProjectWorkflowNodePill: View {
    let node: ProjectWorkflowNodeRun

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: node.kind.symbolName)
                .font(.system(size: 8, weight: .medium))
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
        }
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 18)
        .background(Color.helmHover.opacity(0.75), in: RoundedRectangle(cornerRadius: DS.cornerRadiusSmall))
        .help(helpText)
    }

    private var statusColor: Color {
        switch node.status {
        case .planned: return .secondary.opacity(0.45)
        case .running: return .accentColor
        case .waiting: return .orange
        case .passed: return .green
        case .failed: return .red
        case .skipped: return .secondary
        }
    }

    private var helpText: String {
        let maxPromptLength = 480
        let prompt = node.prompt.count > maxPromptLength
            ? String(node.prompt.prefix(maxPromptLength)) + "..."
            : node.prompt
        return "\(node.title) - \(node.status.displayName)\n\(prompt)"
    }
}

private struct ProjectSchedulerComposer: View {
    @Environment(AppStore.self) private var store
    @AppStorage(CodexComputerUseMode.userDefaultsKey) private var computerUseModeRawValue = CodexComputerUseMode.automatic.rawValue
    @AppStorage(MessageSendShortcut.userDefaultsKey) private var messageSendShortcutRawValue = MessageSendShortcut.defaultValue.rawValue
    @AppStorage(MessageSendShortcut.lineBreakUserDefaultsKey) private var messageLineBreakShortcutRawValue = MessageSendShortcut.defaultLineBreakValue.rawValue

    let project: Project
    @Binding var text: String
    let focusRequest: Int
    var onSubmit: (String, [Part], [ImageAttachment], UUID, SessionRunConfiguration) -> Bool

    @State private var skillChips: [ComposerSkill] = []
    @State private var attachments: [ImageAttachment] = []
    @State private var pickerOpen = false
    @State private var workerProfileId: UUID?
    @State private var runConfiguration = SessionRunConfiguration()
    @State private var localFocusRequest = 0
    @State private var composerInteractionResetRequest = 0
    @State private var pasteMonitor: Any? = nil
    @State private var attachmentStorageId = UUID()

    private var composedPrompt: String {
        ComposerPromptSerializer.serialize(text,
                                           skillChips: skillChips,
                                           vendor: selectedProfile?.vendor ?? .codex)
    }

    private var displayParts: [Part] {
        ComposerPromptSerializer.displayParts(text,
                                              skillChips: skillChips,
                                              fallbackText: composedPrompt)
    }

    private var hasComposerContent: Bool {
        !composedPrompt.isEmpty || !attachments.isEmpty
    }

    private var selectedProfile: Profile? {
        if let workerProfileId,
           store.isProfileAvailable(workerProfileId, for: project.id),
           let profile = store.profile(workerProfileId) {
            return profile
        }
        return store.defaultWorkerProfile(for: project.id)
    }

    private var selectedModelLabel: String {
        selectedProfile
            .flatMap { store.model($0.primaryModelId) }?
            .label ?? "no model"
    }

    private var messageSendShortcut: MessageSendShortcut {
        MessageSendShortcut.normalized(messageSendShortcutRawValue)
    }

    private var messageLineBreakShortcut: MessageSendShortcut {
        MessageSendShortcut.normalizedLineBreak(messageLineBreakShortcutRawValue,
                                                sendShortcut: messageSendShortcut)
    }

    private var canSubmit: Bool {
        hasComposerContent && selectedProfile != nil && sshSendBlockReason == nil
    }

    private var composerPlaceholder: String {
        if let reason = sshSendBlockReason {
            return reason
        }
        return "Drop an idea into this project inbox (⌘V to attach image · \(messageSendShortcut.glyph) to add)"
    }

    var body: some View {
        VStack(spacing: 6) {
            box
            footer
        }
        .frame(maxWidth: DS.messageMaxWidth)
        .onAppear {
            syncSelectedProfileIfNeeded(resetConfiguration: true)
            installPasteMonitor()
        }
        .onChange(of: project.id) { _, _ in
            workerProfileId = nil
            skillChips = []
            removeAllAttachments()
            attachmentStorageId = UUID()
            composerInteractionResetRequest &+= 1
            syncSelectedProfileIfNeeded(resetConfiguration: true)
        }
        .onChange(of: store.profiles.map(\.id)) { _, _ in
            syncSelectedProfileIfNeeded(resetConfiguration: false)
        }
        .onDisappear {
            removePasteMonitor()
            removeAllAttachments()
            attachmentStorageId = UUID()
        }
    }

    private var box: some View {
        SkillAwareComposerBox(
            text: $text,
            skillChips: $skillChips,
            placeholder: composerPlaceholder,
            minLines: 2,
            maxLines: 11,
            focusRequest: focusRequest &+ localFocusRequest,
            resetRequest: composerInteractionResetRequest,
            sendShortcut: messageSendShortcut,
            lineBreakShortcut: messageLineBreakShortcut,
            menuWidthSource: DS.messageMaxWidth,
            textTopPadding: attachments.isEmpty ? 8 : 6,
            skillProfile: selectedProfile,
            skillProject: project,
            onSlashActivityChange: { _ in },
            onSend: submitIfPossible,
            topContent: {
                if !attachments.isEmpty {
                    ComposerAttachmentRow(attachments: attachments,
                                          onRemove: removeAttachment)
                }
            },
            accessoryOverlay: { _ in
                EmptyView()
            }
        )
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            wideFooter
            compactFooter
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .padding(.top, 4)
    }

    private var wideFooter: some View {
        HStack(spacing: 8) {
            modelPickerButton(maxWidth: 260)
            runConfigControls
            sshStatusControl
            Spacer(minLength: 8)
            sendShortcut
            submitButton
        }
    }

    private var compactFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                modelPickerButton(maxWidth: .infinity)
                Spacer(minLength: 8)
                sendShortcut
                submitButton
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    runConfigControls
                    sshStatusControl
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func modelPickerButton(maxWidth: CGFloat) -> some View {
        Button { pickerOpen.toggle() } label: {
            HStack(spacing: 6) {
                if let selectedProfile {
                    VendorBadge(vendor: selectedProfile.vendor).frame(width: 14, height: 14)
                }
                Text(selectedModelLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
            ProjectIdeaProfilePickerMenu(
                projectId: project.id,
                selectedProfileId: selectedProfile?.id,
                onSelect: { profile in
                    workerProfileId = profile.id
                    runConfiguration = .defaults(for: profile)
                    store.setDefaultWorkerProfile(profile.id, for: project.id)
                    pickerOpen = false
                    refocusComposerAfterMenuSelection()
                }
            )
            .frame(width: 360)
        }
        .help("Choose worker provider/model for this idea")
    }

    @ViewBuilder
    private var runConfigControls: some View {
        if let selectedProfile {
            switch selectedProfile.vendor {
            case .claude:
                claudePermissionChip
                claudeEffortChip
                computerUseChip
            case .codex:
                codexSandboxChip
                codexApprovalChip
                codexEffortChip
                computerUseChip
            }
        }
    }

    @ViewBuilder
    private var sshStatusControl: some View {
        if case .ssh(_, _, let status) = project.location {
            HStack(spacing: 5) {
                if status.isConnecting {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                } else {
                    Circle()
                        .fill(status.color)
                        .frame(width: 6, height: 6)
                }
                Text(status.shortLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(status.isConnected ? Color.secondary : status.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                    .fill(Color.helmCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                            .stroke(Color.helmBorder, lineWidth: 1)
                    )
            )
            .help(status.helpText)
        }
    }

    private var sendShortcut: some View {
        Text(messageSendShortcut.glyph)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
    }

    private var submitButton: some View {
        Button {
            submitIfPossible()
        } label: {
            Text("Add")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(submitColor))
        }
        .buttonStyle(.plain)
        .messageSendKeyboardShortcut(messageSendShortcut)
        .disabled(!canSubmit)
        .help(submitHelp)
    }

    private var submitColor: Color {
        canSubmit ? .accentColor : .secondary.opacity(0.45)
    }

    private var submitHelp: String {
        if selectedProfile == nil { return "Create a profile before submitting ideas" }
        if let reason = sshSendBlockReason { return reason }
        return "Submit idea to project inbox"
    }

    private var sshSendBlockReason: String? {
        guard case .ssh(_, _, let status) = project.location,
              !status.isConnected
        else { return nil }
        switch status {
        case .connected:
            return nil
        case .connecting:
            return "SSH connection is still being checked"
        case .failed(let reason):
            return "SSH connection failed: \(reason)"
        }
    }

    private var claudePermissionChip: some View {
        Menu {
            ForEach(ClaudePermissionMode.allCases, id: \.self) { mode in
                Button {
                    runConfiguration.claudePermissionMode = mode
                    refocusComposerAfterMenuSelection()
                } label: {
                    menuSelectionLabel(mode.displayName,
                                       selected: mode == runConfiguration.claudePermissionMode)
                }
            }
        } label: {
            chipLabel(icon: "lock.shield", text: runConfiguration.claudePermissionMode.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Claude --permission-mode")
    }

    private var codexSandboxChip: some View {
        Menu {
            ForEach(Profile.SandboxMode.allCases, id: \.self) { mode in
                Button {
                    runConfiguration.codexSandboxMode = mode
                    refocusComposerAfterMenuSelection()
                } label: {
                    menuSelectionLabel(mode.displayName,
                                       selected: mode == runConfiguration.codexSandboxMode)
                }
            }
        } label: {
            chipLabel(icon: "lock.shield", text: runConfiguration.codexSandboxMode.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Codex sandbox_mode")
    }

    private var codexApprovalChip: some View {
        Menu {
            ForEach(CodexApprovalMode.allCases, id: \.self) { mode in
                Button {
                    runConfiguration.codexApprovalMode = mode
                    refocusComposerAfterMenuSelection()
                } label: {
                    menuSelectionLabel(mode.displayName,
                                       selected: mode == runConfiguration.codexApprovalMode)
                }
            }
        } label: {
            chipLabel(icon: "hand.raised", text: runConfiguration.codexApprovalMode.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Codex approval_policy")
    }

    private var claudeEffortChip: some View {
        Menu {
            ForEach(ClaudeEffort.allCases, id: \.self) { effort in
                Button {
                    runConfiguration.claudeEffort = effort
                    refocusComposerAfterMenuSelection()
                } label: {
                    menuSelectionLabel(effort.displayName,
                                       selected: effort == runConfiguration.claudeEffort)
                }
            }
        } label: {
            chipLabel(icon: "bolt", text: runConfiguration.claudeEffort.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Claude --effort")
    }

    private var codexEffortChip: some View {
        Menu {
            ForEach(Profile.ReasoningEffort.allCases, id: \.self) { effort in
                Button {
                    runConfiguration.codexEffort = effort
                    refocusComposerAfterMenuSelection()
                } label: {
                    menuSelectionLabel(effort.displayName,
                                       selected: effort == runConfiguration.codexEffort)
                }
            }
        } label: {
            chipLabel(icon: "bolt", text: runConfiguration.codexEffort.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Codex model_reasoning_effort")
    }

    private var computerUseChip: some View {
        let isRemote = project.location.isSSH
        let current = CodexComputerUseMode(rawValue: computerUseModeRawValue) ?? .automatic
        return Menu {
            ForEach(CodexComputerUseMode.allCases) { mode in
                Button {
                    computerUseModeRawValue = mode.rawValue
                    refocusComposerAfterMenuSelection()
                } label: {
                    menuSelectionLabel(mode.displayName,
                                       selected: mode == current)
                }
            }
            Divider()
            if isRemote {
                Text("SSH sessions skip local Computer Use")
            } else {
                Text(CodexComputerUseMCP.diagnose(mode: current).title)
            }
        } label: {
            chipLabel(icon: "cursorarrow.motionlines",
                      text: isRemote ? "CU off" : computerUseChipText(current))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(computerUseHelp(isRemote: isRemote, mode: current))
    }

    private func chipLabel(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func menuSelectionLabel(_ text: String, selected: Bool) -> some View {
        if selected {
            Label {
                Text(text)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
            } icon: {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        } else {
            Text(text)
        }
    }

    private func computerUseChipText(_ mode: CodexComputerUseMode) -> String {
        switch mode {
        case .automatic: return "CU auto"
        case .enabled: return "CU on"
        case .disabled: return "CU off"
        }
    }

    private func computerUseHelp(isRemote: Bool, mode: CodexComputerUseMode) -> String {
        if isRemote {
            return "Computer Use is local-only and is skipped for SSH sessions."
        }
        return mode.helpText
    }

    private func syncSelectedProfileIfNeeded(resetConfiguration: Bool) {
        guard let profile = selectedProfile else { return }
        if workerProfileId != profile.id {
            workerProfileId = profile.id
            runConfiguration = .defaults(for: profile)
            return
        }
        if resetConfiguration {
            runConfiguration = .defaults(for: profile)
        }
    }

    private func refocusComposerAfterMenuSelection() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            localFocusRequest &+= 1
        }
    }

    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard ComposerImagePasteboard.isCommandV(event) else { return event }
            return tryPasteImagesFromPasteboard() ? nil : event
        }
    }

    private func removePasteMonitor() {
        if let monitor = pasteMonitor {
            NSEvent.removeMonitor(monitor)
        }
        pasteMonitor = nil
    }

    private func tryPasteImagesFromPasteboard() -> Bool {
        ComposerImagePasteboard.pasteImages(into: &attachments,
                                            imagesDirectory: AppPaths.imagesDir(for: attachmentStorageId),
                                            logPrefix: "[helm.project-inbox]")
    }

    private func removeAttachment(_ attachment: ImageAttachment) {
        ComposerImagePasteboard.remove(attachment, from: &attachments)
    }

    private func removeAllAttachments() {
        ComposerImagePasteboard.removeFiles(attachments)
        attachments = []
    }

    private func submitIfPossible() {
        syncSelectedProfileIfNeeded(resetConfiguration: false)
        guard canSubmit, let selectedProfile else { return }
        store.setDefaultWorkerProfile(selectedProfile.id, for: project.id)
        let submittedAttachments = attachments
        if onSubmit(composedPrompt, displayParts, submittedAttachments, selectedProfile.id, runConfiguration) {
            text = ""
            skillChips = []
            removeAllAttachments()
            attachmentStorageId = UUID()
            composerInteractionResetRequest &+= 1
        }
    }
}

private struct ProjectIdeaProfilePickerMenu: View {
    @Environment(AppStore.self) private var store

    let projectId: UUID
    let selectedProfileId: UUID?
    var onSelect: (Profile) -> Void

    var body: some View {
        let available = store.availableProfiles(for: projectId)
        VStack(alignment: .leading, spacing: 0) {
            groupHeader("Worker Profile · Project Inbox")
            if available.isEmpty {
                emptyHint("No profiles. Open Profiles (gear icon) to add one.")
            } else {
                ForEach(Vendor.allCases, id: \.self) { vendor in
                    let profiles = available.filter { $0.vendor == vendor }
                    if !profiles.isEmpty {
                        subgroupHeader(vendor.displayName)
                        ForEach(profiles) { profile in
                            profileRow(profile, isCurrent: profile.id == selectedProfileId)
                        }
                    }
                }
            }
            divider
            Button {
                store.showProfilesSheet = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .frame(width: 12)
                    Text("Manage providers, models, profiles...")
                        .font(.system(size: 12.5))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(6)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.helmBorder)
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    private func groupHeader(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }

    private func subgroupHeader(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 5)
            .padding(.bottom, 2)
    }

    private func profileRow(_ profile: Profile, isCurrent: Bool) -> some View {
        let model = store.model(profile.primaryModelId)
        let modelLabel = model?.label ?? "missing model"
        return Button {
            onSelect(profile)
        } label: {
            HStack(spacing: 10) {
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                        .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    Text(modelLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(isCurrent ? Color.accentColor.opacity(0.75) : Color.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let model, !model.providerModelId.isEmpty {
                    Text(model.providerModelId)
                        .font(DS.monoFontSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                    .fill(isCurrent ? Color.accentColor.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProjectSchedulerDisclosureHeader: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}

private struct ProjectSchedulerSessionRecapRow: View {
    let session: Session
    let headline: String
    let isRunning: Bool
    var onOpen: () -> Void
    var onTrack: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(headline)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(statusLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(statusColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: DS.cornerRadiusSmall))
            Button {
                onTrack()
            } label: {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Track this session in the project scheduler")
            Button {
                onOpen()
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Open session")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(Color.helmCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                        .stroke(Color.orange.opacity(isRunning ? 0.0 : 0.25), lineWidth: 1)
                )
        )
    }

    private var statusLabel: String {
        isRunning ? "Running" : "Needs triage"
    }

    private var statusColor: Color {
        isRunning ? Color.green : Color.orange
    }

    private var statusSymbolName: String {
        isRunning ? "play.circle.fill" : "exclamationmark.circle"
    }
}

private struct ProjectSchedulerCompletedTaskRow: View {
    let task: ProjectSchedulerTask
    let headline: String?
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.green)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text([headline, task.summary].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(ProjectSchedulerView.relative(task.updatedAt))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            if task.sessionId != nil {
                Button {
                    onOpen()
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Open session")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(Color.helmCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                        .stroke(Color.helmBorder, lineWidth: 1)
                )
        )
    }
}

private struct QuickSwitcherView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var highlightedId: UUID?
    @State private var keyMonitor: Any?
    @FocusState private var searchFocused: Bool

    private var entries: [QuickSwitcherEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allEntries = store.visibleSessions.compactMap { session -> QuickSwitcherEntry? in
            guard let project = store.project(for: session.id) else { return nil }
            let profile = store.profile(session.profileId)
            let path = displayPath(for: project)
            let headline = store.sessionHeadline(session)
            return QuickSwitcherEntry(
                session: session,
                project: project,
                vendor: profile?.vendor,
                headline: headline,
                path: path,
                haystack: [
                    session.title,
                    project.name,
                    path,
                    headline,
                    profile?.name ?? "",
                    profile?.vendor.displayName ?? "",
                ].joined(separator: " ").lowercased()
            )
        }
        guard !needle.isEmpty else { return allEntries }
        let terms = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        return allEntries.filter { entry in
            terms.allSatisfy { entry.haystack.contains($0) }
        }
    }

    private var currentHighlight: UUID? {
        highlightedId.flatMap { id in
            entries.contains { $0.id == id } ? id : nil
        } ?? entries.first?.id
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.14)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)

            panel
        }
        .onAppear {
            highlightedId = entries.first?.id
            focusSearch()
            installKeyMonitor()
        }
        .onChange(of: query) { _, _ in
            highlightedId = entries.first?.id
        }
        .onDisappear(perform: removeKeyMonitor)
        .onExitCommand(perform: close)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            searchRow
            Divider()
            results
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.cornerRadiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cornerRadiusLarge, style: .continuous)
                .stroke(Color.helmBorderStrong, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: 12)
        .padding(.horizontal, 28)
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Jump to session or project", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit(openHighlighted)
            Text("⌘K")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    @ViewBuilder
    private var results: some View {
        if entries.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("Try a session title, project name, or path.")
            )
            .frame(height: 180)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(entries) { entry in
                        Button {
                            open(entry)
                        } label: {
                            QuickSwitcherRow(
                                entry: entry,
                                isHighlighted: entry.id == currentHighlight
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)
            .onMoveCommand { direction in
                switch direction {
                case .up:
                    moveHighlight(by: -1)
                case .down:
                    moveHighlight(by: 1)
                default:
                    break
                }
            }
        }
    }

    private func moveHighlight(by offset: Int) {
        guard !entries.isEmpty else { return }
        let current = currentHighlight.flatMap { id in
            entries.firstIndex { $0.id == id }
        } ?? 0
        highlightedId = entries[(current + offset + entries.count) % entries.count].id
    }

    private func openHighlighted() {
        guard let id = currentHighlight,
              let entry = entries.first(where: { $0.id == id })
        else { return }
        open(entry)
    }

    private func open(_ entry: QuickSwitcherEntry) {
        store.selectedSessionId = entry.session.id
        close()
    }

    private func close() {
        store.hideQuickSwitcherPanel()
        store.requestComposerFocus()
    }

    private func focusSearch() {
        DispatchQueue.main.async {
            searchFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            searchFocused = true
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let commandFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard commandFlags.isEmpty else { return false }

        switch event.keyCode {
        case 125:
            moveHighlight(by: 1)
            return true
        case 126:
            moveHighlight(by: -1)
            return true
        case 36, 76:
            openHighlighted()
            return true
        case 53:
            close()
            return true
        default:
            return false
        }
    }

    private func displayPath(for project: Project) -> String {
        switch project.location {
        case .local(let path):
            return path
        case .ssh(let host, let path, let status):
            let resolved = status.resolvedPath?.isEmpty == false
                ? status.resolvedPath!
                : path
            return "\(host):\(resolved)"
        }
    }
}

private struct QuickSwitcherEntry: Identifiable {
    let session: Session
    let project: Project
    let vendor: Vendor?
    let headline: String
    let path: String
    let haystack: String

    var id: UUID { session.id }
}

private struct QuickSwitcherRow: View {
    let entry: QuickSwitcherEntry
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let vendor = entry.vendor {
                VendorBadge(vendor: vendor)
                    .frame(width: 20, height: 20)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 20, height: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.session.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    Text(entry.project.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text("\(entry.headline) · \(entry.path)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(isHighlighted ? Color.helmSelected : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

private struct CollapsedSidebarRail: View {
    var onExpandSidebar: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SidebarChromeButton(symbolName: "sidebar.left",
                                accessibilityLabel: "Show sidebar",
                                help: "Show sidebar",
                                action: onExpandSidebar)
                .padding(.top, DS.sidebarHeaderTopPadding)

            Spacer()

            SidebarChromeButton(symbolName: "gearshape",
                                accessibilityLabel: "Settings",
                                help: "Profiles & vendor settings",
                                action: onOpenSettings)
                .padding(.bottom, 13)
        }
        .frame(width: DS.sidebarCollapsedRailWidth)
        .background(Color.helmSidebarBg)
    }
}

struct SidebarChromeButton: View {
    let symbolName: String
    let accessibilityLabel: String
    let help: String
    var action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                        .fill(hovered ? Color.helmHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}
