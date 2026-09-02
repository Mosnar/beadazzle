import XCTest
@testable import Beadazzle

final class BeadsJSONCommandOutputTests: XCTestCase {
    func testPayloadStripsTheEnvelopeAroundAnObject() throws {
        let context = try BeadsProjectContext.decode(
            from: BeadsJSONCommandOutput.payload(from: """
            {"schema_version":1,"data":{"backend":"dolt","dolt_mode":"embedded","beads_dir":"/tmp/project/.beads"}}
            """)
        )

        XCTAssertEqual(context.backend, "dolt")
        XCTAssertTrue(context.usesCurrentEmbeddedDolt)
    }

    func testPayloadStripsTheEnvelopeAroundAnArray() throws {
        let remotes = try BeadsDoltRemotes.decode(
            from: BeadsJSONCommandOutput.payload(from: """
            {"schema_version":1,"data":[{"name":"origin","url":"git+ssh://git@example.com/project.git"}]}
            """)
        )

        XCTAssertEqual(remotes.primaryRemote?.name, "origin")
    }

    func testPayloadLeavesUnenvelopedOutputUntouched() {
        let output = #"[{"id":"bead-1","title":"Unenveloped"}]"#

        XCTAssertEqual(BeadsJSONCommandOutput.payload(from: output), output)
    }

    // Why: `bd context --json` reports the tracker's own schema version as a top-level
    // field. Unwrapping on that key alone would decode every project as an empty context,
    // which reads as an unsupported project mode.
    func testPayloadKeepsAContextThatCarriesSchemaVersionWithoutData() throws {
        let output = #"{"backend":"dolt","dolt_mode":"embedded","schema_version":65}"#

        XCTAssertEqual(BeadsJSONCommandOutput.payload(from: output), output)
        XCTAssertEqual(try BeadsProjectContext.decode(from: output).backend, "dolt")
    }

    func testPayloadLeavesJSONLExportOutputUntouched() {
        let output = """
        {"id":"bead-1","title":"First"}
        {"id":"bead-2","title":"Second"}
        """

        XCTAssertEqual(BeadsJSONCommandOutput.payload(from: output), output)
    }

    func testDecodeObjectReadsAnEnvelopedPayload() throws {
        let context = try BeadsJSONCommandOutput.decodeObject(
            BeadsProjectContext.self,
            from: #"{"schema_version":1,"data":{"backend":"dolt","role":"maintainer"}}"#,
            command: "bd context --json"
        )

        XCTAssertEqual(context.backend, "dolt")
        XCTAssertEqual(context.role, "maintainer")
    }

    func testRequireArrayAcceptsAnEnvelopedArray() throws {
        try BeadsJSONCommandOutput.requireArray(
            in: #"{"schema_version":1,"data":[{"id":"bead-1"}]}"#,
            command: "bd list --json"
        )
    }

    func testRequireArrayRejectsAnEnvelopedObject() {
        XCTAssertThrowsError(
            try BeadsJSONCommandOutput.requireArray(
                in: #"{"schema_version":1,"data":{"id":"bead-1"}}"#,
                command: "bd list --json"
            )
        )
    }

    func testThrowIfErrorEnvelopeDetectsAnEnvelopedError() {
        XCTAssertThrowsError(
            try BeadsJSONCommandOutput.throwIfErrorEnvelope(
                #"{"schema_version":1,"data":{"error":"schema version mismatch: database is at v65, binary knows up to v53"}}"#,
                command: "bd list --json"
            )
        ) { error in
            guard case BeadError.commandFailed(_, let output) = error else {
                return XCTFail("Expected the enveloped error to fail the command")
            }
            XCTAssertTrue(output.contains("schema version mismatch"))
        }
    }

    func testThrowIfErrorEnvelopeStillDetectsAnUnenvelopedError() {
        XCTAssertThrowsError(
            try BeadsJSONCommandOutput.throwIfErrorEnvelope(
                #"{"error":"no beads database found","schema_version":1}"#,
                command: "bd list --json"
            )
        )
    }

    func testThrowIfErrorEnvelopeAcceptsHealthyEnvelopedOutput() throws {
        try BeadsJSONCommandOutput.throwIfErrorEnvelope(
            #"{"schema_version":1,"data":{"backend":"dolt"}}"#,
            command: "bd context --json"
        )
    }
}
