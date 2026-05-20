import SwiftUI

struct ApprovalCard: View {
    let approval: Approval
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 13))
                Text("Claude wants to run a command")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            Text(approval.command)
                .font(DS.monoFont)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                        .fill(Color.helmCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                                .stroke(Color.helmBorder, lineWidth: 1)
                        )
                )

            Text("in \(approval.cwd)")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Button("Deny", role: .destructive) { store.pendingApproval = false }
                Button("Approve once") { store.pendingApproval = false }
                    .keyboardShortcut(.defaultAction)
                Button("Always allow rm in this project") { store.pendingApproval = false }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadius)
                .fill(Color.orange.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadius)
                        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                )
        )
    }
}
