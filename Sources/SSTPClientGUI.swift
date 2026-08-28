import SwiftUI
import AppKit
import Security
import Darwin

// MARK: - Keychain

struct KeychainStore {
    static let service = "SSTP Client GUI"

    static func load(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func save(account: String, password: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(password.utf8)
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

enum VPNStatus: Equatable {
    case disconnected, connecting, connected, error
}

final class VPNModel: ObservableObject {
    @Published var server = ""
    @Published var username = ""
    @Published var password = ""
    @Published var ignoreCertificate = false
    @Published var certificatePath = ""
    @Published var fullTunnel = true

    @Published var status: VPNStatus = .disconnected
    @Published var message = ""

    @Published var brewOK = false
    @Published var sstpOK = false
    @Published var pppdOK = false
    @Published var optionsOK = false
    @Published var brewText = ""
    @Published var sstpText = ""

    @Published var diagnostics = ""
    @Published var diagnosticsRunning = false
    @Published var diagnosticTarget = ""
    @Published var diagnosticPort = "443"

    private let resultFile = "/tmp/sstp-gui.result"
    private let pidFile = "/tmp/sstp-gui.pid"
    private let stateFile = "/tmp/sstp-gui.state"
    private let logFile = "/tmp/sstp-gui.log"
    private var timer: Timer?

    init() {
        loadPreferences()
        password = KeychainStore.load(account: username)
        checkComponents()
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    deinit { timer?.invalidate() }

    var ready: Bool { brewOK && sstpOK && pppdOK && optionsOK }
    var connected: Bool { status == .connected }
    var canDisconnect: Bool { connected || processAlive() || FileManager.default.fileExists(atPath: stateFile) }

    var statusText: String {
        switch status {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .error: return "Error"
        }
    }

    var statusColor: Color {
        switch status {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .connected: return .green
        case .error: return .red
        }
    }

    private var controllerPath: String? { Bundle.main.path(forResource: "vpnctl", ofType: "sh") }
    private var setupPath: String? { Bundle.main.path(forResource: "setup", ofType: "sh") }

    private func loadPreferences() {
        let d = UserDefaults.standard
        server = d.string(forKey: "server") ?? ""
        username = d.string(forKey: "username") ?? ""
        ignoreCertificate = d.object(forKey: "ignoreCertificate") as? Bool ?? false
        certificatePath = d.string(forKey: "certificatePath") ?? ""
        fullTunnel = d.object(forKey: "fullTunnel") as? Bool ?? true
        diagnosticTarget = d.string(forKey: "diagnosticTarget") ?? ""
        diagnosticPort = d.string(forKey: "diagnosticPort") ?? "443"
    }

    private func savePreferences() {
        let d = UserDefaults.standard
        d.set(server, forKey: "server")
        d.set(username, forKey: "username")
        d.set(ignoreCertificate, forKey: "ignoreCertificate")
        d.set(certificatePath, forKey: "certificatePath")
        d.set(fullTunnel, forKey: "fullTunnel")
        d.set(diagnosticTarget, forKey: "diagnosticTarget")
        d.set(diagnosticPort, forKey: "diagnosticPort")
    }

    private func run(_ executable: String, _ args: [String]) -> String {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return "ERROR: \(error.localizedDescription)\n"
        }
    }

    private func runShell(_ command: String) -> String { run("/bin/bash", ["-lc", command]) }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func appleEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runAdmin(_ command: String) -> String? {
        let source = "do shell script \"" + appleEscape(command) + "\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return "Could not create AppleScript" }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error?.description
    }

    private func runAdminAsync(_ command: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let error = self.runAdmin(command)
            DispatchQueue.main.async { completion(error) }
        }
    }

    private func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func sstpcPath() -> String? {
        ["/opt/homebrew/sbin/sstpc", "/usr/local/sbin/sstpc"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func checkComponents() {
        DispatchQueue.global(qos: .utility).async {
            let brew = self.brewPath()
            let sstp = self.sstpcPath()
            let brewText = brew.map { self.run($0, ["--version"]).components(separatedBy: "\n").first ?? "OK" } ?? "Not installed"
            let sstpText = sstp.map { self.run($0, ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "Not installed"
            let pppdOK = FileManager.default.isExecutableFile(atPath: "/usr/sbin/pppd")
            let optionsOK = FileManager.default.fileExists(atPath: "/etc/ppp/options")
            DispatchQueue.main.async {
                self.brewOK = brew != nil
                self.sstpOK = sstp != nil
                self.pppdOK = pppdOK
                self.optionsOK = optionsOK
                self.brewText = brewText
                self.sstpText = sstpText
            }
        }
    }

    private func processAlive() -> Bool {
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func routeInterface(_ address: String) -> String {
        let output = run("/sbin/route", ["-n", "get", address])
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                return t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private func readResult() -> String {
        (try? String(contentsOfFile: resultFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func refreshStatus() {
        let result = readResult()
        if result.hasPrefix("OK|") {
            let fields = result.split(separator: "|")
            if fields.count >= 2 {
                let ppp = String(fields[1])
                if processAlive() {
                    if fullTunnel {
                        if routeInterface("1.1.1.1") == ppp {
                            status = .connected
                            message = "Full tunnel active via \(ppp)"
                            return
                        }
                    } else {
                        status = .connected
                        message = "SSTP connected via \(ppp)"
                        return
                    }
                }
            }
        }
        if processAlive() {
            status = .connecting
            message = "SSTP/PPP is starting and routes are being checked"
            return
        }
        if result.hasPrefix("FAIL|") {
            status = .error
            message = String(result.dropFirst(5))
            return
        }
        if status != .error {
            status = .disconnected
            message = ""
        }
    }

    func chooseCertificate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["crt", "pem", "cer"]
        if panel.runModal() == .OK, let url = panel.url {
            certificatePath = url.path
            savePreferences()
        }
    }

    private func writeSecret() -> String? {
        let path = "/tmp/sstp-gui-secret-\(getpid()).txt"
        do {
            try password.write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, S_IRUSR | S_IWUSR)
            return path
        } catch { return nil }
    }

    func connect() {
        guard ready else { status = .error; message = "Install required components first"; return }
        guard !server.isEmpty, !username.isEmpty, !password.isEmpty else { status = .error; message = "Server, username and password are required"; return }
        guard let controller = controllerPath else { status = .error; message = "vpnctl.sh is missing from the app bundle"; return }
        if !ignoreCertificate && certificatePath.isEmpty { status = .error; message = "Choose a CA/server certificate or enable certificate ignore mode"; return }
        guard let secret = writeSecret() else { status = .error; message = "Could not prepare password handoff"; return }

        savePreferences()
        KeychainStore.save(account: username, password: password)
        try? FileManager.default.removeItem(atPath: resultFile)

        let certMode = ignoreCertificate ? "ignore" : "verify"
        let command = "/bin/bash \(shellQuote(controller)) connect \(shellQuote(server)) \(shellQuote(username)) \(shellQuote(secret)) \(shellQuote(certMode)) \(shellQuote(certificatePath)) \(fullTunnel ? "1" : "0")"
        status = .connecting
        message = fullTunnel ? "Connecting; full tunnel will only be enabled after a PPP connectivity test" : "Connecting SSTP"

        runAdminAsync(command) { error in
            if let error {
                try? FileManager.default.removeItem(atPath: secret)
                self.status = .error
                self.message = error
            } else {
                self.refreshStatus()
            }
        }
    }

    func disconnect() {
        guard let controller = controllerPath else { return }
        let command = "/bin/bash \(shellQuote(controller)) disconnect \(shellQuote(server))"
        status = .connecting
        message = "Disconnecting..."
        runAdminAsync(command) { error in
            if let error { self.status = .error; self.message = error }
            else { self.status = .disconnected; self.message = "" }
            self.refreshStatus()
        }
    }

    func repairNetworking() {
        guard let controller = controllerPath else { return }
        let command = "/bin/bash \(shellQuote(controller)) repair \(shellQuote(server))"
        status = .connecting
        message = "Removing SSTP GUI routes and owned process..."
        runAdminAsync(command) { error in
            if let error { self.status = .error; self.message = error }
            else { self.status = .disconnected; self.message = "Network state cleaned" }
        }
    }

    func installComponents() {
        guard let source = setupPath,
              let text = try? String(contentsOfFile: source, encoding: .utf8) else {
            status = .error; message = "setup.sh is missing from the app bundle"; return
        }
        let target = "/tmp/SSTP-Client-GUI-Setup.command"
        do {
            try text.write(toFile: target, atomically: true, encoding: .utf8)
            chmod(target, 0o755)
            NSWorkspace.shared.open(URL(fileURLWithPath: target))
        } catch { status = .error; message = error.localizedDescription }
    }

    func useVPNServerAsDiagnosticTarget() {
        diagnosticTarget = server
        savePreferences()
    }

    func runDiagnostics() {
        diagnosticsRunning = true
        diagnostics = "Running extended diagnostics..."
        savePreferences()

        let serverCopy = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedTarget = diagnosticTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetCopy = requestedTarget.isEmpty ? serverCopy : requestedTarget
        let parsedPort = Int(diagnosticPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 443
        let portCopy = (1...65535).contains(parsedPort) ? parsedPort : 443

        DispatchQueue.global(qos: .userInitiated).async {
            var out = ""

            func section(_ name: String) {
                out += "\n=== \(name) ===\n"
            }

            func appendCommand(_ executable: String, _ args: [String]) {
                let result = self.run(executable, args)
                out += result.isEmpty ? "NO OUTPUT\n" : result
            }

            func appendHostResolution(_ host: String) {
                let byName = self.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", host])
                if !byName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out += byName
                    return
                }
                let byAddress = self.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "ip_address", host])
                out += byAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "NO DNS RESULT\n" : byAddress
            }

            func appendTrace(_ host: String) {
                appendCommand("/usr/sbin/traceroute", ["-n", "-m", "12", "-w", "1", "-q", "1", host])
            }

            section("DATE")
            appendCommand("/bin/date", [])

            section("MACOS")
            appendCommand("/usr/bin/sw_vers", [])

            section("ARCH")
            appendCommand("/usr/bin/uname", ["-m"])

            section("NETWORK PATH SNAPSHOT")
            appendCommand("/usr/sbin/scutil", ["--nwi"])

            section("PROXY CONFIGURATION")
            appendCommand("/usr/sbin/scutil", ["--proxy"])

            section("DEFAULT ROUTE")
            appendCommand("/sbin/route", ["-n", "get", "default"])

            section("HOMEBREW")
            out += self.brewPath().map { self.run($0, ["--version"]) } ?? "NOT INSTALLED\n"

            section("SSTP")
            out += self.sstpcPath().map { self.run($0, ["--version"]) + "\nPath: \($0)\n" } ?? "NOT INSTALLED\n"

            section("PPPD")
            out += self.runShell("ls -l /usr/sbin/pppd /etc/ppp/options 2>&1")

            section("VPN PROCESS")
            out += self.runShell("if [ -f /tmp/sstp-gui.pid ]; then PID=$(cat /tmp/sstp-gui.pid); ps -p \"$PID\" -o pid,ppid,user,etime,comm; else echo NONE; fi")

            section("PPP INTERFACES")
            out += self.runShell("/sbin/ifconfig | grep -A 12 '^ppp' || true")

            section("INTERNET ROUTE 1.1.1.1")
            appendCommand("/sbin/route", ["-n", "get", "1.1.1.1"])

            section("INTERNET ICMP 1.1.1.1")
            appendCommand("/sbin/ping", ["-c", "4", "1.1.1.1"])

            section("INTERNET TCP 1.1.1.1:443")
            appendCommand("/usr/bin/nc", ["-vz", "-G", "5", "1.1.1.1", "443"])

            section("INTERNET TRACEROUTE 1.1.1.1")
            appendTrace("1.1.1.1")

            if !serverCopy.isEmpty {
                section("VPN SERVER DNS")
                appendHostResolution(serverCopy)

                section("VPN SERVER ROUTE")
                appendCommand("/sbin/route", ["-n", "get", serverCopy])

                section("VPN SERVER ICMP")
                appendCommand("/sbin/ping", ["-c", "4", serverCopy])

                section("VPN SERVER TCP 443")
                appendCommand("/usr/bin/nc", ["-vz", "-G", "5", serverCopy, "443"])

                section("VPN SERVER TRACEROUTE")
                appendTrace(serverCopy)
            }

            if !targetCopy.isEmpty {
                section("DIAGNOSTIC TARGET")
                out += "Host: \(targetCopy)\nTCP port: \(portCopy)\n"

                section("TARGET DNS")
                appendHostResolution(targetCopy)

                section("TARGET ROUTE")
                appendCommand("/sbin/route", ["-n", "get", targetCopy])

                section("TARGET ICMP")
                appendCommand("/sbin/ping", ["-c", "4", targetCopy])

                section("TARGET TCP \(portCopy)")
                appendCommand("/usr/bin/nc", ["-vz", "-G", "5", targetCopy, String(portCopy)])

                section("TARGET TRACEROUTE")
                appendTrace(targetCopy)
            } else {
                section("DIAGNOSTIC TARGET")
                out += "NOT SET\n"
            }

            section("ROUTING TABLE")
            out += self.runShell("/usr/sbin/netstat -rn -f inet | grep -E 'default|0/1|128.0/1|ppp|UGHS|UHW' || true")

            section("ARP CACHE")
            out += self.runShell("/usr/sbin/arp -an | head -n 80")

            section("DNS")
            out += self.runShell("/usr/sbin/scutil --dns | head -n 160")

            section("APP RESULT")
            out += self.runShell("cat /tmp/sstp-gui.result 2>/dev/null || echo NONE")

            section("APP STATE")
            out += self.runShell("cat /tmp/sstp-gui.state 2>/dev/null || echo NONE")

            section("VPN LOG")
            out += self.runShell("tail -n 80 /tmp/sstp-gui.log 2>/dev/null || echo 'No log'")

            DispatchQueue.main.async {
                self.diagnostics = out
                self.diagnosticsRunning = false
            }
        }
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }

    func openLog() {
        if FileManager.default.fileExists(atPath: logFile) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logFile))
        }
    }
}

struct ComponentRow: View {
    let ok: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(ok ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

struct ContentView: View {
    @StateObject private var vpn = VPNModel()

    var body: some View {
        TabView {
            VStack(alignment: .leading, spacing: 15) {
                Group {
                    Text("SSTP Client GUI").font(.title2).bold()
                    HStack {
                        Circle().fill(vpn.statusColor).frame(width: 12, height: 12)
                        Text(vpn.statusText).bold()
                        Spacer()
                    }
                }

                Group {
                    HStack { Text("Server").frame(width: 80, alignment: .trailing); TextField("vpn.example.com", text: $vpn.server) }
                    HStack { Text("Login").frame(width: 80, alignment: .trailing); TextField("DOMAIN\\user", text: $vpn.username) }
                    HStack { Text("Password").frame(width: 80, alignment: .trailing); SecureField("VPN password", text: $vpn.password) }
                }

                Group {
                    Toggle("Full Tunnel (all IPv4 traffic through VPN)", isOn: $vpn.fullTunnel)
                    Toggle("Ignore certificate verification (--cert-warn)", isOn: $vpn.ignoreCertificate)
                    if !vpn.ignoreCertificate {
                        HStack {
                            Text(vpn.certificatePath.isEmpty ? "No certificate selected" : vpn.certificatePath)
                                .font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose certificate") { vpn.chooseCertificate() }
                        }
                    }
                    if !vpn.message.isEmpty { Text(vpn.message).font(.caption).textSelection(.enabled) }
                }

                HStack {
                    if vpn.canDisconnect { Button("Disconnect") { vpn.disconnect() } }
                    else { Button("Connect") { vpn.connect() }.disabled(!vpn.ready || vpn.status == .connecting) }
                    Button("Open log") { vpn.openLog() }
                    Spacer()
                }
            }
            .padding(20)
            .tabItem { Label("VPN", systemImage: "lock.shield") }

            VStack(alignment: .leading, spacing: 15) {
                Text("Setup").font(.title2).bold()
                Group {
                    ComponentRow(ok: vpn.brewOK, title: "Homebrew", detail: vpn.brewText)
                    ComponentRow(ok: vpn.sstpOK, title: "sstp-client", detail: vpn.sstpText)
                    ComponentRow(ok: vpn.pppdOK, title: "pppd", detail: vpn.pppdOK ? "/usr/sbin/pppd — OK" : "Not found")
                    ComponentRow(ok: vpn.optionsOK, title: "PPP options", detail: vpn.optionsOK ? "/etc/ppp/options — OK" : "Missing")
                }
                Divider()
                HStack {
                    Button("Check again") { vpn.checkComponents() }
                    if !vpn.ready { Button("Install components") { vpn.installComponents() } }
                    Button("Repair network") { vpn.repairNetworking() }
                    Spacer()
                }
                Text("Repair network removes routes and the SSTP process owned by this app. It does not intentionally terminate unrelated VPN clients.")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(20)
            .tabItem { Label("Setup", systemImage: "gearshape") }

            VStack(alignment: .leading, spacing: 12) {
                Text("Extended Diagnostics").font(.title2).bold()

                GroupBox("Target test") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Host / IP")
                                .frame(width: 70, alignment: .trailing)
                            TextField("10.0.0.10 or host.example.com", text: $vpn.diagnosticTarget)
                            Button("Use VPN server") { vpn.useVPNServerAsDiagnosticTarget() }
                        }
                        HStack {
                            Text("TCP port")
                                .frame(width: 70, alignment: .trailing)
                            TextField("443", text: $vpn.diagnosticPort)
                                .frame(width: 90)
                            Text("Target diagnostics include DNS, route, ping, TCP and traceroute.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                    .padding(4)
                }

                HStack {
                    Button(vpn.diagnosticsRunning ? "Running..." : "Run extended diagnostics") { vpn.runDiagnostics() }
                        .disabled(vpn.diagnosticsRunning)
                    Button("Copy") { vpn.copyDiagnostics() }.disabled(vpn.diagnostics.isEmpty)
                    Button("Repair network") { vpn.repairNetworking() }
                    Spacer()
                }

                Text("Traceroute uses up to 12 hops with one probe per hop. ICMP or traceroute may be filtered by a network even when TCP connectivity works.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ScrollView {
                    Text(vpn.diagnostics.isEmpty ? "Set an optional target and press Run extended diagnostics." : vpn.diagnostics)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
            .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 760, height: 600)
    }
}

@main
struct SSTPClientGUIApp: App {
    var body: some Scene {
        WindowGroup("SSTP Client GUI") { ContentView() }
    }
}
