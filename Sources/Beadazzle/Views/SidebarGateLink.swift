import SwiftUI

struct SidebarGateLink: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issue: BeadIssue
    let gate: BeadGate

    var body: some View {
        if gate.awaitType == .timer, gate.expiresAt != nil {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                linkButton(now: context.date)
            }
        } else {
            linkButton(now: Date())
        }
    }

    private func linkButton(now: Date) -> some View {
        let gateTint = GatePresentation.tint(for: gate, now: now)

        return HoverPersistentPopover {
            store.openIssueFromDetail(issueID: issue.id)
        } label: { isHovered in
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: gate.awaitType.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(gateTint)
                    .frame(width: 22, height: 22)
                    .background(gateTint.opacity(gate.isOpen ? 0.14 : 0.08), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(GatePresentation.compactTitle(for: gate))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        if let remaining = GatePresentation.timerRemainingText(for: gate, now: now) {
                            Text(remaining)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(gateTint)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(gateTint.opacity(gate.isOpen ? 0.15 : 0.08), in: Capsule())
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    Text(subtitle(now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, InspectorChrome.rowHorizontalPadding)
            .padding(.vertical, 7)
            .padding(.trailing, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: InspectorChrome.rowCornerRadius, style: .continuous))
            .background(isHovered ? InspectorChrome.rowHoverFill : .clear, in: RoundedRectangle(cornerRadius: InspectorChrome.rowCornerRadius, style: .continuous))
            .overlay(alignment: .trailing) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, alignment: .trailing)
                    .padding(.trailing, InspectorChrome.rowHorizontalPadding)
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(true)
            }
        } preview: {
            SidebarGatePreview(issue: issue, gate: gate, now: now)
        }
        .help(helpText(now: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(GatePresentation.compactTitle(for: gate)), \(issue.id)")
        .accessibilityValue("\(GatePresentation.conditionHeadline(for: gate, now: now)), status: \(gate.status)")
        .accessibilityHint("Opens the gate")
    }

    private func subtitle(now: Date) -> String {
        if let reason = gate.reason?.nilIfBlank {
            return reason
        }
        if let expiresAt = gate.expiresAt {
            return expiresAt <= now ? "Timer elapsed; run Check to resolve" : "Expires \(BeadFormatters.displayDate(expiresAt))"
        }
        return GatePresentation.conditionHeadline(for: gate, now: now)
    }

    private func helpText(now: Date) -> String {
        "Blocked by \(GatePresentation.compactTitle(for: gate)) \(issue.id): \(GatePresentation.conditionHeadline(for: gate, now: now))"
    }
}

private struct SidebarGatePreview: View {
    let issue: BeadIssue
    let gate: BeadGate
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SidebarPreviewIDHeader(issueID: issue.id)

            HStack(spacing: 8) {
                Image(systemName: gate.awaitType.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(GatePresentation.tint(for: gate, now: now))

                Text(GatePresentation.compactTitle(for: gate))
                    .font(.headline)
                    .lineLimit(1)
            }

            Text(GatePresentation.conditionHeadline(for: gate, now: now))
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                GatePreviewMetaRow(label: "Status", value: gate.status)
                if let expiresAt = gate.expiresAt {
                    GatePreviewMetaRow(label: "Expires", value: BeadFormatters.displayDate(expiresAt))
                }
                if let timeout = gate.timeout {
                    GatePreviewMetaRow(label: "Timeout", value: GatePresentation.durationText(timeout))
                }
                if let awaitID = gate.awaitID?.nilIfBlank {
                    GatePreviewMetaRow(label: "Await ID", value: awaitID)
                }
                if let reason = gate.reason?.nilIfBlank {
                    GatePreviewMetaRow(label: "Reason", value: reason)
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

private struct GatePreviewMetaRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
