import Foundation
import Security
import Darwin

/// Reuses one Authorization Services session for privileged actions while the
/// application is running. This avoids creating a brand-new authentication
/// session for every Connect / Disconnect / Repair operation.
///
/// AuthorizationExecuteWithPrivileges is deprecated by Apple. It is kept here
/// as a compatibility bridge for the project's macOS 12 deployment target.
/// The long-term replacement is a signed ServiceManagement privileged helper.
final class AuthorizationSession {
    static let shared = AuthorizationSession()

    private typealias ExecuteWithPrivilegesFunction = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private let lock = NSLock()
    private var authorization: AuthorizationRef?
    private var executeFunction: ExecuteWithPrivilegesFunction?

    private init() {}

    deinit {
        if let authorization {
            AuthorizationFree(authorization, [])
        }
    }

    private func loadExecuteFunction() -> ExecuteWithPrivilegesFunction? {
        if let executeFunction { return executeFunction }
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "AuthorizationExecuteWithPrivileges") else {
            return nil
        }
        let function = unsafeBitCast(symbol, to: ExecuteWithPrivilegesFunction.self)
        executeFunction = function
        return function
    }

    private func ensureAuthorization() -> String? {
        if authorization != nil { return nil }

        var newAuthorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &newAuthorization)
        guard createStatus == errAuthorizationSuccess, let newAuthorization else {
            return "AuthorizationCreate failed: \(createStatus)"
        }

        var item = kAuthorizationRightExecute.withCString { name in
            AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
        }
        var rights = withUnsafeMutablePointer(to: &item) { pointer in
            AuthorizationRights(count: 1, items: pointer)
        }
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        let rightsStatus = AuthorizationCopyRights(newAuthorization, &rights, nil, flags, nil)
        guard rightsStatus == errAuthorizationSuccess else {
            AuthorizationFree(newAuthorization, [.destroyRights])
            return rightsStatus == errAuthorizationCanceled
                ? "Administrator authorization was cancelled"
                : "Administrator authorization failed: \(rightsStatus)"
        }

        authorization = newAuthorization
        return nil
    }

    /// Executes `/bin/bash -c <command>` as root. The first call may show the
    /// macOS administrator dialog. Subsequent calls reuse the same auth ref and
    /// normally do not prompt again during the current app session.
    func runShell(_ command: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        if let error = ensureAuthorization() { return error }
        guard let authorization, let execute = loadExecuteFunction() else {
            return "Privileged execution API is unavailable"
        }

        let arguments = ["-c", command]
        var allocated = arguments.map { strdup($0) }
        allocated.append(nil)
        defer {
            for pointer in allocated where pointer != nil { free(pointer) }
        }

        var pipe: UnsafeMutablePointer<FILE>?
        let status: OSStatus = "/bin/bash".withCString { executable in
            allocated.withUnsafeMutableBufferPointer { buffer in
                execute(authorization, executable, [], buffer.baseAddress, &pipe)
            }
        }

        guard status == errAuthorizationSuccess else {
            if status == errAuthorizationCanceled {
                return "Administrator authorization was cancelled"
            }
            return "Privileged command failed to start: \(status)"
        }

        // Reading until EOF makes this call synchronous, matching the old
        // AppleScript behavior and preventing UI state races.
        if let pipe {
            var buffer = [CChar](repeating: 0, count: 1024)
            while fread(&buffer, 1, buffer.count, pipe) > 0 {}
            fclose(pipe)
        }

        return nil
    }

    func forget() {
        lock.lock()
        defer { lock.unlock() }
        if let authorization {
            AuthorizationFree(authorization, [.destroyRights])
            self.authorization = nil
        }
    }
}
