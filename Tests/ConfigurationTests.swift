import Foundation

@main
struct ConfigurationTests {
    static func main() throws {
        let accepted: [(String, String, String, Int)] = [
            ("vpn.example.com", "443", "vpn.example.com", 443),
            (" vpn.example.com ", " 8443 ", "vpn.example.com", 8443),
            ("vpn.example.com:9443", "8443", "vpn.example.com", 9443),
            ("vpn.example.com:443", "invalid", "vpn.example.com", 443),
            ("192.0.2.1:65535", "443", "192.0.2.1", 65535),
            ("192.0.2.1", "1", "192.0.2.1", 1),
            ("vpn.example.com.", "00443", "vpn.example.com.", 443),
            ("vpn", "443", "vpn", 443),
            ("vpn-01.example", String(repeating: "0", count: 100) + "443", "vpn-01.example", 443)
        ]
        for (server, port, expectedHost, expectedPort) in accepted {
            let endpoint = try VPNEndpoint(server: server, port: port)
            precondition(endpoint.host == expectedHost && endpoint.port == expectedPort,
                         "Unexpected endpoint for \(server) / \(port)")
        }
        let rejected: [(String, String)] = [
            ("", "443"), (" ", "443"), ("vpn.example", ""),
            ("vpn.example", "0"), ("vpn.example", "65536"), ("vpn.example", "-1"),
            ("vpn.example", "+443"), ("vpn.example", "44 3"), ("vpn.example", "１２３"),
            ("vpn.example", "999999999999999999999999"), ("vpn.example", "0000"),
            ("vpn.example:", "443"), ("vpn.example:0", "443"), ("vpn.example: 443", "443"),
            ("https://vpn.example", "443"), ("vpn.example/path", "443"),
            ("[2001:db8::1]:443", "443"), ("2001:db8::1", "443"),
            ("-n", "443"), ("vpn-.example", "443"), ("vpn..example", "443"),
            ("vpn example", "443"), ("vpn|example", "443"), ("vpn\nexample", "443"),
            ("256.0.0.1", "443"), ("127.1", "443"), ("1234", "443"),
            ("1.2.3.4.", "443"), ("0001.2.3.4", "443"), ("192.000.002.001", "443"),
            (String(repeating: "x", count: 64) + ".example", "443"),
            (Array(repeating: String(repeating: "x", count: 63), count: 4).joined(separator: "."), "443"),
            ("\u{00A0}vpn.example", "443")
        ]
        for (server, port) in rejected {
            do {
                _ = try VPNEndpoint(server: server, port: port)
                fatalError("Accepted invalid endpoint: \(server) / \(port)")
            } catch is VPNEndpoint.ValidationError { }
        }

        let legacy = """
        [{"id":"AABBCCDD-1234-5678-ABCD-0123456789AB","name":"Legacy","server":"vpn.example","username":"tester","ignoreCertificate":false,"certificatePath":"","fullTunnel":true}]
        """
        var profiles = try JSONDecoder().decode([VPNProfile].self, from: Data(legacy.utf8))
        precondition(profiles.count == 1 && profiles[0].port == nil && profiles[0].effectivePort == "443")
        profiles[0].port = "8443"
        let restored = try JSONDecoder().decode([VPNProfile].self, from: JSONEncoder().encode(profiles))
        precondition(restored == profiles && restored[0].effectivePort == "8443")
        let proposalProfile = legacy.replacingOccurrences(of: "\"fullTunnel\":true", with: "\"fullTunnel\":true,\"port\":\"9443\"")
        let imported = try JSONDecoder().decode([VPNProfile].self, from: Data(proposalProfile.utf8))
        precondition(imported[0].effectivePort == "9443")

        for password in ["simple", "with spaces", "a'b$;`#", "пароль", String(repeating: "a", count: 242)] {
            try VPNCredentials.validate(password: password)
        }
        for password in ["", "a\"b", "a\\b", "a\nb", "a\rb", "a\r\nb", "a\0b", String(repeating: "a", count: 243), String(repeating: "я", count: 122)] {
            do {
                try VPNCredentials.validate(password: password)
                fatalError("Accepted unsupported password")
            } catch let error as VPNCredentials.ValidationError {
                if !password.isEmpty {
                    precondition(!error.localizedDescription.contains(password), "Error exposed password")
                }
            }
        }
        for password in ["a\"b", "a\\b", "a\\\"b", String(repeating: "a", count: 255), String(repeating: "я", count: 127)] {
            try VPNCredentials.validate(password: password, supportsGUIFixes: true)
        }
        for password in ["", "a\nb", "a\rb", "a\r\nb", "a\0b", String(repeating: "a", count: 256), String(repeating: "я", count: 128)] {
            do {
                try VPNCredentials.validate(password: password, supportsGUIFixes: true)
                fatalError("Accepted unsupported patched-client password")
            } catch is VPNCredentials.ValidationError { }
        }

        let preferred = SSTPClientDependency.preferredPaths[0]
        let alternate = SSTPClientDependency.preferredPaths[1]
        let stock = SSTPClientDependency.stockPaths[0]
        let patchedVersion = "sstp-client 1.0.20 sstp-gui-fixes-1\n"
        func select(_ versions: [String: String]) -> SSTPClientDependency? {
            SSTPClientDependency.find(isExecutable: { versions[$0] != nil }, readVersion: { versions[$0]! })
        }
        precondition(select([:]) == nil)
        let stockOnly = select([stock: "sstp-client 1.0.20"])
        precondition(stockOnly?.path == stock && stockOnly?.supportsGUIFixes == false)
        let patchedPreferred = select([preferred: patchedVersion, stock: "sstp-client 1.0.20"])
        precondition(patchedPreferred?.path == preferred && patchedPreferred?.supportsGUIFixes == true)
        precondition(select([preferred: "sstp-client 1.0.20", stock: "sstp-client 1.0.20"])?.path == stock)
        precondition(select([preferred: "sstp-client 1.0.20", alternate: patchedVersion])?.path == alternate)
        precondition(select([stock: patchedVersion])?.supportsGUIFixes == true)
        for misleading in ["sstp-gui-fixes-10", "1.0.20-sstp-gui-fixes-1", "/tmp/sstp-gui-fixes-1", "sstp-gui-fixes-1.exe"] {
            precondition(select([preferred: misleading]) == nil, "Accepted an inexact capability marker")
        }
        for patched in [false, true] {
            try VPNCertificates.validateSelection(customPath: "/chosen/ca.pem", ignoreVerification: false, supportsGUIFixes: patched)
            try VPNCertificates.validateSelection(customPath: "", ignoreVerification: true, supportsGUIFixes: patched)
        }
        try VPNCertificates.validateSelection(customPath: "", ignoreVerification: false, supportsGUIFixes: true)
        do {
            try VPNCertificates.validateSelection(customPath: "", ignoreVerification: false, supportsGUIFixes: false)
            fatalError("Enabled automatic CA selection with stock client")
        } catch is VPNCredentials.ValidationError { }
        print("Swift configuration tests passed (endpoints, legacy profiles, stock/patched capabilities)")
    }
}
