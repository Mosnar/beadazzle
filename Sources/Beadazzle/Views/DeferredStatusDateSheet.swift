import SwiftUI

struct DeferredStatusRequest: Identifiable, Equatable {
    let issueIDs: [String]
    let title: String?
    let status: String
    let reopeningAncestorIssueIDs: [String]

    init(issues: [BeadIssue], status: String, reopeningAncestorIssueIDs: [String] = []) {
        let sortedIssues = issues.sorted { $0.id < $1.id }
        self.init(
            issueIDs: sortedIssues.map(\.id),
            title: sortedIssues.count == 1 ? sortedIssues.first?.title : nil,
            status: status,
            reopeningAncestorIssueIDs: reopeningAncestorIssueIDs
        )
    }

    init(issueIDs: [String], title: String?, status: String, reopeningAncestorIssueIDs: [String] = []) {
        self.issueIDs = uniqueSortedIssueIDs(issueIDs)
        self.title = title
        self.status = status
        self.reopeningAncestorIssueIDs = uniqueSortedIssueIDs(reopeningAncestorIssueIDs)
    }

    var id: String {
        "\(status)|" + issueIDs.joined(separator: "|") + "|" + reopeningAncestorIssueIDs.joined(separator: "|")
    }

    var targetDescription: String {
        if let id = issueIDs.first, let title {
            return "\(id): \(title)"
        }
        return "\(issueIDs.count.formatted()) selected beads"
    }
}

struct DeferredStatusDateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: DeferredStatusRequest
    var cancelAction: () -> Void = {}
    let action: (Date?) async -> Bool
    @State private var selectedDate: Date?
    @State private var visibleMonth: Date
    @State private var isWorking = false
    @State private var didFinish = false

    init(
        request: DeferredStatusRequest,
        cancelAction: @escaping () -> Void = {},
        action: @escaping (Date?) async -> Bool
    ) {
        self.request = request
        self.cancelAction = cancelAction
        self.action = action
        self._visibleMonth = State(initialValue: CalendarMonthPicker.monthStart(for: Date()))
    }

    private var selectedDateBinding: Binding<Date?> {
        Binding(
            get: { selectedDate.map(normalized) },
            set: { selectedDate = $0.map(normalized) }
        )
    }

    private var confirmTitle: String {
        selectedDate == nil ? "Defer Without Date" : "Defer"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Deferred Date?")
                    .font(.headline)
                Text("Choose an optional date for \(request.targetDescription), or leave it blank to defer without a time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CalendarMonthPicker(selectedDate: selectedDateBinding, visibleMonth: $visibleMonth)

            DateEditorActionBar(
                includesDeferredShortcuts: true,
                canClear: selectedDate != nil,
                setToday: {
                    selectedDate = normalized(Date())
                    visibleMonth = CalendarMonthPicker.monthStart(for: selectedDate ?? Date())
                },
                clear: {
                    selectedDate = nil
                },
                addDay: {
                    add(.day, value: 1)
                },
                addWeek: {
                    add(.day, value: 7)
                },
                addMonth: {
                    add(.month, value: 1)
                }
            )

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    confirm()
                } label: {
                    Text(confirmTitle)
                        .lineLimit(1)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }
        }
        .padding(.horizontal, DateEditorLayout.horizontalPadding)
        .padding(.vertical, DateEditorLayout.verticalPadding)
        .frame(width: DateEditorLayout.containerWidth, alignment: .leading)
        .interactiveDismissDisabled(isWorking)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Deferred date")
        .onDisappear {
            guard !didFinish else { return }
            didFinish = true
            cancelAction()
        }
    }

    private func add(_ component: Calendar.Component, value amount: Int) {
        let base = normalized(selectedDate ?? Date())
        let nextDate = Calendar.current.date(byAdding: component, value: amount, to: base).map(normalized) ?? base
        selectedDate = nextDate
        visibleMonth = CalendarMonthPicker.monthStart(for: nextDate)
    }

    private func normalized(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private func cancel() {
        guard !didFinish else { return }
        didFinish = true
        cancelAction()
        dismiss()
    }

    private func confirm() {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            let didComplete = await action(selectedDate.map(normalized))
            isWorking = false
            if didComplete {
                didFinish = true
                dismiss()
            }
        }
    }
}
