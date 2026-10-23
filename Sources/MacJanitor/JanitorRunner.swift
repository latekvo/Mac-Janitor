import Foundation
import JanitorCore

/// Runs the bundled `janitor` CLI as a child process and decodes the Report it prints.
enum JanitorRunner {
    struct Outcome {
        var report: Report?
        /// What to show the user when the run did not cleanly produce a report.
        var problem: String?
    }

    /// `Contents/MacOS/janitor` inside the bundle; beside the binary under `.build` too.
    static var executable: URL {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("janitor")
    }

    static func run(dryRun: Bool) async -> Outcome {
        await Task.detached(priority: .userInitiated) { runBlocking(dryRun: dryRun) }.value
    }

    private static func runBlocking(dryRun: Bool) -> Outcome {
        let exe = executable
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            return Outcome(problem: "janitor not found at \(exe.path). Rebuild with install/build-app.sh.")
        }
        let process = Process()
        process.executableURL = exe
        process.arguments = ["run", "--json"] + (dryRun ? ["--dry-run"] : [])
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
            return Outcome(report: report, problem: "janitor was killed by signal \(status).")
        }
        if status != 0 {
            // The CLI exits 1 when any action failed; those rows already show in red.
            let failed = report?.count(.failed) ?? 0
            let problem = !stderr.isEmpty ? stderr
                : failed > 0 ? "\(failed) action\(failed == 1 ? "" : "s") failed; see the list below."
                : "janitor exited with status \(status)."
            return Outcome(report: report, problem: problem)
        }
        if report == nil {
            return Outcome(problem: "janitor printed no readable report." + (stderr.isEmpty ? "" : "\n" + stderr))
        }
        return Outcome(report: report)
    }
}
