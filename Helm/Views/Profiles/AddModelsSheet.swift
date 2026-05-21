import SwiftUI

/// Sheet that fetches a provider's `/v1/models` catalog, lets the user pick
/// multiple, and adds them to the parent provider as Models with empty
/// aliases. Aliases are filled later in the Model editor.
///
/// Also has an "add custom" entry for wire ids that don't appear in the
/// catalog (e.g. relay-specific aliases that don't show up in `/v1/models`).
struct AddModelsSheet: View {
    let provider: Provider
    /// Wire ids already attached to this provider — rendered as
    /// already-checked-disabled rows so the user doesn't add duplicates.
    let existingWireIds: Set<String>
    var onAdd: ([ModelCatalogEntry]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var fetchState: FetchState = .idle
    @State private var selected: Set<String> = []
    @State private var search: String = ""
    @State private var customId: String = ""
    /// Custom wire ids the user typed. Surfaced at the top of the list and
    /// pre-selected. Persisted only in this sheet's lifetime.
    @State private var customEntries: [ModelCatalogEntry] = []

    enum FetchState {
        case idle
        case loading
        case loaded([ModelCatalogEntry])
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 540, idealWidth: 600,
               minHeight: 500, idealHeight: 580)
        .task { fetchCatalog(force: false) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VendorBadge(vendor: provider.vendor).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add models from \(provider.name)")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Pulled from \(hostHint())")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    fetchCatalog(force: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(fetchState.isLoading)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11))
                TextField("Filter…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                    .fill(Color.helmCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                            .stroke(Color.helmBorder, lineWidth: 1)
                    )
            )
        }
        .padding(16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch fetchState {
        case .idle, .loading:
            loadingView

        case .failed(let message):
            failureView(message)

        case .loaded(let entries):
            entryList(catalog: entries)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Fetching from \(hostHint())…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(_ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Couldn't fetch models")
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 24)
            HStack(spacing: 8) {
                Button("Retry") { fetchCatalog(force: true) }
                    .controlSize(.small)
                Text("or use the custom-id field below.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }

    private func entryList(catalog: [ModelCatalogEntry]) -> some View {
        // Custom entries first, then catalog. Both pass through filter().
        let merged = customEntries + catalog
        let filtered = filter(merged)
        return ScrollView {
            LazyVStack(spacing: 0) {
                if filtered.isEmpty {
                    Text(search.isEmpty
                         ? "No models returned."
                         : "No matches for \"\(search)\".")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ForEach(filtered) { entry in
                        row(entry)
                    }
                }
            }
        }
    }

    private func row(_ entry: ModelCatalogEntry) -> some View {
        let alreadyAdded = existingWireIds.contains(entry.id)
        let isSelected = selected.contains(entry.id) || alreadyAdded
        let isCustom = customEntries.contains(where: { $0.id == entry.id })
        return Button {
            guard !alreadyAdded else { return }
            toggle(entry.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(
                        alreadyAdded ? Color.secondary.opacity(0.5)
                        : isSelected ? Color.accentColor
                        : Color.secondary.opacity(0.5))
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.id)
                            .font(DS.monoFontSmall)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isCustom {
                            Text("custom")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.accentColor.opacity(0.15))
                                )
                                .foregroundStyle(.tint)
                        }
                        if alreadyAdded {
                            Text("already added")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if let dn = entry.displayName, !dn.isEmpty {
                        Text(dn)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected && !alreadyAdded
                ? Color.accentColor.opacity(0.08)
                : Color.clear
            )
            .opacity(alreadyAdded ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("Or add custom:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("model_hub/es2_orange_o47", text: $customId)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.monoFontSmall)
                    .onSubmit { addCustom() }
                Button {
                    addCustom()
                } label: {
                    Label("Add to list", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(customId.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Text(footerSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(addButtonTitle) { commitAdd() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(16)
    }

    private var footerSummary: String {
        var parts: [String] = []
        if case .loaded(let e) = fetchState {
            parts.append("\(e.count) available")
        }
        if !customEntries.isEmpty {
            parts.append("\(customEntries.count) custom")
        }
        parts.append("\(selected.count) selected")
        return parts.joined(separator: " · ")
    }

    private var addButtonTitle: String {
        selected.isEmpty ? "Add" : "Add \(selected.count)"
    }

    // MARK: - Actions

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) }
        else { selected.insert(id) }
    }

    private func addCustom() {
        let trimmed = customId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Don't double-add if it's already in the catalog OR previously typed.
        let alreadyKnown: Bool = {
            if case .loaded(let e) = fetchState,
               e.contains(where: { $0.id == trimmed }) { return true }
            return customEntries.contains { $0.id == trimmed }
        }()
        if !alreadyKnown {
            customEntries.insert(
                ModelCatalogEntry(id: trimmed, displayName: nil),
                at: 0)
        }
        selected.insert(trimmed)
        customId = ""
    }

    private func commitAdd() {
        let catalog: [ModelCatalogEntry] = {
            if case .loaded(let e) = fetchState { return e }
            return []
        }()
        let merged = customEntries + catalog
        let chosen = merged.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        onAdd(chosen)
        dismiss()
    }

    // MARK: - Helpers

    private func filter(_ entries: [ModelCatalogEntry]) -> [ModelCatalogEntry] {
        guard !search.isEmpty else { return entries }
        let q = search.lowercased()
        return entries.filter { e in
            e.id.lowercased().contains(q) ||
            (e.displayName?.lowercased().contains(q) ?? false)
        }
    }

    private func fetchCatalog(force: Bool) {
        fetchState = .loading
        Task { @MainActor in
            do {
                let entries = try await ModelCatalogService.shared.fetch(
                    for: provider, force: force)
                fetchState = .loaded(entries)
            } catch {
                fetchState = .failed(error.localizedDescription)
            }
        }
    }

    private func hostHint() -> String {
        if !provider.baseURL.isEmpty,
           let host = URL(string: provider.baseURL)?.host {
            return host
        }
        return provider.vendor == .claude ? "api.anthropic.com" : "api.openai.com"
    }
}

private extension AddModelsSheet.FetchState {
    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
