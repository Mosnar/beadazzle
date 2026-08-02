import Foundation

enum ShellCommand {
    private static let safeCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:-@"
    )

    static func render(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(escape).joined(separator: " ")
    }

    static func escape(_ value: String) -> String {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) else {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return value
    }
}
