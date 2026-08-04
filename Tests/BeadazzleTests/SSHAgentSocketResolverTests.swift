import XCTest
@testable import Beadazzle

final class SSHAgentSocketResolverTests: XCTestCase {
    func testSSHHostParsesGitSSHAndSCPRemoteURLs() {
        XCTAssertEqual(
            SSHAgentSocketResolver.sshHost(
                from: "git+ssh://git@github.com/venveo/sales-radar.git"
            ),
            "github.com"
        )
        XCTAssertEqual(
            SSHAgentSocketResolver.sshHost(from: "git@github.example:team/tracker.git"),
            "github.example"
        )
    }

    func testSSHDestinationPreservesRemoteUserAndPortForConfigurationLookup() {
        XCTAssertEqual(
            SSHAgentSocketResolver.sshDestination(
                from: "git+ssh://deploy@github.example:2222/team/tracker.git"
            ),
            SSHAgentSocketResolver.Destination(
                host: "github.example",
                user: "deploy",
                port: 2222
            )
        )
        XCTAssertEqual(
            SSHAgentSocketResolver.sshDestination(
                from: "git@github.example:team/tracker.git"
            ),
            SSHAgentSocketResolver.Destination(
                host: "github.example",
                user: "git",
                port: nil
            )
        )
        XCTAssertEqual(
            SSHAgentSocketResolver.sshDestination(
                from: "ssh://git@github.example/team/tracker.git"
            )?.configurationArguments,
            ["-G", "-l", "git", "github.example"]
        )
    }

    func testSSHHostRejectsNonSSHRemoteURLs() {
        XCTAssertNil(
            SSHAgentSocketResolver.sshHost(from: "https://github.com/venveo/sales-radar.git")
        )
        XCTAssertNil(SSHAgentSocketResolver.sshHost(from: "file:///tmp/tracker.git"))
    }

    func testIdentityAgentPathReadsResolvedOpenSSHConfiguration() {
        XCTAssertEqual(
            SSHAgentSocketResolver.identityAgentPath(from: """
            host github.com
            user git
            identityagent /Users/example/Library/Group Containers/agent.sock
            identitiesonly false
            """),
            "/Users/example/Library/Group Containers/agent.sock"
        )
        XCTAssertNil(
            SSHAgentSocketResolver.identityAgentPath(from: "identityagent none")
        )
    }

    func testIdentityAgentSettingHonorsExplicitlyDisabledAgent() {
        let base = [
            "PATH": "/usr/bin:/bin",
            "SSH_AUTH_SOCK": "/tmp/inherited-agent.sock",
        ]

        XCTAssertEqual(
            SSHAgentSocketResolver.applying(.disabled, to: base),
            ["PATH": "/usr/bin:/bin"]
        )
        XCTAssertEqual(
            SSHAgentSocketResolver.applying(.unspecified, to: base),
            base
        )
        XCTAssertEqual(
            SSHAgentSocketResolver.applying(.path("/tmp/configured-agent.sock"), to: base)["SSH_AUTH_SOCK"],
            "/tmp/configured-agent.sock"
        )
    }

    func testIdentityAgentLiteralPreservesInheritedSocket() {
        let base = ["SSH_AUTH_SOCK": "/tmp/inherited-agent.sock"]

        XCTAssertEqual(
            SSHAgentSocketResolver.identityAgentSetting(
                from: "identityagent SSH_AUTH_SOCK"
            ),
            .unspecified
        )
        XCTAssertEqual(
            SSHAgentSocketResolver.applying(.unspecified, to: base),
            base
        )
    }

    func testIdentityAgentDollarVariableResolvesAgainstSubprocessEnvironment() {
        let base = [
            "SSH_AUTH_SOCK": "/tmp/inherited-agent.sock",
            "ONEPASSWORD_SSH_AGENT": "/tmp/onepassword-agent.sock",
        ]
        let setting = SSHAgentSocketResolver.identityAgentSetting(
            from: "identityagent $ONEPASSWORD_SSH_AGENT"
        )

        XCTAssertEqual(setting, .environmentVariable("ONEPASSWORD_SSH_AGENT"))
        XCTAssertEqual(
            SSHAgentSocketResolver.applying(setting, to: base)["SSH_AUTH_SOCK"],
            "/tmp/onepassword-agent.sock"
        )
    }

    func testMissingIdentityAgentDollarVariablePreservesInheritedSocket() {
        let base = ["SSH_AUTH_SOCK": "/tmp/inherited-agent.sock"]

        XCTAssertEqual(
            SSHAgentSocketResolver.applying(.environmentVariable("MISSING_AGENT"), to: base),
            base
        )
    }
}
