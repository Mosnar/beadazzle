import Foundation

enum BeadsJSONCommandOutput {
    static func decodeObject<Value: Decodable>(
        _ type: Value.Type,
        from output: String,
        command: String
    ) throws -> Value {
        let data = try objectData(from: output, command: command)
        return try JSONDecoder().decode(type, from: data)
    }

    static func requireArray(in output: String, command: String) throws {
        try throwIfErrorEnvelope(output, command: command)
        let data = try extractedData(
            from: output,
            opening: "[",
            closing: "]",
            command: command
        )
        guard (try JSONSerialization.jsonObject(with: data)) is [Any] else {
            throw BeadError.commandFailed(command: command, output: output)
        }
    }

    static func throwIfErrorEnvelope(_ output: String, command: String) throws {
        let candidates = [Data(output.utf8), extractedObjectData(from: output)].compactMap { $0 }
        for data in candidates {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = object["error"] as? String,
                  message.nilIfBlank != nil else {
                continue
            }
            throw BeadError.commandFailed(command: command, output: output)
        }
    }

    private static func objectData(from output: String, command: String) throws -> Data {
        try throwIfErrorEnvelope(output, command: command)
        let data = try extractedData(
            from: output,
            opening: "{",
            closing: "}",
            command: command
        )
        guard (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw BeadError.commandFailed(command: command, output: output)
        }
        return data
    }

    private static func extractedObjectData(from output: String) -> Data? {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return Data(output[start...end].utf8)
    }

    private static func extractedData(
        from output: String,
        opening: Character,
        closing: Character,
        command: String
    ) throws -> Data {
        guard let start = output.firstIndex(of: opening),
              let end = output.lastIndex(of: closing),
              start <= end else {
            throw BeadError.commandFailed(command: command, output: output)
        }
        return Data(output[start...end].utf8)
    }
}
