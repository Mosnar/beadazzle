import AppKit
import SwiftUI

struct AboutBeadazzleView: View {
    static let windowID = "about"

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let info: AboutBeadazzleInfo

    @State private var didCopyEmail = false
    @State private var copyConfirmationTask: Task<Void, Never>?

    init(info: AboutBeadazzleInfo = AboutBeadazzleInfo()) {
        self.info = info
    }

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 160, height: 160)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(AboutBeadazzleInfo.appName)
                    .font(.system(.largeTitle, design: .default, weight: .regular))

                Text(info.versionDescription)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Spacer()
                    .frame(height: 28)

                Text("Created by \(AboutBeadazzleInfo.author)")
                    .font(.body)

                HStack(spacing: 8) {
                    Button(AboutBeadazzleInfo.emailAddress) {
                        copyEmailAddress()
                    }
                    .buttonStyle(.link)
                    .accessibilityHint("Copies the email address")

                    if didCopyEmail {
                        Label("Copied", systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }

                HStack(spacing: 12) {
                    Button(AboutDisclosure.acknowledgments.title) {
                        openWindow(id: AboutDisclosure.acknowledgments.windowID)
                    }

                    Button(AboutDisclosure.license.title) {
                        openWindow(id: AboutDisclosure.license.windowID)
                    }
                }
                .font(.callout)
                .buttonStyle(.link)
                .padding(.top, 8)

                Spacer()

                HStack(spacing: 12) {
                    Link(
                        "GitHub Repository",
                        destination: AboutBeadazzleInfo.repositoryURL
                    )

                    Link(
                        "Report a Problem",
                        destination: AboutBeadazzleInfo.issuesURL
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 40)
        .padding(.top, 52)
        .padding(.bottom, 30)
        .frame(width: 640, height: 320)
        .background(AboutWindowInitialFocusReset())
        .onDisappear {
            copyConfirmationTask?.cancel()
        }
    }

    private func copyEmailAddress() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(AboutBeadazzleInfo.emailAddress, forType: .string)

        copyConfirmationTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            didCopyEmail = true
        }

        copyConfirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }

            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                didCopyEmail = false
            }
        }
    }
}

private struct AboutWindowInitialFocusReset: NSViewRepresentable {
    func makeNSView(context: Context) -> InitialFocusResetView {
        InitialFocusResetView()
    }

    func updateNSView(_ nsView: InitialFocusResetView, context: Context) {}

    final class InitialFocusResetView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }

            Task { @MainActor [weak window] in
                window?.initialFirstResponder = nil
                window?.makeFirstResponder(nil)
            }
        }
    }
}

struct AboutBeadazzleInfo: Equatable {
    static let appName = "Beadazzle"
    static let author = "Ransom Roberson"
    static let emailAddress = "beadazzle@ransom.lol"
    static let repositoryURL = URL(string: "https://github.com/Mosnar/beadazzle")!
    static let issuesURL = URL(string: "https://github.com/Mosnar/beadazzle/issues")!

    let versionDescription: String

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        guard let version = Self.trimmedValue(
            in: infoDictionary,
            forKey: "CFBundleShortVersionString"
        ) else {
            versionDescription = "Development build"
            return
        }

        if let build = Self.trimmedValue(in: infoDictionary, forKey: "CFBundleVersion") {
            versionDescription = "Version \(version) (\(build))"
        } else {
            versionDescription = "Version \(version)"
        }
    }

    private static func trimmedValue(
        in infoDictionary: [String: Any]?,
        forKey key: String
    ) -> String? {
        guard let value = infoDictionary?[key] as? String else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
