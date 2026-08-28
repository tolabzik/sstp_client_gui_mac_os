import SwiftUI
import AppKit
import Foundation
import UserNotifications

// MARK: - Shared app metadata

enum AppLinks {
    static let repository = "https://github.com/tolabzik/sstp_client_gui_mac_os"
    static let releases = repository + "/releases"
    static let latestReleaseAPI = "https://api.github.com/repos/tolabzik/sstp_client_gui_mac_os/releases/latest"
    static let bundleIdentifier = "io.github.tolabzik.sstp-client-gui"
}

enum AppNotifications {
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "notificationsEnabled")
    }

    static func requestAuthorization() {
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(_ title: String, _ body: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Profiles

struct VPNProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var server: String
    var username: String
    var ignoreCertificate: Bool
    var certificatePath: String
    var fullTunnel: Bool
}

final class VPNProfileStore: ObservableObject {
    @Published var profiles: [VPNProfile] = []
    @Published var selectedID: String = ""
    @Published var draftName: String = ""

    private let profilesKey = "vpnProfiles.v1"
    private let selectedKey = "vpnProfiles.selected"

    init() {
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([VPNProfile].self, from: data) {
            profiles = decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        selectedID = UserDefaults.standard.string(forKey: selectedKey) ?? ""
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        UserDefaults.standard.set(selectedID, forKey: selectedKey)
    }

    func applySelected(to vpn: VPNModel) {
        guard let id = UUID(uuidString: selectedID),
              let profile = profiles.first(where: { $0.id == id }) else { return }

        vpn.server = profile.server
        vpn.username = profile.username
        vpn.ignoreCertificate = profile.ignoreCertificate
        vpn.certificatePath = profile.certificatePath
        vpn.fullTunnel = profile.fullTunnel
        vpn.password = KeychainStore.load(account: profile.username)
        draftName = profile.name

        let defaults = UserDefaults.standard
        defaults.set(profile.server, forKey: "server")
        defaults.set(profile.username, forKey: "username")
        defaults.set(profile.ignoreCertificate, forKey: "ignoreCertificate")
        defaults.set(profile.certificatePath, forKey: "certificatePath")
        defaults.set(profile.fullTunnel, forKey: "fullTunnel")
        persist()
    }

    func saveCurrent(from vpn: VPNModel) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? (vpn.server.isEmpty ? "VPN Profile" : vpn.server) : trimmed

        if let id = UUID(uuidString: selectedID),
           let index = profiles.firstIndex(where: { $0.id == id }) {
            profiles[index] = VPNProfile(
                id: id,
                name: name,
                server: vpn.server,
                username: vpn.username,
                ignoreCertificate: vpn.ignoreCertificate,
                certificatePath: vpn.certificatePath,
                fullTunnel: vpn.fullTunnel
            )
        } else {
            let profile = VPNProfile(
                id: UUID(),
                name: name,
                server: vpn.server,
                username: vpn.username,
                ignoreCertificate: vpn.ignoreCertificate,
                certificatePath: vpn.certificatePath,
                fullTunnel: vpn.fullTunnel
            )
            profiles.append(profile)
            selectedID = profile.id.uuidString
        }

        if !vpn.username.isEmpty && !vpn.password.isEmpty {
            KeychainStore.save(account: vpn.username, password: vpn.password)
        }

        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    func deleteSelected() {
        guard let id = UUID(uuidString: selectedID) else { return }
        profiles.removeAll { $0.id == id }
        selectedID = ""
        draftName = ""
        persist()
    }
}

struct ProfilesPanel: View {
    @ObservedObject var store: VPNProfileStore
    @ObservedObject var vpn: VPNModel

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Saved profiles", systemImage: "person.crop.rectangle.stack.fill")
                    .font(.headline)

                HStack(spacing: 10) {
                    Picker("Profile", selection: $store.selectedID) {
                        Text("Current / unsaved").tag("")
                        ForEach(store.profiles) { profile in
                            Text(profile.name).tag(profile.id.uuidString)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 220)
                    .onChange(of: store.selectedID) { _ in
                        store.applySelected(to: vpn)
                    }

                    TextField("Profile name", text: $store.draftName)

                    Button("Save") { store.saveCurrent(from: vpn) }
                        .buttonStyle(.borderedProminent)

                    Button("Delete") { store.deleteSelected() }
                        .disabled(store.selectedID.isEmpty)
                }

                Text("Server, login, certificate mode and tunnel mode are stored in the profile. Passwords stay in macOS Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Update manager

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }

    let tag_name: String
    let html_url: String
    let body: String?
    let assets: [Asset]
}

final class UpdateManager: ObservableObject {
    @Published var checking = false
    @Published var installing = false
    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var releaseNotes = ""
    @Published var statusText = "Not checked yet"
    @Published var autoCheckUpdates: Bool
    @Published var notificationsEnabled: Bool

    private var zipURL: String = ""
    private var checksumURL: String = ""
    private var releaseURL: String = AppLinks.releases

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var architecture: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "autoCheckUpdates") == nil {
            defaults.set(true, forKey: "autoCheckUpdates")
        }
        autoCheckUpdates = defaults.bool(forKey: "autoCheckUpdates")
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")

        if notificationsEnabled {
            AppNotifications.requestAuthorization()
        }

        if autoCheckUpdates {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.checkForUpdates(silent: true)
            }
        }
    }

    func setAutoCheck(_ value: Bool) {
        autoCheckUpdates = value
        UserDefaults.standard.set(value, forKey: "autoCheckUpdates")
    }

    func setNotifications(_ value: Bool) {
        notificationsEnabled = value
        UserDefaults.standard.set(value, forKey: "notificationsEnabled")
        if value { AppNotifications.requestAuthorization() }
    }

    private func numericVersion(_ value: String) -> [Int] {
        let clean = value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: "-", maxSplits: 1)
            .first.map(String.init) ?? value
        return clean.split(separator: ".").map { Int($0) ?? 0 }
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        var left = numericVersion(candidate)
        var right = numericVersion(current)
        let count = max(left.count, right.count)
        while left.count < count { left.append(0) }
        while right.count < count { right.append(0) }
        for index in 0..<count {
            if left[index] != right[index] { return left[index] > right[index] }
        }
        return false
    }

    func checkForUpdates(silent: Bool = false) {
        guard !checking else { return }
        guard let url = URL(string: AppLinks.latestReleaseAPI) else { return }

        checking = true
        if !silent { statusText = "Checking GitHub Releases…" }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("SSTP-Client-GUI/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.checking = false

                if let error {
                    if !silent { self.statusText = "Update check failed: \(error.localizedDescription)" }
                    return
                }

                guard let http = response as? HTTPURLResponse else {
                    if !silent { self.statusText = "GitHub did not return a valid response" }
                    return
                }

                if http.statusCode == 404 {
                    self.statusText = "No published releases yet"
                    return
                }

                guard (200...299).contains(http.statusCode), let data,
                      let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                    if !silent { self.statusText = "Could not read the latest GitHub release" }
                    return
                }

                let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                self.latestVersion = version
                self.releaseNotes = release.body ?? ""
                self.releaseURL = release.html_url
                self.zipURL = release.assets.first(where: {
                    $0.name.hasSuffix(".zip") && !$0.name.hasSuffix(".zip.sha256")
                })?.browser_download_url ?? ""
                self.checksumURL = release.assets.first(where: { $0.name.hasSuffix(".zip.sha256") })?.browser_download_url ?? ""

                self.updateAvailable = self.isNewer(version, than: self.currentVersion)
                if self.updateAvailable {
                    self.statusText = "Version \(version) is available"
                    AppNotifications.send("SSTP Client GUI update", "Version \(version) is ready to install.")
                } else {
                    self.statusText = "You are up to date — v\(self.currentVersion)"
                }
            }
        }.resume()
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func appleEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runAdmin(_ command: String) -> String? {
        let source = "do shell script \"" + appleEscape(command) + "\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return "Could not create administrator request" }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error?.description
    }

    func installUpdate() {
        guard updateAvailable, !installing else { return }
        guard !latestVersion.isEmpty, !zipURL.isEmpty, !checksumURL.isEmpty else {
            statusText = "This release does not contain both the ZIP and SHA-256 asset"
            return
        }

        let allowedPrefix = "https://github.com/tolabzik/sstp_client_gui_mac_os/releases/download/"
        guard zipURL.hasPrefix(allowedPrefix), checksumURL.hasPrefix(allowedPrefix) else {
            statusText = "Refusing an update asset outside the official GitHub repository"
            return
        }

        let scriptPath = "/tmp/sstp-gui-self-update.sh"
        let updaterScript = """
        #!/bin/bash
        set -euo pipefail

        ZIP_URL="$1"
        SHA_URL="$2"
        EXPECTED_VERSION="$3"
        TARGET="$4"
        BUNDLE_ID="$5"
        WORK="$(/usr/bin/mktemp -d /tmp/sstp-gui-update.XXXXXX)"
        trap '/bin/rm -rf "$WORK"' EXIT

        ZIP="$WORK/update.zip"
        SHA="$WORK/update.zip.sha256"

        /usr/bin/curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$ZIP_URL" -o "$ZIP"
        /usr/bin/curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$SHA_URL" -o "$SHA"

        EXPECTED_HASH="$(/usr/bin/awk '{print $1; exit}' "$SHA")"
        ACTUAL_HASH="$(/usr/bin/shasum -a 256 "$ZIP" | /usr/bin/awk '{print $1}')"
        [ -n "$EXPECTED_HASH" ] && [ "$EXPECTED_HASH" = "$ACTUAL_HASH" ]

        /usr/bin/ditto -x -k "$ZIP" "$WORK/unpacked"
        APP="$(/usr/bin/find "$WORK/unpacked" -maxdepth 4 -type d -name 'SSTP Client GUI.app' -print | /usr/bin/head -n 1)"
        [ -n "$APP" ] && [ -d "$APP" ]

        /usr/bin/codesign --verify --deep --strict "$APP"
        FOUND_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
        FOUND_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
        [ "$FOUND_VERSION" = "$EXPECTED_VERSION" ]
        [ "$FOUND_ID" = "$BUNDLE_ID" ]

        NEW="${TARGET}.new"
        /bin/rm -rf "$NEW"
        /usr/bin/ditto "$APP" "$NEW"
        /usr/bin/codesign --verify --deep --strict "$NEW"

        /bin/rm -rf "$TARGET"
        /bin/mv "$NEW" "$TARGET"
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" >/dev/null 2>&1 || true
        /usr/bin/codesign --verify --deep --strict "$TARGET"
        """

        do {
            try updaterScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            chmod(scriptPath, 0o700)
        } catch {
            statusText = "Could not create updater: \(error.localizedDescription)"
            return
        }

        installing = true
        statusText = "Downloading and verifying v\(latestVersion)…"
        let target = "/Applications/SSTP Client GUI.app"
        let command = "/bin/bash \(shellQuote(scriptPath)) \(shellQuote(zipURL)) \(shellQuote(checksumURL)) \(shellQuote(latestVersion)) \(shellQuote(target)) \(shellQuote(AppLinks.bundleIdentifier))"

        DispatchQueue.global(qos: .userInitiated).async {
            let error = self.runAdmin(command)
            DispatchQueue.main.async {
                self.installing = false
                if let error {
                    self.statusText = "Update failed: \(error)"
                    return
                }

                self.statusText = "Updated to v\(self.latestVersion). Restarting…"
                AppNotifications.send("SSTP Client GUI updated", "Version \(self.latestVersion) was installed successfully.")

                let restart = Process()
                restart.executableURL = URL(fileURLWithPath: "/bin/sh")
                restart.arguments = ["-c", "sleep 1; /usr/bin/open -n \(self.shellQuote(target)) >/dev/null 2>&1"]
                restart.standardOutput = FileHandle.nullDevice
                restart.standardError = FileHandle.nullDevice
                try? restart.run()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func openGitHub() {
        if let url = URL(string: AppLinks.repository) { NSWorkspace.shared.open(url) }
    }

    func openLatestRelease() {
        if let url = URL(string: releaseURL) { NSWorkspace.shared.open(url) }
    }

    func reportIssue() {
        var components = URLComponents(string: AppLinks.repository + "/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Issue in SSTP Client GUI v\(currentVersion)"),
            URLQueryItem(name: "body", value: "Version: \(currentVersion) (build \(currentBuild))\nArchitecture: \(architecture)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n\nDescribe the problem:\n")
        ]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Quick health summary

struct HealthItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let ok: Bool
    let warning: Bool
}

final class QuickHealthModel: ObservableObject {
    @Published var items: [HealthItem] = []
    @Published var running = false
    @Published var headline = "Not checked"

    private func run(_ executable: String, _ args: [String]) -> (String, Int32) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (output, process.terminationStatus)
        } catch {
            return (error.localizedDescription, -1)
        }
    }

    func refresh(vpn: VPNModel) {
        guard !running else { return }
        running = true

        let server = vpn.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let ready = vpn.ready
        let state = vpn.status
        let fullTunnel = vpn.fullTunnel
        let conflict = vpn.networkWarning

        DispatchQueue.global(qos: .utility).async {
            var result: [HealthItem] = []

            result.append(HealthItem(
                title: "Components",
                detail: ready ? "Homebrew, sstpc, pppd and PPP options are ready" : "One or more required components are missing",
                ok: ready,
                warning: !ready
            ))

            let pppOutput = self.run("/sbin/ifconfig", ["-l"]).0
            let ppps = pppOutput.split(separator: " ").filter { $0.hasPrefix("ppp") }.map(String.init)
            let pppOK = state == .connected ? !ppps.isEmpty : true
            result.append(HealthItem(
                title: "SSTP / PPP",
                detail: state == .connected ? (ppps.isEmpty ? "Connected state reported but PPP was not found" : "PPP interfaces: \(ppps.joined(separator: ", "))") : "VPN is \(state == .connecting ? "connecting" : "not connected")",
                ok: pppOK,
                warning: state == .connecting
            ))

            let routeOutput = self.run("/sbin/route", ["-n", "get", "1.1.1.1"]).0
            let routeIF = routeOutput.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { $0.hasPrefix("interface:") })?
                .replacingOccurrences(of: "interface:", with: "")
                .trimmingCharacters(in: .whitespaces) ?? "unknown"
            let routeOK = !fullTunnel || state != .connected || routeIF.hasPrefix("ppp")
            result.append(HealthItem(
                title: "Internet route",
                detail: "1.1.1.1 → \(routeIF)" + (fullTunnel && state == .connected ? " (Full Tunnel expected)" : ""),
                ok: routeOK,
                warning: !routeOK
            ))

            let internetStatus = self.run("/usr/bin/nc", ["-z", "-G", "3", "1.1.1.1", "443"]).1
            result.append(HealthItem(
                title: "Internet",
                detail: internetStatus == 0 ? "TCP 1.1.1.1:443 reachable" : "TCP 1.1.1.1:443 failed",
                ok: internetStatus == 0,
                warning: internetStatus != 0
            ))

            let dnsStatus = self.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", "github.com"])
            let dnsOK = dnsStatus.1 == 0 && dnsStatus.0.contains("ip_address")
            result.append(HealthItem(
                title: "DNS",
                detail: dnsOK ? "github.com resolves" : "DNS resolution test failed",
                ok: dnsOK,
                warning: !dnsOK
            ))

            if !server.isEmpty {
                let serverStatus = self.run("/usr/bin/nc", ["-z", "-G", "3", server, "443"]).1
                result.append(HealthItem(
                    title: "SSTP server",
                    detail: serverStatus == 0 ? "\(server):443 reachable" : "\(server):443 is not reachable",
                    ok: serverStatus == 0,
                    warning: serverStatus != 0
                ))
            }

            result.append(HealthItem(
                title: "VPN conflicts",
                detail: conflict ? "Other VPN/default-route leftovers require review" : "No conflicting Full Tunnel routes detected",
                ok: !conflict,
                warning: conflict
            ))

            let failures = result.filter { !$0.ok }.count
            let headline = failures == 0 ? "All checks passed" : "\(failures) check\(failures == 1 ? "" : "s") need attention"

            DispatchQueue.main.async {
                self.items = result
                self.headline = headline
                self.running = false
            }
        }
    }
}

struct NetworkHealthPanel: View {
    @ObservedObject var vpn: VPNModel
    @StateObject private var health = QuickHealthModel()
    private let refreshTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Label("Network health", systemImage: "waveform.path.ecg.rectangle")
                        .font(.headline)
                    Spacer()
                    Text(health.headline)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(health.running ? "Checking…" : "Refresh") { health.refresh(vpn: vpn) }
                        .disabled(health.running)
                }

                if health.items.isEmpty {
                    Text("Quick checks for components, PPP, routes, Internet, DNS, SSTP server and VPN conflicts.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(health.items) { item in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: item.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(item.ok ? .green : (item.warning ? .orange : .red))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).fontWeight(.semibold)
                                Text(item.detail).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .onAppear { health.refresh(vpn: vpn) }
        .onReceive(refreshTimer) { _ in health.refresh(vpn: vpn) }
    }
}

// MARK: - Diagnostics helpers

extension VPNModel {
    func saveDiagnostics() {
        guard !diagnostics.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SSTP-Client-GUI-Diagnostics-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")) .txt"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? diagnostics.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Menu bar

final class StatusBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private weak var vpn: VPNModel?
    private var timer: Timer?
    private var lastStatus: VPNStatus?

    func bind(_ vpn: VPNModel) {
        self.vpn = vpn
        if statusItem == nil { setup() }
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "SSTP Client GUI")
            button.image?.isTemplate = true
        }
    }

    private func refresh() {
        guard let vpn, let statusItem else { return }
        let menu = NSMenu()

        let status = NSMenuItem(title: "Status: \(vpn.statusText)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show SSTP Client GUI", action: #selector(showApp), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let toggle = NSMenuItem(title: vpn.canDisconnect ? "Disconnect" : "Connect", action: #selector(toggleVPN), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = vpn.canDisconnect || vpn.ready
        menu.addItem(toggle)

        let repair = NSMenuItem(title: "Repair this app", action: #selector(repairVPN), keyEquivalent: "")
        repair.target = self
        menu.addItem(repair)

        menu.addItem(.separator())
        let github = NSMenuItem(title: "Open GitHub", action: #selector(openGitHub), keyEquivalent: "")
        github.target = self
        menu.addItem(github)

        statusItem.menu = menu
        statusItem.button?.toolTip = "SSTP Client GUI — \(vpn.statusText)"
        statusItem.button?.image = NSImage(
            systemSymbolName: vpn.connected ? "lock.shield.fill" : "lock.shield",
            accessibilityDescription: vpn.statusText
        )
        statusItem.button?.image?.isTemplate = true

        if let previous = lastStatus, previous != vpn.status {
            if vpn.status == .connected {
                AppNotifications.send("VPN connected", vpn.message.isEmpty ? "SSTP tunnel is active." : vpn.message)
            } else if previous == .connected && vpn.status == .disconnected {
                AppNotifications.send("VPN disconnected", "SSTP tunnel is no longer active.")
            } else if vpn.status == .error {
                AppNotifications.send("VPN needs attention", vpn.message)
            }
        }
        lastStatus = vpn.status
    }

    @objc private func showApp() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleVPN() {
        guard let vpn else { return }
        vpn.canDisconnect ? vpn.disconnect() : vpn.connect()
    }

    @objc private func repairVPN() {
        vpn?.repairNetworking()
    }

    @objc private func openGitHub() {
        if let url = URL(string: AppLinks.repository) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - About / Updates UI

struct AboutView: View {
    @ObservedObject var updater: UpdateManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AppHeader(title: "About SSTP Client GUI", subtitle: "Version, updates and project links", icon: "info.circle.fill")

                AppCard {
                    HStack(alignment: .center, spacing: 18) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 54, weight: .semibold))
                            .foregroundStyle(.blue, .cyan)
                            .frame(width: 76)

                        VStack(alignment: .leading, spacing: 5) {
                            Text("SSTP Client GUI").font(.title2).bold()
                            Text("v\(updater.currentVersion) · build \(updater.currentBuild)")
                                .font(.headline)
                            Text("macOS \(updater.architecture) · Universal arm64 + x86_64 distribution")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(AppLinks.repository)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                    }
                }

                AppCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Updates", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                                .font(.headline)
                            Spacer()
                            if updater.updateAvailable {
                                StatusPill(color: .orange, text: "v\(updater.latestVersion) available")
                            } else {
                                StatusPill(color: .green, text: "v\(updater.currentVersion)")
                            }
                        }

                        Text(updater.statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)

                        Toggle("Automatically check GitHub Releases", isOn: Binding(
                            get: { updater.autoCheckUpdates },
                            set: { updater.setAutoCheck($0) }
                        ))

                        Toggle("macOS notifications", isOn: Binding(
                            get: { updater.notificationsEnabled },
                            set: { updater.setNotifications($0) }
                        ))

                        HStack {
                            Button(updater.checking ? "Checking…" : "Check for updates") { updater.checkForUpdates() }
                                .disabled(updater.checking || updater.installing)

                            if updater.updateAvailable {
                                Button(updater.installing ? "Installing…" : "Install v\(updater.latestVersion)") { updater.installUpdate() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(updater.installing)
                            }

                            Button("Open latest release") { updater.openLatestRelease() }
                            Spacer()
                        }

                        if !updater.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Divider()
                            Text("Release notes").fontWeight(.semibold)
                            ScrollView {
                                Text(updater.releaseNotes)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 150)
                        }
                    }
                }

                AppCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Project", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.headline)
                        Text("Open source SSTP client GUI for macOS. Releases contain a single Universal application for Apple Silicon and Intel Macs.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            Button("Open GitHub") { updater.openGitHub() }
                            Button("Report a problem") { updater.reportIssue() }
                            Spacer()
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}
