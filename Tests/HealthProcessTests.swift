import Foundation

@main
struct HealthProcessTests {
    static func fixture(_ mode: String) throws {
        switch mode {
        case "exit-status":
            FileHandle.standardOutput.write(Data("normal\n".utf8))
            FileHandle.standardError.write(Data("warning\n".utf8))
            exit(7)
        case "large-output":
            for _ in 0..<128 {
                FileHandle.standardOutput.write(Data(repeating: 65, count: 2048))
                FileHandle.standardError.write(Data(repeating: 66, count: 2048))
            }
        case "ignore-term", "endless-output":
            signal(SIGTERM, SIG_IGN)
            FileHandle.standardOutput.write(Data("\(getpid())\n".utf8))
            while true {
                if mode == "endless-output" {
                    FileHandle.standardOutput.write(Data(repeating: 67, count: 8192))
                } else {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        case "term-exits-zero":
            signal(SIGTERM) { _ in exit(0) }
            while true { Thread.sleep(forTimeInterval: 0.1) }
        case "descendant-pipe":
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["10"]
            child.standardOutput = FileHandle.standardOutput
            child.standardError = FileHandle.standardError
            try child.run()
            FileHandle.standardOutput.write(Data("\(child.processIdentifier)\n".utf8))
        default:
            fatalError("Unknown fixture")
        }
    }

    static func main() throws {
        if CommandLine.arguments.count > 1 {
            try fixture(CommandLine.arguments[1])
            return
        }

        let runner = HealthProcessHarness()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let normal = runner.check(executable, ["exit-status"])
        precondition(normal.1 == 7 && normal.0 == "normal\nwarning\n", "Lost output or exit status")

        let large = runner.check(executable, ["large-output"])
        precondition(large.1 == 0 && large.0.utf8.count == 524_288, "Large output blocked or was lost")
        precondition(large.0.utf8.filter { $0 == 65 }.count == 262_144)
        precondition(large.0.utf8.filter { $0 == 66 }.count == 262_144)

        for mode in ["ignore-term", "endless-output", "term-exits-zero"] {
            let started = ProcessInfo.processInfo.systemUptime
            let result = runner.check(executable, [mode], timeout: 0.5)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            precondition(result.1 == 124 && elapsed < 2, "Timeout did not bound \(mode): \(elapsed)")
            precondition(result.0.utf8.count <= 1_048_576 + 30, "Output retention was unbounded")
            if mode != "term-exits-zero" {
                guard let line = result.0.split(separator: "\n").first, let pid = Int32(line) else {
                    fatalError("Missing fixture PID")
                }
                precondition(kill(pid, 0) == -1 && errno == ESRCH, "Timed-out child is still alive or unreaped")
            }
        }

        let started = ProcessInfo.processInfo.systemUptime
        let descendant = runner.check(executable, ["descendant-pipe"])
        guard let pid = Int32(descendant.0.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            fatalError("Missing descendant PID")
        }
        defer { kill(pid, SIGTERM) }
        precondition(descendant.1 == 0 && ProcessInfo.processInfo.systemUptime - started < 1,
                     "Waited for a descendant to close the pipe")

        let missing = runner.check("/nonexistent-sstp-health-test", [])
        precondition(missing.1 == -1, "Launch failure was not reported")
        print("Health process tests passed (output, exit status, timeout, forced termination, inherited pipe)")
    }
}
