import AppKit
import SwiftUI

struct BeadCommandFailureDetails: Equatable {
    let command: String?
    let output: String?

    init(command: String?, output: String?) {
        self.command = command?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.output = output?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    var isEmpty: Bool { command == nil && output == nil }

    var copyableText: String {
        [command, output].compactMap(\.self).joined(separator: "\n\n")
    }

    func copyToPasteboard() {
        guard !copyableText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyableText, forType: .string)
    }
}

struct BeadCommandFailureDetailsView: View {
    let details: BeadCommandFailureDetails
    var maximumOutputHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let command = details.command {
                Text(command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .accessibilityLabel("Command: \(command)")
            }

            if let output = details.output {
                if details.command != nil { Divider() }
                if outputNeedsScrolling(output) {
                    ScrollView {
                        outputText(output).padding(10)
                    }
                    .frame(maxHeight: maximumOutputHeight)
                } else {
                    outputText(output).padding(10)
                }
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
    }

    private func outputNeedsScrolling(_ output: String) -> Bool {
        output.count > 600 || output.components(separatedBy: "\n").count > 8
    }

    private func outputText(_ output: String) -> some View {
        Text(output)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Output: \(output)")
    }
}

struct BeadCommandFailureDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let message: String
    let details: BeadCommandFailureDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Text(message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if details.isEmpty {
                Text("No command output was captured for this failure.")
                    .foregroundStyle(.secondary)
            } else {
                BeadCommandFailureDetailsView(
                    details: details,
                    maximumOutputHeight: .infinity
                )
                .frame(maxHeight: .infinity)

                HStack {
                    Spacer()
                    Button("Copy Command and Output", systemImage: "doc.on.doc") {
                        details.copyToPasteboard()
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy the complete captured command and output")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 360, idealHeight: 480)
    }
}
