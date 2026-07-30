import SwiftUI

/// Find-in-bead bar, pinned under the breadcrumbs so it stays put while the
/// bead scrolls beneath it.
struct BeadFindBar: View {
    @Bindable var session: BeadFindSession
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Find in Bead", text: $session.query)
                .textFieldStyle(.plain)
                .focused($isQueryFocused)
                .font(.callout)
                .frame(minWidth: 120, maxWidth: 260)
                .accessibilityLabel("Find in bead")
                // Handled here rather than via `onSubmit` so ⇧Return can step
                // backwards; returning `.handled` keeps the field from also
                // submitting and double-advancing.
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        session.moveToPreviousMatch()
                    } else {
                        session.moveToNextMatch()
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    session.close()
                    return .handled
                }

            if let summary = session.matchSummary {
                Text(summary)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(session.hasMatches ? .secondary : .tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(summary)
            }

            HStack(spacing: 2) {
                stepButton(
                    systemImage: "chevron.up",
                    label: "Find Previous",
                    action: session.moveToPreviousMatch
                )
                stepButton(
                    systemImage: "chevron.down",
                    label: "Find Next",
                    action: session.moveToNextMatch
                )
            }

            Spacer(minLength: 0)

            Button("Done") {
                session.close()
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 14)
        .frame(height: ContentLayout.workspaceToolbarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .onKeyPress(.escape) {
            session.close()
            return .handled
        }
        // Re-runs whenever the session asks for focus, so ⌘F or ⌥⌘F while the
        // bar is already open puts the caret back in the field. One hop so the
        // field exists first — same approach as the bead picker's search field.
        .task(id: session.focusRequestToken) {
            await Task.yield()
            isQueryFocused = true
        }
    }

    private func stepButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!session.hasMatches)
        .help(label)
        .accessibilityLabel(label)
    }
}
