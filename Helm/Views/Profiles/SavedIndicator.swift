import SwiftUI

/// Tiny "Saved · HH:mm:ss" footer the editors render under their content.
/// Reads the last-write timestamp the AppStore publishes when ProfileStore /
/// StateStore finishes a write — the only feedback users get that the
/// debounced auto-save actually made it to disk (no Save button anywhere).
struct SavedIndicator: View {
    @Environment(AppStore.self) private var store

    /// `.profiles` reads `lastProfilesSaveAt`; `.state` reads `lastStateSaveAt`.
    enum Source { case profiles, state }
    var source: Source = .profiles

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if let date = timestamp {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("Saved · \(formatted(date))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            } else {
                Text("Auto-saves on edit.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 6)
    }

    private var timestamp: Date? {
        switch source {
        case .profiles: return store.lastProfilesSaveAt
        case .state:    return store.lastStateSaveAt
        }
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
