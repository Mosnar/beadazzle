import SwiftUI

struct BlockedActionPresentation: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case resolvedGate
        case noActiveGate
    }

    enum Action: Hashable, Sendable, Identifiable {
        case createTimer
        case createDecision
        case reopen

        var id: Self { self }

        var title: String {
            switch self {
            case .createTimer:
                "Timer gate"
            case .createDecision:
                "Decision gate"
            case .reopen:
                "Reopen"
            }
        }

        var systemImage: String {
            switch self {
            case .createTimer:
                "timer"
            case .createDecision:
                "person.badge.clock"
            case .reopen:
                "arrow.uturn.backward.circle"
            }
        }

        var help: String {
            switch self {
            case .createTimer:
                "Create an 8 hour timer gate"
            case .createDecision:
                "Create a human decision gate"
            case .reopen:
                "Move this bead back to the active status"
            }
        }
    }

    let kind: Kind
    let issueID: String
    let message: String
    let actions: [Action]

    var id: String {
        "\(issueID)-\(kind)"
    }

    var systemImage: String {
        switch kind {
        case .resolvedGate:
            "checkmark.seal"
        case .noActiveGate:
            "questionmark.circle"
        }
    }

    var tint: Color {
        switch kind {
        case .resolvedGate:
            Color(nsColor: .systemGreen)
        case .noActiveGate:
            Color(nsColor: .systemOrange)
        }
    }

    static func make(
        issueID: String,
        reason: BlockedReasonPresentation?,
        canCreateGate: Bool = true
    ) -> BlockedActionPresentation? {
        guard let reason else { return nil }
        switch reason.kind {
        case .resolvedGate:
            return BlockedActionPresentation(
                kind: .resolvedGate,
                issueID: issueID,
                message: "Gate resolved; status still blocked.",
                actions: [.reopen]
            )
        case .unexplained:
            return BlockedActionPresentation(
                kind: .noActiveGate,
                issueID: issueID,
                message: "Marked blocked with no active gate.",
                actions: canCreateGate ? [.createTimer, .createDecision, .reopen] : [.reopen]
            )
        case .issue, .gate, .multiple, .external, .subissue:
            return nil
        }
    }
}

struct BlockedActionBanner: View {
    let presentation: BlockedActionPresentation
    let isBusy: Bool
    let perform: (BlockedActionPresentation.Action) -> Void

    @State private var isDismissed = false

    var body: some View {
        if !isDismissed {
            VStack(spacing: 0) {
                divider

                ViewThatFits(in: .horizontal) {
                    horizontalContent
                    verticalContent
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(rowFill)

                divider
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Blocked bead helper")
            .accessibilityValue(presentation.message)
            .help(presentation.message)
        }
    }

    private var horizontalContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            messageLabel

            Spacer(minLength: 12)

            BlockedActionButtons(
                actions: presentation.actions,
                isBusy: isBusy,
                perform: perform
            )

            dismissButton
        }
    }

    private var verticalContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                messageLabel

                Spacer(minLength: 8)

                dismissButton
            }

            BlockedActionButtons(
                actions: presentation.actions,
                isBusy: isBusy,
                perform: perform
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var messageLabel: some View {
        Label {
            Text(presentation.message)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: presentation.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(presentation.tint)
                .accessibilityHidden(true)
        }
    }

    private var dismissButton: some View {
        Button {
            isDismissed = true
        } label: {
            Label("Dismiss", systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .disabled(isBusy)
        .help("Dismiss")
        .accessibilityLabel("Dismiss blocked bead helper")
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.58))
            .frame(height: 1)
    }

    private var rowFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.44)
    }
}

private struct BlockedActionButtons: View {
    let actions: [BlockedActionPresentation.Action]
    let isBusy: Bool
    let perform: (BlockedActionPresentation.Action) -> Void

    var body: some View {
        HStack(spacing: 0) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 8)
                    .accessibilityLabel("Updating blocked bead")
            }

            ForEach(actions) { action in
                Button {
                    perform(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .labelStyle(.titleOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.subheadline)
                .foregroundStyle(isBusy ? Color(nsColor: .tertiaryLabelColor) : Color.accentColor)
                .disabled(isBusy)
                .help(action.help)

                if action != actions.last {
                    Rectangle()
                        .fill(InspectorChrome.dividerFill)
                        .frame(width: 1, height: 12)
                        .padding(.horizontal, 6)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
