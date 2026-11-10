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
                guard label.count <= 3, let octet = Int(label) else { return false }
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

    static func validate(password: String) throws {
        guard !password.isEmpty else {
            throw ValidationError(errorDescription: "Password is required")
        }
        // sstpc writes --password into pppd's options without quoting these
        // characters. Pre-escaping would also change the MPPE key input.
        guard !password.unicodeScalars.contains(where: { [0, 10, 13, 34, 92].contains($0.value) }) else {
            throw ValidationError(errorDescription: "The current sstp-client password handoff does not safely support quotes, backslashes or line breaks. Connection was stopped before passing the password to sstpc.")
        }
        guard password.utf8.count <= 242 else {
            throw ValidationError(errorDescription: "The current sstp-client password handoff does not safely support passwords longer than 242 UTF-8 bytes. Connection was stopped before passing the password to sstpc.")
        }
    }
}
