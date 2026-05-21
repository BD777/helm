import SwiftUI

/// Lists profiles compatible with the current session's vendor. Tapping a
/// profile rebinds the session. Cross-vendor switches need a new session
/// (added later via the sidebar).
struct ModelPickerMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = store.selectedSession,
               let current = store.profile(session.profileId) {
                let matching = store.profiles(for: current.vendor)
                groupHeader("Profile · \(current.vendor.displayName)")
                if matching.isEmpty {
                    emptyHint("No profiles. Open Profiles (gear icon) to add one.")
                } else {
                    ForEach(matching) { profile in
                        profileRow(profile, isCurrent: profile.id == current.id) {
                            store.setProfile(profile, on: session.id)
                            dismiss()
                        }
                    }
                }
                divider
                Button {
                    store.showProfilesSheet = true
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11))
                            .frame(width: 12)
                        Text("Manage providers, models, profiles…")
                            .font(.system(size: 12.5))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                emptyHint("No session selected.")
            }
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

    private func profileRow(_ profile: Profile, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        let model = store.model(profile.primaryModelId)
        let modelLabel = model?.label ?? "missing model"
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isCurrent ? "checkmark" : "")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tint)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name).font(.system(size: 12.5))
                    Text(modelLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if let m = model, !m.providerModelId.isEmpty {
                    Text(m.providerModelId)
                        .font(DS.monoFontSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
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
