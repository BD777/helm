import SwiftUI

/// Lists profiles available to the current session. Draft sessions can still
/// switch vendors; sent sessions are locked to their original vendor.
struct ModelPickerMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = store.selectedSession,
               let current = store.profile(session.profileId) {
                let profiles = availableProfiles(for: session, current: current)
                groupHeader(session.isDraft ? "Profile · New chat" : "Profile · \(current.vendor.displayName)")
                if profiles.isEmpty {
                    emptyHint("No profiles. Open Profiles (gear icon) to add one.")
                } else if session.isDraft {
                    ForEach(Vendor.allCases, id: \.self) { vendor in
                        let vendorProfiles = profiles.filter { $0.vendor == vendor }
                        if !vendorProfiles.isEmpty {
                            subgroupHeader(vendor.displayName)
                            ForEach(vendorProfiles) { profile in
                                profileRow(profile, isCurrent: profile.id == current.id) {
                                    store.setProfile(profile, on: session.id)
                                    dismiss()
                                }
                            }
                        }
                    }
                } else {
                    ForEach(profiles) { profile in
                        profileRow(profile, isCurrent: profile.id == current.id) {
                            store.setProfile(profile, on: session.id)
                            dismiss()
                        }
                    }
                    lockHint("Vendor is locked after the first message.")
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

    private func availableProfiles(for session: Session, current: Profile) -> [Profile] {
        guard let project = store.project(for: session.id) else { return [] }
        let scoped = store.availableProfiles(for: project.id)
        if session.isDraft {
            return scoped
        }
        return scoped.filter { $0.vendor == current.vendor }
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

    private func lockHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
