import SwiftUI

struct ChatToolbar: View {
    @Environment(AppStore.self) private var store
    @State private var pickerOpen: Bool = false

    var body: some View {
        let session = store.selectedSession
        let project = session.flatMap { store.project(for: $0.id) }

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session?.title ?? "—")
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text(project?.location.pathString ?? "")
                    .font(DS.monoFontSmall)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if store.isStreaming {
                RunPill()
            }

            ModelPickerButton(open: $pickerOpen)
                .popover(isPresented: $pickerOpen, arrowEdge: .top) {
                    ModelPickerMenu()
                        .frame(width: 320)
                }

            ApprovalSegmented()

            Menu {
                Button("Rename…") { }
                Button("Copy session ID") { }
                Button("Open in Finder") { }
                Divider()
                Button("Archive", role: .destructive) { }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}

private struct ModelPickerButton: View {
    @Environment(AppStore.self) private var store
    @Binding var open: Bool

    var body: some View {
        let s = store.selectedSession
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                if let s {
                    VendorBadge(vendor: s.vendor).frame(width: 14, height: 14)
                    Text(s.model).font(.system(size: 12))
                    Text("· \(s.profileName)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("No model").font(.system(size: 12))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
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

private struct ApprovalSegmented: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let s = store.selectedSession
        HStack(spacing: 0) {
            ForEach(ApprovalMode.allCases, id: \.self) { mode in
                let on = (s?.approvalMode == mode)
                Button {
                    if var cur = store.selectedSession {
                        cur.approvalMode = mode
                        store.selectedSession = cur
                    }
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 11.5, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? .white : .secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(on ? Color.accentColor : Color.clear)
                }
                .buttonStyle(.plain)
                if mode != ApprovalMode.allCases.last {
                    Divider().frame(height: 16)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                .fill(Color.helmCard)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.cornerRadiusSmall)
                        .stroke(Color.helmBorder, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.cornerRadiusSmall))
    }
}

private struct RunPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.orange)
                .frame(width: 6, height: 6)
                .opacity(0.9)
            Text("Running · 0:12")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Button("Stop") { }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.orange.opacity(0.15))
                .overlay(Capsule().stroke(Color.orange.opacity(0.3), lineWidth: 1))
        )
    }
}
