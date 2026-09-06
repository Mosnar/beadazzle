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
        let envelopePayload = envelopePayload(from: output)
        try throwIfErrorEnvelope(output, envelopePayload: envelopePayload, command: command)
        let data = try extractedData(
            from: envelopePayload ?? output,
            opening: "[",
            closing: "]",
            command: command
        )
        guard (try JSONSerialization.jsonObject(with: data)) is [Any] else {
            throw BeadError.commandFailed(command: command, output: output)
        }
    }

    /// Strips bd's JSON envelope — `{"schema_version": <n>, "data": <payload>}` — which
    /// `BD_JSON_ENVELOPE=1` turns on today and which bd announced as the default from 2.0.
    /// Output that carries no envelope is returned untouched, so both wire formats decode
    /// the same way. Every parse of `bd --json` output has to go through this first: the
    /// fields Beadazzle decodes live inside `data`, and so does an enveloped `error`.
    static func payload(from output: String) -> String {
        envelopePayload(from: output) ?? output
    }

    static func throwIfErrorEnvelope(_ output: String, command: String) throws {
        try throwIfErrorEnvelope(
            output,
            envelopePayload: envelopePayload(from: output),
            command: command
        )
    }

    /// Callers that already unwrapped the envelope pass it along so unenveloped output is
    /// parsed once, not once per step.
    private static func throwIfErrorEnvelope(
        _ output: String,
        envelopePayload: String?,
        command: String
    ) throws {
        if reportsError(in: output) {
            throw BeadError.commandFailed(command: command, output: output)
        }
        if let envelopePayload, reportsError(in: envelopePayload) {
            throw BeadError.commandFailed(command: command, output: output)
        }
    }

    /// The serialized `data` member of an enveloped output; nil when the output is not enveloped.
    private static func envelopePayload(from output: String) -> String? {
        guard let envelope = envelopeObject(in: output),
              let payload = envelope["data"],
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.fragmentsAllowed]
              ),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func reportsError(in text: String) -> Bool {
        let candidates = [Data(text.utf8), extractedObjectData(from: text)].compactMap { $0 }
        for data in candidates {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = object["error"] as? String,
                  message.nilIfBlank != nil else {
                continue
            }
            return true
        }
        return false
    }

    private static func envelopeObject(in output: String) -> [String: Any]? {
        guard let data = extractedObjectData(from: output),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema_version"] != nil,
              object.keys.contains("data") else {
            return nil
        }
        return object
    }

    private static func objectData(from output: String, command: String) throws -> Data {
        let envelopePayload = envelopePayload(from: output)
        try throwIfErrorEnvelope(output, envelopePayload: envelopePayload, command: command)
        let data = try extractedData(
            from: envelopePayload ?? output,
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
