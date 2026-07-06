import SwiftUI

/// Purpose-built detail surface for a gate bead. Surfaces what the gate is waiting on, when
/// a timer expires, which beads it blocks, and who is waiting — with resolve / check / add
/// waiter actions. Shown in place of the generic issue editor for `issue_type == "gate"`.
struct GateDetailPage: View {
    let issue: BeadIssue
    let gate: BeadGate

    @Environment(BeadStore.self) private var store: BeadStore
    @State private var isBusy = false
    @State private var showingResolveSheet = false
    @State private var showingAddWaiterSheet = false
    @State private var checkResult: String?

    var body: some View {
        VStack(spacing: 0) {
            GateBreadcrumbBar(
                gate: gate,
                isBusy: isBusy,
                onResolve: { showingResolveSheet = true },
                onCheck: { Task { await runCheck() } },
                onAddWaiter: { showingAddWaiterSheet = true }
            )
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    conditionSection
                    if !blockedBeads.isEmpty {
                        blocksSection
                    }
                    if let reason = gate.reason {
                        GateSection(title: "Reason") {
                            Text(reason)
                                .textSelection(.enabled)
                                .foregroundStyle(.primary)
                        }
                    }
                    metadataSection
                    // Waiters are only meaningful for multi-agent orchestration, so they sit
                    // last and are hidden entirely when none are registered.
                    if !gate.waiters.isEmpty {
                        waitersSection
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .sheet(isPresented: $showingResolveSheet) {
            GateResolveSheet(gate: gate) { reason in
                await perform { await store.resolveGate(id: gate.id, reason: reason) }
            }
        }
        .sheet(isPresented: $showingAddWaiterSheet) {
            GateAddWaiterSheet(gate: gate) { waiter in
                await perform { await store.addGateWaiter(id: gate.id, waiter: waiter) }
            }
        }
        .alert("Gate check", isPresented: checkResultBinding) {
            Button("OK") { checkResult = nil }
        } message: {
            Text(checkResult ?? "")
        }
    }

    // MARK: Sections

    private var conditionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("WAITING ON")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                GateStateBadge(isOpen: gate.isOpen)
            }
            conditionContent
        }
    }

    @ViewBuilder
    private var conditionContent: some View {
        switch gate.awaitType {
        case .timer:
            if let expiresAt = gate.expiresAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(expiryHeadline(expiresAt: expiresAt, now: context.date))
                            .font(.body)
                        Text(BeadFormatters.displayDate(expiresAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Timer\(gate.timeout.map { " · \(Self.durationText($0))" } ?? "")")
            }
        default:
            Text(GatePresentation.conditionHeadline(for: gate))
        }
    }

    private var blocksSection: some View {
        GateSection(title: blockedBeads.count == 1 ? "Blocks" : "Blocks \(blockedBeads.count) beads") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(blockedBeads) { blocked in
                    Button {
                        store.select([blocked.id])
                    } label: {
                        HStack(spacing: 6) {
                            Text(blocked.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(blocked.title)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var waitersSection: some View {
        GateSection(title: "Waiters (\(gate.waiters.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(gate.waiters, id: \.self) { waiter in
                    Text(waiter)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var metadataSection: some View {
        GateSection(title: "Details") {
            VStack(alignment: .leading, spacing: 4) {
                if let createdAt = gate.createdAt {
                    GateMetaRow(label: "Created", value: BeadFormatters.displayDate(createdAt))
                }
                if let updatedAt = gate.updatedAt {
                    GateMetaRow(label: "Updated", value: BeadFormatters.displayDate(updatedAt))
                }
                GateMetaRow(label: "Status", value: gate.status)
            }
        }
    }

    // MARK: Helpers

    private var blockedBeads: [BeadIssue] {
        store.blockedBeads(byGateID: gate.id)
    }

    private var checkResultBinding: Binding<Bool> {
        Binding(get: { checkResult != nil }, set: { if !$0 { checkResult = nil } })
    }

    private func runCheck() async {
        isBusy = true
        defer { isBusy = false }
        let output = await store.checkGates()
        checkResult = (output?.nilIfBlank) ?? "No changes — gate is still waiting."
    }

    private func perform(_ action: @escaping () async -> Bool) async {
        isBusy = true
        defer { isBusy = false }
        _ = await action()
    }

    private func expiryHeadline(expiresAt: Date, now: Date) -> String {
        if expiresAt <= now {
            return "Timer elapsed — run Check to resolve"
        }
        return "Expires \(BeadFormatters.relative(expiresAt))"
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval) ?? ""
    }
}

// MARK: - Breadcrumb

private struct GateBreadcrumbBar: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let gate: BeadGate
    let isBusy: Bool
    let onResolve: () -> Void
    let onCheck: () -> Void
    let onAddWaiter: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            BreadcrumbButton(store.projectName, systemImage: "folder", help: "Back to beads") {
                store.clearSelection()
            }
            if store.selectedBookmark != .gates {
                BreadcrumbSeparator()
                BreadcrumbLabel(store.selectedBookmark.title, systemImage: store.selectedBookmark.systemImage)
            }
            BreadcrumbSeparator()

            BreadcrumbIssueLabel(
                issueID: gate.id,
                title: gate.title,
                statusDescription: gate.isOpen ? "open gate" : "closed gate",
                statusSymbol: gate.awaitType.systemImage,
                statusColor: GatePresentation.tint(isOpen: gate.isOpen)
            )
            .layoutPriority(-1)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if gate.isOpen {
                    Button("Resolve…", action: onResolve)
                        .controlSize(.small)
                        .disabled(isBusy)

                    Button("Check", action: onCheck)
                        .controlSize(.small)
                        .disabled(isBusy)
                }

                Menu {
                    if gate.isOpen {
                        Button(action: onAddWaiter) {
                            Label("Add Waiter…", systemImage: "person.badge.plus")
                        }
                        .disabled(isBusy)
                        Divider()
                    }
                    Button {
                        IssueClipboard.copyIssueID(gate.id)
                    } label: {
                        Label("Copy Gate ID", systemImage: "doc.on.doc")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("More")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Building blocks

private struct GateStateBadge: View {
    let isOpen: Bool

    var body: some View {
        let tint = GatePresentation.tint(isOpen: isOpen)
        Text(isOpen ? "OPEN" : "CLOSED")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct GateSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct GateMetaRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Sheets

private struct GateResolveSheet: View {
    let gate: BeadGate
    let onResolve: (String?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resolve gate")
                .font(.headline)
            Text("Closing \(gate.id) unblocks the beads it is gating and wakes any waiters.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Reason (optional)", text: $reason, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Resolve") {
                    Task {
                        isSubmitting = true
                        await onResolve(reason)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

private struct GateAddWaiterSheet: View {
    let gate: BeadGate
    let onAdd: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var waiter = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add waiter")
                .font(.headline)
            Text("A waiter is an address (e.g. project/workers/agent-1) that is woken when the gate closes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Waiter address", text: $waiter)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    Task {
                        isSubmitting = true
                        await onAdd(waiter)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || waiter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - Gate creation

/// A gate is created *on an existing bead* — it always blocks one. This compact form is
/// meant to live in a popover anchored to that bead's detail, distinct from the bead editor.
struct GateCreationForm: View {
    let blockedIssueID: String
    let blockedTitle: String
    var onFinished: () -> Void = {}

    @Environment(BeadStore.self) private var store: BeadStore
    @State private var awaitType: GateAwaitType = .timer
    @State private var timeout = "8h"
    @State private var reason = ""
    @State private var awaitID = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Gate")
                    .font(.headline)
                Text("Blocks \(blockedIssueID) — \(blockedTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Picker("Type", selection: $awaitType) {
                ForEach(GateAwaitType.creatable, id: \.self) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.menu)

            switch awaitType {
            case .timer:
                labeledField("Timeout", placeholder: "e.g. 30m, 8h, 7d", text: $timeout)
            case .githubRun:
                labeledField("Run ID", placeholder: "workflow run id", text: $awaitID)
            case .githubPR:
                labeledField("PR number", placeholder: "e.g. 42", text: $awaitID)
            default:
                EmptyView()
            }

            labeledField("Reason", placeholder: "optional", text: $reason)

            HStack {
                Spacer()
                Button("Cancel") { onFinished() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Gate") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || !isValid)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func labeledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func submit() {
        isSubmitting = true
        Task {
            await store.createGate(
                blocks: blockedIssueID,
                type: awaitType,
                reason: reason,
                timeout: awaitType == .timer ? timeout : nil,
                awaitID: (awaitType == .githubRun || awaitType == .githubPR) ? awaitID : nil
            )
            onFinished()
        }
    }

    private var isValid: Bool {
        switch awaitType {
        case .timer:
            return !timeout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .githubRun, .githubPR:
            return !awaitID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }
}
