import Foundation
import JanitorCore

/// Runs the bundled `janitor` CLI as a child process and decodes the Report it prints.
enum JanitorRunner {
    struct Outcome {
        var report: Report?
        /// What to show the user when the run did not cleanly produce a report.
        var problem: String?
        /// Another run, usually the scheduled one, held the lock.
        var locked = false
    }

    /// `Contents/MacOS/janitor` inside the bundle; beside the binary under `.build` too.
    static var executable: URL {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("janitor")
    }

    /// With `only`, a real run acts on just those action ids.
    static func run(dryRun: Bool, only: [String]? = nil) async -> Outcome {
        await Task.detached(priority: .userInitiated) { runBlocking(dryRun: dryRun, only: only) }.value
    }

    private static func runBlocking(dryRun: Bool, only: [String]?) -> Outcome {
        let exe = executable
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            return Outcome(problem: "janitor not found at \(Format.path(exe.path))")
        }
        var arguments = ["run", "--json"] + (dryRun ? ["--dry-run"] : [])
        var onlyFile: URL?
        defer { onlyFile.map { try? FileManager.default.removeItem(at: $0) } }
        if let only {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("janitor-only-\(UUID().uuidString).txt")
            do {
                try only.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            } catch {
                return Outcome(problem: "Could not write \(file.path): \(error.localizedDescription)")
            }
            onlyFile = file
            arguments += ["--only", file.path]
        }
        return launch(exe, arguments)
    }

    private static func launch(_ exe: URL, _ arguments: [String]) -> Outcome {
        let process = Process()
        process.executableURL = exe
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return Outcome(problem: "Could not start janitor: \(error.localizedDescription)")
        }

        // Drain both pipes at once so a full one cannot stall the child.
        var errData = Data()
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            stderrDone.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        stderrDone.wait()
        process.waitUntilExit()

        let report = try? JSONDecoder.janitor.decode(Report.self, from: outData)
        let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = process.terminationStatus

        if process.terminationReason == .uncaughtSignal {
            return Outcome(report: report, problem: "janitor was killed by signal \(status)")
        }
        if status != 0 && stderr.hasSuffix("another janitor run is in progress") {
            return Outcome(locked: true)
        }
        if status != 0 {
            // The CLI exits 1 when an action failed; those items already show in red.
            if !stderr.isEmpty { return Outcome(report: report, problem: stderr) }
            return Outcome(report: report, problem: report == nil ? "janitor exited with status \(status)" : nil)
        }
        if report == nil {
            return Outcome(problem: "janitor printed no readable report" + (stderr.isEmpty ? "" : ": " + stderr))
        }
        return Outcome(report: report)
    }
}
