import Foundation
import AppKit

/// Privileged command bridge used by SSTP Client GUI.
///
/// v1.4.0 tried to reuse AuthorizationExecuteWithPrivileges so the user would
/// authenticate only once per application session. That API launches tools with
/// an authorization context that is not reliable for the sstpc -> pppd process
/// chain on current macOS releases. In particular, PPP could fail to launch even
/// though the outer privileged command appeared to start successfully.
///
/// Until the app ships a dedicated ServiceManagement privileged helper, use the
/// proven `do shell script ... with administrator privileges` path. It gives the
/// VPN controller a normal root execution context and keeps SSTP/PPP reliable.
final class AuthorizationSession {
    static let shared = AuthorizationSession()

    private init() {}

    private func appleEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Executes `/bin/bash -c <command>` with administrator privileges.
    /// macOS controls whether authentication is requested for each invocation.
    func runShell(_ command: String) -> String? {
        let source = "do shell script \"" + appleEscape(command) + "\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            return "Could not create administrator request"
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error?.description
    }

    /// Kept for API compatibility with the previous implementation.
    func forget() {}
}
