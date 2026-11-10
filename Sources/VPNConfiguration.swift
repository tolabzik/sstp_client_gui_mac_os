import Foundation

/// One interpretation of a server address for connection, routing and diagnostics.
struct VPNEndpoint: Equatable {
    let host: String
    let port: Int

    var target: String { "\(host):\(port)" }

    enum ValidationError: LocalizedError {
        case emptyServer, invalidHost, unsupportedIPv6, invalidPort

        var errorDescription: String? {
            switch self {
            case .emptyServer: return "Enter a VPN server hostname or IPv4 address"
            case .invalidHost: return "Enter a hostname or IPv4 address, without a URL or path"
            case .unsupportedIPv6: return "IPv6 server addresses are not supported by this app's IPv4 routing"
            case .invalidPort: return "VPN port must be a number from 1 to 65535"
            }
        }
    }

    init(server: String, port: String = "443") throws {
        let outerWhitespace = CharacterSet(charactersIn: " \t\r\n\u{0B}\u{0C}")
        let address = server.trimmingCharacters(in: outerWhitespace)
        guard !address.isEmpty else { throw ValidationError.emptyServer }
        guard !address.contains("["), !address.contains("]"),
              address.filter({ $0 == ":" }).count <= 1 else {
            throw ValidationError.unsupportedIPv6
        }
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        let host = String(parts[0])
        let portText = parts.count == 2 ? String(parts[1]) : port.trimmingCharacters(in: outerWhitespace)
        guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(portText.drop(while: { $0 == "0" })), (1...65535).contains(number) else {
            throw ValidationError.invalidPort
        }

        // Limit hostnames to ASCII DNS names; international names can use punycode.
        let dnsName = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = dnsName.split(separator: ".", omittingEmptySubsequences: false)
        let alphanumeric: (UInt8) -> Bool = { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
        guard !dnsName.isEmpty, dnsName.utf8.count <= 253,
              labels.allSatisfy({ label in
                  let bytes = Array(label.utf8)
                  return !bytes.isEmpty && bytes.count <= 63 && alphanumeric(bytes[0]) && alphanumeric(bytes[bytes.count - 1]) && bytes.allSatisfy { alphanumeric($0) || $0 == 45 }
              }) else { throw ValidationError.invalidHost }
        if dnsName.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            guard !host.hasSuffix("."), labels.count == 4, labels.allSatisfy({ label in
                guard label.count <= 3, (label.count == 1 || !label.hasPrefix("0")),
                      let octet = Int(label) else { return false }
                return (0...255).contains(octet)
            }) else { throw ValidationError.invalidHost }
        }
        self.host = host
        self.port = number
    }
}

struct VPNProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var server: String
    var username: String
    var ignoreCertificate: Bool
    var certificatePath: String
    var fullTunnel: Bool
    // Optional so profiles saved before custom ports were introduced still decode.
    var port: String? = nil

    var effectivePort: String { port ?? "443" }
}

enum VPNCredentials {
    struct ValidationError: LocalizedError {
        let errorDescription: String?
    }

    static func validate(password: String, supportsGUIFixes: Bool = false) throws {
        guard !password.isEmpty else {
            throw ValidationError(errorDescription: "Password is required")
        }
        guard !password.unicodeScalars.contains(where: { [0, 10, 13].contains($0.value) }) else {
            throw ValidationError(errorDescription: "Passwords cannot contain NUL characters or line breaks")
        }
        // Only the patched dependency escapes the pppd file while retaining the
        // original password for MPPE. Never pre-escape the --password argument.
        if !supportsGUIFixes && password.unicodeScalars.contains(where: { [34, 92].contains($0.value) }) {
            throw ValidationError(errorDescription: "Upgrade the SSTP component in Setup to use passwords containing quotes or backslashes")
        }
        let limit = supportsGUIFixes ? 255 : 242
        guard password.utf8.count <= limit else {
            throw ValidationError(errorDescription: supportsGUIFixes
                ? "Passwords must not exceed 255 UTF-8 bytes"
                : "Upgrade the SSTP component in Setup to use passwords longer than 242 UTF-8 bytes (maximum 255)")
        }
    }
}

struct SSTPClientDependency {
    static let capabilityMarker = "sstp-gui-fixes-1"
    static let preferredPaths = ["/opt/homebrew/opt/sstp-client-gui/sbin/sstpc", "/usr/local/opt/sstp-client-gui/sbin/sstpc"]
    static let stockPaths = ["/opt/homebrew/sbin/sstpc", "/usr/local/sbin/sstpc"]

    let path: String
    let version: String

    var supportsGUIFixes: Bool {
        // Require a complete marker token, so fixes-10 or a filename cannot
        // accidentally advertise fixes-1 compatibility.
        version.split(whereSeparator: { $0.isWhitespace }).contains(Substring(Self.capabilityMarker))
    }

    static func find(isExecutable: (String) -> Bool, readVersion: (String) -> String) -> SSTPClientDependency? {
        for path in preferredPaths + stockPaths where isExecutable(path) {
            let dependency = SSTPClientDependency(path: path, version: readVersion(path))
            if stockPaths.contains(path) || dependency.supportsGUIFixes { return dependency }
        }
        return nil
    }
}

enum VPNCertificates {
    static func validateSelection(customPath: String, ignoreVerification: Bool, supportsGUIFixes: Bool) throws {
        if !ignoreVerification && customPath.isEmpty && !supportsGUIFixes {
            throw VPNCredentials.ValidationError(errorDescription: "Upgrade the SSTP component in Setup to use automatic certificate verification, or choose a CA certificate file")
        }
    }
}
