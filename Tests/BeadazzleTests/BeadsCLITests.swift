import XCTest
@testable import Beadazzle

final class BeadsCLITests: XCTestCase {
    func testExecutableUsesConfiguredPathBeforeEnvironmentOverrideWhenExecutable() {
        let result = BeadsCLI.executable(
            configuredPath: "/tmp/configured-bd",
            environment: ["BEADAZZLE_BD_PATH": "/tmp/env-bd", "PATH": "/bin"],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            isExecutable: { $0 == "/tmp/configured-bd" || $0 == "/tmp/env-bd" }
        )

        XCTAssertEqual(result.url.path, "/tmp/configured-bd")
        XCTAssertTrue(result.prefix.isEmpty)
    }

    func testExecutableIgnoresInvalidConfiguredPathAndFallsBackToEnvironmentOverride() {
        let result = BeadsCLI.executable(
            configuredPath: "/tmp/not-executable",
            environment: ["BEADAZZLE_BD_PATH": "/tmp/env-bd", "PATH": "/bin"],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            isExecutable: { $0 == "/tmp/env-bd" }
        )

        XCTAssertEqual(result.url.path, "/tmp/env-bd")
        XCTAssertTrue(result.prefix.isEmpty)
    }

    func testExecutableUsesEnvironmentOverrideWhenExecutable() {
        let result = BeadsCLI.executable(
            environment: ["BEADAZZLE_BD_PATH": "/tmp/custom-bd", "PATH": "/bin"],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            isExecutable: { $0 == "/tmp/custom-bd" }
        )

        XCTAssertEqual(result.url.path, "/tmp/custom-bd")
        XCTAssertTrue(result.prefix.isEmpty)
    }

    func testExecutableSearchesHomeLocalBinForGuiLaunches() {
        let result = BeadsCLI.executable(
            environment: ["PATH": ""],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            isExecutable: { $0 == "/tmp/home/.local/bin/bd" }
        )

        XCTAssertEqual(result.url.path, "/tmp/home/.local/bin/bd")
        XCTAssertTrue(result.prefix.isEmpty)
    }

    func testExecutableFallsBackToEnvWhenNoCandidateExists() {
        let result = BeadsCLI.executable(
            environment: ["PATH": ""],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            isExecutable: { _ in false }
        )

        XCTAssertEqual(result.url.path, "/usr/bin/env")
        XCTAssertEqual(result.prefix, ["bd"])
    }

    func testSubprocessEnvironmentMovesResolvedExecutableDirectoryToFrontAndDeduplicates() {
        let result = BeadsCLI.subprocessEnvironment(
            base: ["PATH": "/usr/bin:/opt/homebrew/bin:/usr/local/bin"],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/bd")
        )

        XCTAssertEqual(
            result["PATH"],
            "/opt/homebrew/bin:/usr/bin:/usr/local/bin:/tmp/home/.local/bin"
        )
    }

    func testSubprocessEnvironmentPrependsMissingResolvedExecutableDirectory() {
        let result = BeadsCLI.subprocessEnvironment(
            base: ["PATH": "/usr/bin"],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            executableURL: URL(fileURLWithPath: "/tmp/tools/bd")
        )

        XCTAssertEqual(
            result["PATH"],
            "/tmp/tools:/usr/bin:/tmp/home/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        )
    }

    func testSubprocessEnvironmentLeavesEnvWrapperPathOrderingUnchanged() {
        let result = BeadsCLI.subprocessEnvironment(
            base: ["PATH": "/usr/bin:/opt/homebrew/bin"],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            executableURL: URL(fileURLWithPath: "/usr/bin/env")
        )

        XCTAssertEqual(
            result["PATH"],
            "/usr/bin:/opt/homebrew/bin:/tmp/home/.local/bin:/usr/local/bin"
        )
    }

    func testSubprocessEnvironmentDoesNotInsertRootForRootLevelExecutable() {
        let result = BeadsCLI.subprocessEnvironment(
            base: ["PATH": "/usr/bin"],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            executableURL: URL(fileURLWithPath: "/bd")
        )

        XCTAssertEqual(
            result["PATH"],
            "/usr/bin:/tmp/home/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        )
        XCTAssertFalse(result["PATH", default: ""].split(separator: ":").contains("/"))
    }

    func testSubprocessEnvironmentRemovesXcodeHostInstrumentation() {
        let result = BeadsCLI.subprocessEnvironment(
            base: [
                "PATH": "/usr/bin",
                "SSH_AUTH_SOCK": "/tmp/agent.sock",
                "DYLD_FUTURE_XCODE_SETTING": "injected",
                "DYLD_INSERT_LIBRARIES": "/tmp/libMainThreadChecker.dylib",
                "DYLD_FRAMEWORK_PATH": "/tmp/Debug",
                "DYLD_LIBRARY_PATH": "/tmp/Debug",
                "IDE_DISABLED_OS_ACTIVITY_DT_MODE": "1",
                "OS_ACTIVITY_DT_MODE": "YES",
                "OS_ACTIVITY_TOOLS_OVERSIZE": "YES",
                "OS_ACTIVITY_TOOLS_PRIVACY": "YES",
                "SQLITE_ENABLE_THREAD_ASSERTIONS": "1",
                "__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/tmp/Debug",
                "__XCODE_FUTURE_SETTING": "injected",
                "__XPC_DYLD_FRAMEWORK_PATH": "/tmp/Debug",
                "__XPC_DYLD_LIBRARY_PATH": "/tmp/Debug",
                "__XPC_LLVM_PROFILE_FILE": "/tmp/profile",
                "__XPC_FUTURE_SETTING": "injected",
                "BEADAZZLE_KEEP_ME": "yes"
            ],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/bd")
        )

        XCTAssertEqual(result["SSH_AUTH_SOCK"], "/tmp/agent.sock")
        XCTAssertEqual(result["BEADAZZLE_KEEP_ME"], "yes")
        XCTAssertNil(result["DYLD_FUTURE_XCODE_SETTING"])
        XCTAssertNil(result["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(result["DYLD_FRAMEWORK_PATH"])
        XCTAssertNil(result["DYLD_LIBRARY_PATH"])
        XCTAssertNil(result["IDE_DISABLED_OS_ACTIVITY_DT_MODE"])
        XCTAssertNil(result["OS_ACTIVITY_DT_MODE"])
        XCTAssertNil(result["OS_ACTIVITY_TOOLS_OVERSIZE"])
        XCTAssertNil(result["OS_ACTIVITY_TOOLS_PRIVACY"])
        XCTAssertNil(result["SQLITE_ENABLE_THREAD_ASSERTIONS"])
        XCTAssertNil(result["__XCODE_BUILT_PRODUCTS_DIR_PATHS"])
        XCTAssertNil(result["__XCODE_FUTURE_SETTING"])
        XCTAssertNil(result["__XPC_DYLD_FRAMEWORK_PATH"])
        XCTAssertNil(result["__XPC_DYLD_LIBRARY_PATH"])
        XCTAssertNil(result["__XPC_LLVM_PROFILE_FILE"])
        XCTAssertNil(result["__XPC_FUTURE_SETTING"])
    }
}
