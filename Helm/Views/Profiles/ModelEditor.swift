import SwiftUI

/// Editor for one Model — wire id + optional alias. The Model is bound to
/// its parent Provider implicitly (set when the row is created via the
/// Provider's [+] in ProfilesSheet); switching providers isn't supported
/// from here.
struct ModelEditor: View {
    @Binding var model: Model
    var onDelete: () -> Void

    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                identitySection
                Spacer(minLength: 4)
                SavedIndicator()
            }
            .padding(20)
        }
        .background(Color.helmChatBg)
    }

    private var header: some View {
        let provider = store.provider(model.providerId)
        return HStack(spacing: 10) {
            if let provider {
                VendorBadge(vendor: provider.vendor).frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.label)
                    .font(.system(size: 16, weight: .semibold))
                Text(provider?.name ?? "no provider")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .controlSize(.small)
        }
    }

    private var identitySection: some View {
        section("Identity") {
            field("Provider model id",
                  hint: "Wire id sent over the network. e.g. model_hub/es2_orange_o47, gpt-5.5-2026-04-24") {
                TextField("model_hub/es2_orange_o47",
                          text: $model.providerModelId)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.monoFontSmall)
            }

            field("Alias",
                  hint: "Optional human-readable label shown in pickers and the chat header. Empty = render the wire id.") {
                TextField("optional, e.g. es2 sonnet 4.6", text: $model.alias)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Layout helpers

    @ViewBuilder
    private func section<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    @ViewBuilder
    private func field<V: View>(_ label: String, hint: String? = nil, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            content()
            if let hint {
                Text(hint).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
    }
}
