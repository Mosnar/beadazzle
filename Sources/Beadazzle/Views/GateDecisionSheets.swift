import SwiftUI

/// Approve/reject sheets for human decision gates. Shared by the gate detail page and the
/// blocked-bead banner on the issue detail page.
struct GateApproveSheet: View {
    let gate: BeadGate
    let affectedBeads: [BeadIssue]
    let onApprove: (String?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Approve gate")
                .font(.headline)
            Text("Approving \(gate.id) closes the gate and moves eligible blocked beads back to open.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            GateDecisionBeadsList(
                beads: affectedBeads,
                emptyText: "No blocked beads need a status change."
            )
            TextField("Reason (optional)", text: $reason, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button("Approve") {
                    Task {
                        isSubmitting = true
                        let didApprove = await onApprove(reason)
                        isSubmitting = false
                        if didApprove {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(isSubmitting)
    }
}

struct GateRejectSheet: View {
    let gate: BeadGate
    let affectedBeads: [BeadIssue]
    let statusOptions: [String]
    let isDeferredStatus: (String) -> Bool
    let onReject: (String, String, IssueMetadataDateUpdate) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var selectedStatus: String
    @State private var isSubmitting = false
    @State private var deferredStatusRequest: DeferredStatusRequest?

    init(
        gate: BeadGate,
        affectedBeads: [BeadIssue],
        statusOptions: [String],
        defaultStatus: String?,
        isDeferredStatus: @escaping (String) -> Bool,
        onReject: @escaping (String, String, IssueMetadataDateUpdate) async -> Bool
    ) {
        self.gate = gate
        self.affectedBeads = affectedBeads
        self.statusOptions = statusOptions
        self.isDeferredStatus = isDeferredStatus
        self.onReject = onReject
        self._selectedStatus = State(initialValue: defaultStatus ?? statusOptions.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reject gate")
                .font(.headline)
            Text("Rejecting \(gate.id) closes the gate and applies the selected status to eligible blocked beads.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            GateDecisionBeadsList(
                beads: affectedBeads,
                emptyText: "No blocked beads need a status change."
            )
            if statusOptions.isEmpty {
                Text("No statuses are available for rejected beads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Rejected bead status", selection: $selectedStatus) {
                    ForEach(statusOptions, id: \.self) { status in
                        Text(status).tag(status)
                    }
                }
                .pickerStyle(.menu)
            }
            TextField("Reason", text: $reason, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button("Reject", role: .destructive) {
                    reject()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(isSubmitting)
        .sheet(item: $deferredStatusRequest) { request in
            DeferredStatusDateSheet(request: request) { deferUntil in
                await submit(deferUntil: .set(deferUntil))
            }
        }
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func reject() {
        guard canSubmit else { return }
        if isDeferredStatus(selectedStatus), !affectedBeads.isEmpty {
            deferredStatusRequest = DeferredStatusRequest(issues: affectedBeads, status: selectedStatus)
            return
        }
        Task {
            await submit(deferUntil: .unchanged)
        }
    }

    @MainActor
    private func submit(deferUntil: IssueMetadataDateUpdate) async -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        let didReject = await onReject(reason, selectedStatus, deferUntil)
        isSubmitting = false
        if didReject {
            dismiss()
        }
        return didReject
    }
}

private struct GateDecisionBeadsList: View {
    let beads: [BeadIssue]
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(beads.count == 1 ? "Affected bead" : "Affected beads")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if beads.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(beads) { bead in
                        HStack(spacing: 6) {
                            Text(bead.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(bead.title)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}
