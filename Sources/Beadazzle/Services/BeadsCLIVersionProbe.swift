import Foundation

enum BeadsCLIVersionCheck: Equatable, Sendable {
    case checking
    case valid(version: String)
    case invalid(message: String)
}

/// Confirms that the resolved `bd` executable is actually the Beads CLI by running
/// `bd version` and parsing its banner. Used by app Settings to surface the resolved
/// version and to warn when the configured path points at something else entirely.
enum BeadsCLIVersionProbe {
    static func check() async -> BeadsCLIVersionCheck {
        await check(executable: BeadsCLI.executable())
    }

    static func check(executable: (url: URL, prefix: [String])) async -> BeadsCLIVersionCheck {
        await Task.detached(priority: .userInitiated) {
            runVersionCommand(executable: executable)
        }.value
    }

    static func interpret(terminationStatus: Int32, output: String, timedOut: Bool) -> BeadsCLIVersionCheck {
        if timedOut {
            return .invalid(message: "bd did not respond to `bd version`.")
        }
        guard terminationStatus == 0 else {
            // `/usr/bin/env bd` exits 127 when no `bd` exists anywhere on the search path.
            if terminationStatus == 127 {
                return .invalid(message: "bd was not found. Install Beads or choose its path above.")
            }
            return .invalid(message: "This executable doesn't look like the Beads CLI.")
        }
        guard let version = version(from: output) else {
            return .invalid(message: "This executable doesn't look like the Beads CLI.")
        }
        return .valid(version: version)
    }

    static func version(from output: String) -> String? {
        guard let banner = output
            .components(separatedBy: .newlines)
            .compactMap({ $0.trimmingCharacters(in: .whitespaces).nilIfBlank })
            .first
        else { return nil }

        let prefix = "bd version "
        guard banner.lowercased().hasPrefix(prefix) else { return nil }
        return String(banner.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces).nilIfBlank
    }

    private static func runVersionCommand(executable: (url: URL, prefix: [String])) -> BeadsCLIVersionCheck {
        let process = Process()
        process.executableURL = executable.url
        process.arguments = executable.prefix + ["version"]
        process.environment = BeadsCLI.subprocessEnvironment(executableURL: executable.url)

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            return .invalid(message: "Couldn't run bd: \(error.localizedDescription)")
        }

        let watchdog = WatchdogState()
        let watchdogItem = DispatchWorkItem {
            watchdog.markFired()
            process.terminate()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 10, execute: watchdogItem)
        defer { watchdogItem.cancel() }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return interpret(
            terminationStatus: process.terminationStatus,
            output: text,
            timedOut: watchdog.didFire
        )
    }
}

private final class WatchdogState: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func markFired() {
        lock.lock()
        defer { lock.unlock() }
        fired = true
    }

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}
