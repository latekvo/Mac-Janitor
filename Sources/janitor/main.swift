import Foundation
import JanitorCore

let usage = """
usage: janitor run [--dry-run] [--json] [--scheduled]

  --dry-run    plan only; delete nothing and leave last-run.json alone
  --json       print the report as JSON instead of one line per action
  --scheduled  the launchd entry point: does nothing while paused
"""

let args = Array(CommandLine.arguments.dropFirst())
guard args.first == "run", args.dropFirst().allSatisfy({ ["--dry-run", "--json", "--scheduled"].contains($0) }) else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
let dryRun = args.contains("--dry-run")
let json = args.contains("--json")
let cfg = Config.load()

let stamp = ISO8601DateFormatter()
func logLine(_ s: String) {
    let line = "\(stamp.string(from: Date())) \(dryRun ? "[dry-run] " : "")\(s)\n"
    if !json { FileHandle.standardOutput.write(Data(line.utf8)) }
    // Dry runs come from people previewing; the log is the record of real runs.
    guard !dryRun else { return }
    try? FileManager.default.createDirectory(at: Paths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let h = FileHandle(forWritingAtPath: Paths.log.path) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        h.closeFile()
    } else {
        try? Data(line.utf8).write(to: Paths.log)
    }
}

if args.contains("--scheduled") && cfg.paused {
    logLine("paused; skipping scheduled run")
    exit(0)
}

do {
    logLine("run started")
    let report = try Janitor.run(cfg, dryRun: dryRun, log: logLine)
    let freed = ByteCountFormatter.string(fromByteCount: report.freeBytesAfter - report.freeBytesBefore, countStyle: .file)
    let planned = ByteCountFormatter.string(fromByteCount: report.actions.reduce(0) { $0 + $1.bytes }, countStyle: .file)
    logLine("run finished: \(report.actions.count) actions (\(planned)), free space change \(freed)")
    if json {
        FileHandle.standardOutput.write(try JSONEncoder.janitor.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    exit(report.actions.contains { $0.status == .failed } ? 1 : 0)
} catch {
    logLine("run failed: \(error)")
    FileHandle.standardError.write(Data("janitor: \(error)\n".utf8))
    exit(1)
}
