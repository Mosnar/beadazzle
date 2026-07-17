import SwiftUI

struct MissingDatabaseView: View {
    let projectURL: URL
    let isInitializing: Bool
    let isRecovering: Bool
    let onInitialize: (BeadsInitOptions) -> Void
    let onOpenProject: () -> Void

    @State private var options = BeadsInitOptions()
    @State private var showsMoreOptions = false
    @FocusState private var focusedField: FocusedField?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("No Beads Database Found")
                        .font(.title2.weight(.semibold))

                    Text("Beadazzle could not find a current Dolt-backed Beads project with a readable `issues.jsonl` snapshot.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(projectURL.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(projectURL.path)
                }

                actionButtons

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                VStack(spacing: 0) {
                    MoreOptionsHeader(isExpanded: showsMoreOptions) {
                        showsMoreOptions.toggle()
                        if !showsMoreOptions {
                            focusedField = nil
                        }
                    }

                    if showsMoreOptions {
                        MoreOptionsContent(
                            options: $options,
                            focusedField: $focusedField,
                            isDisabled: isBusy
                        )
                        .padding(.top, 12)
                    }
                }
                .disabled(isBusy)
            }
            .padding(32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                initializeButton
                openProjectButton
            }

            VStack(spacing: 10) {
                initializeButton
                openProjectButton
            }
        }
    }

    private var initializeButton: some View {
        Button(action: initialize) {
            if isInitializing {
                Label("Initializing Beads", systemImage: "hourglass")
            } else if isRecovering {
                Label("Checking Beads", systemImage: "arrow.clockwise")
            } else {
                Label("Initialize Beads", systemImage: "plus.circle")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isBusy)
    }

    private var openProjectButton: some View {
        Button(action: onOpenProject) {
            Label("Open Different Project", systemImage: "folder")
        }
        .controlSize(.large)
        .disabled(isBusy)
    }

    private func initialize() {
        guard !isBusy else { return }
        onInitialize(options)
    }

    private var isBusy: Bool {
        isInitializing || isRecovering
    }
}

private enum FocusedField: Hashable {
    case prefix
}

private struct MoreOptionsHeader: View {
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .accessibilityHidden(true)

                Text("More options")
                    .font(.callout)
                    .foregroundStyle(.primary)

                Spacer()
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide more options" : "Show more options")
    }
}

private struct MoreOptionsContent: View {
    @Binding var options: BeadsInitOptions
    var focusedField: FocusState<FocusedField?>.Binding
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                wideOptionsGrid
                compactOptionsStack
            }

            Text("Beadazzle will also export `issues.jsonl` to the active Beads tracker directory so the project can load immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var wideOptionsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow(alignment: .firstTextBaseline) {
                OptionLabel(
                    title: "Issue prefix",
                    help: "Sets the ID prefix for new beads. Leave it blank to use the project folder name."
                )

                prefixField
            }

            GridRow {
                ToggleOption(
                    title: "Use stealth mode",
                    help: "Configures local git excludes so Beads files stay out of the repository by default.",
                    isOn: $options.usesStealthMode,
                    isDisabled: isDisabled
                )
                .gridCellColumns(2)
            }

            GridRow {
                ToggleOption(
                    title: "Skip AGENTS.md setup",
                    help: "Prevents bd from creating or updating agent instruction files during initialization.",
                    isOn: $options.skipsAgents,
                    isDisabled: isDisabled
                )
                .gridCellColumns(2)
            }

            if !options.usesStealthMode {
                GridRow {
                    ToggleOption(
                        title: "Skip git hooks",
                        help: "Skips installing bd-managed git hooks for this repository.",
                        isOn: $options.skipsHooks,
                        isDisabled: isDisabled
                    )
                    .gridCellColumns(2)
                }
            }

            GridRow(alignment: .top) {
                OptionLabel(
                    title: "Command",
                    help: "Shows the bd init command Beadazzle will run with the selected options."
                )

                commandPreview
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactOptionsStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                OptionLabel(
                    title: "Issue prefix",
                    help: "Sets the ID prefix for new beads. Leave it blank to use the project folder name."
                )

                prefixField
            }

            ToggleOption(
                title: "Use stealth mode",
                help: "Configures local git excludes so Beads files stay out of the repository by default.",
                isOn: $options.usesStealthMode,
                isDisabled: isDisabled
            )

            ToggleOption(
                title: "Skip AGENTS.md setup",
                help: "Prevents bd from creating or updating agent instruction files during initialization.",
                isOn: $options.skipsAgents,
                isDisabled: isDisabled
            )

            if !options.usesStealthMode {
                ToggleOption(
                    title: "Skip git hooks",
                    help: "Skips installing bd-managed git hooks for this repository.",
                    isOn: $options.skipsHooks,
                    isDisabled: isDisabled
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                OptionLabel(
                    title: "Command",
                    help: "Shows the bd init command Beadazzle will run with the selected options."
                )

                commandPreview
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var prefixField: some View {
        TextField("Use project folder name", text: $options.prefix)
            .textFieldStyle(.plain)
            .font(.body)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(fieldBorderColor, lineWidth: focusedField.wrappedValue == .prefix ? 1.5 : 1)
            }
            .focused(focusedField, equals: .prefix)
            .onSubmit {
                focusedField.wrappedValue = nil
            }
            .disabled(isDisabled)
            .frame(maxWidth: .infinity)
    }

    private var commandPreview: some View {
        Text(options.commandPreview)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fieldBorderColor: Color {
        focusedField.wrappedValue == .prefix ? Color.accentColor : Color(nsColor: .separatorColor)
    }
}

private struct OptionLabel: View {
    let title: String
    let help: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)

            InfoHelpButton(title: title, help: help)
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ToggleOption: View {
    let title: String
    let help: String
    @Binding var isOn: Bool
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            Toggle(title, isOn: $isOn)
                .disabled(isDisabled)

            InfoHelpButton(title: title, help: help)
        }
        .font(.callout)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InfoHelpButton: View {
    let title: String
    let help: String

    @State private var isShowingHelp = false

    var body: some View {
        Button {
            isShowingHelp.toggle()
        } label: {
            Image(systemName: isShowingHelp ? "info.circle.fill" : "info.circle")
                .font(.caption)
                .foregroundStyle(isShowingHelp ? .secondary : .tertiary)
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(title) information")
        .accessibilityHint("Shows a short explanation.")
        .popover(isPresented: $isShowingHelp, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)

                Text(help)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
        }
    }
}
