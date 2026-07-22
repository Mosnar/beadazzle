import SwiftUI

private struct ProjectHealthLoadingModifier: ViewModifier {
    @Environment(BeadStore.self) private var store: BeadStore

    func body(content: Content) -> some View {
        content.task(id: store.project.projectURL) {
            guard store.project.projectHealthSnapshot == nil,
                  !store.project.isLoadingProjectHealth else { return }
            store.loadProjectHealthStatus()
        }
    }
}

extension View {
    func loadsProjectHealthStatusIfNeeded() -> some View {
        modifier(ProjectHealthLoadingModifier())
    }
}

struct ProjectPreflightSummaryView: View {
    let preflight: ProjectPreflightHealth
    let badgeStatus: ProjectPreflightHealth.Status?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: preflight.status.systemImage)
                .font(.title3)
                .foregroundStyle(preflight.status.tint)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(preflight.title)
                    .font(.headline)
                Text(preflight.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let badgeStatus {
                ProjectHealthBadge(
                    title: badgeStatus.badgeTitle,
                    style: badgeStatus.badgeStyle
                )
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preflight.title)
        .accessibilityValue(preflight.summary)
    }
}

struct ProjectPreflightCheckRow: View {
    let check: ProjectPreflightHealth.Check

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.status.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(check.status.tint)
                .frame(width: 18)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(check.title)
                        .font(.callout.weight(.semibold))
                    Text(check.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                if let detail = check.detail?.nilIfBlank {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                if let actionHint = check.actionHint?.nilIfBlank {
                    Label(actionHint, systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(check.status.tint)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(check.title), \(check.status.accessibilityLabel)")
        .accessibilityValue(check.summary)
        .accessibilityHint([check.detail, check.actionHint].compactMap { $0?.nilIfBlank }.joined(separator: " "))
    }
}

struct ProjectHealthStatusSummary: View {
    let action: ProjectHealthAction?
    let isLoading: Bool
    let loadedAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            content
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var content: some View {
        if let action {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(action.title)
            }
        } else if isLoading {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading status")
            }
        } else if let loadedAt {
            Label("Updated \(loadedAt.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
        } else {
            Label("Status not loaded", systemImage: "clock")
        }
    }
}

struct ProjectHealthActionButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(isDisabled)
        .help(title)
    }
}

struct ProjectHealthValueText: View {
    let value: String?
    let placeholder: String

    init(_ value: String?, placeholder: String = "Unavailable") {
        self.value = value?.nilIfBlank
        self.placeholder = placeholder
    }

    var body: some View {
        Text(value ?? placeholder)
            .foregroundStyle(value == nil ? .secondary : .primary)
            .lineLimit(1)
    }
}

struct ProjectHealthConfigValueText: View {
    let value: String?
    let errorMessage: String?

    init(_ value: String?, errorMessage: String?) {
        self.value = value
        self.errorMessage = errorMessage
    }

    var body: some View {
        ProjectHealthValueText(errorMessage == nil ? value : nil)
            .help(errorMessage ?? value ?? "Unavailable")
    }
}

struct ProjectHealthPathText: View {
    let value: String?
    let lineLimit: Int

    init(_ value: String?, lineLimit: Int = 1) {
        self.value = value?.nilIfBlank
        self.lineLimit = lineLimit
    }

    var body: some View {
        Text(value ?? "Unavailable")
            .foregroundStyle(value == nil ? .secondary : .primary)
            .lineLimit(lineLimit)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(value ?? "Unavailable")
    }
}

struct ProjectHealthUnavailableRow: View {
    let errorMessage: String?

    var body: some View {
        ProjectHealthMessageRow(
            title: "Unavailable",
            message: errorMessage ?? "Status has not loaded yet.",
            systemImage: "exclamationmark.triangle"
        )
    }
}

struct ProjectHealthMessageRow: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }
}

struct ProjectHealthBadge: View {
    enum Style {
        case ok
        case info
        case warning
        case critical
    }

    let title: String
    let style: Style

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(backgroundStyle, in: Capsule())
            .accessibilityLabel(title)
    }

    private var foregroundStyle: Color {
        switch style {
        case .ok:
            Color.green
        case .info:
            Color.accentColor
        case .warning:
            Color.orange
        case .critical:
            Color.red
        }
    }

    private var backgroundStyle: Color {
        foregroundStyle.opacity(0.14)
    }
}

private extension ProjectPreflightHealth.Status {
    var systemImage: String {
        switch self {
        case .ready:
            "checkmark.circle.fill"
        case .info:
            "info.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .blocked:
            "xmark.octagon.fill"
        case .checking:
            "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .ready:
            .green
        case .info:
            .accentColor
        case .warning:
            .orange
        case .blocked:
            .red
        case .checking:
            .secondary
        }
    }

    var badgeTitle: String {
        switch self {
        case .ready:
            "Ready"
        case .info:
            "Info"
        case .warning:
            "Check"
        case .blocked:
            "Blocked"
        case .checking:
            "Checking"
        }
    }

    var badgeStyle: ProjectHealthBadge.Style {
        switch self {
        case .ready:
            .ok
        case .info, .checking:
            .info
        case .warning:
            .warning
        case .blocked:
            .critical
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .ready:
            "ready"
        case .info:
            "informational"
        case .warning:
            "needs attention"
        case .blocked:
            "blocked"
        case .checking:
            "checking"
        }
    }
}
