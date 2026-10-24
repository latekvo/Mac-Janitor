import Foundation
import JanitorCore

let usage = """
usage: janitor run [--dry-run] [--json] [--scheduled] [--only <file>]

  --dry-run      plan only; delete nothing and leave last-run.json alone
  --json         print the report as JSON instead of one line per action
  --scheduled    the launchd entry point: runs only when unpaused and either
                 intervalHours have passed or free space is below lowDiskGB
  --only <file>  act only on these action ids (one per line), if still planned
"""

var args = Array(CommandLine.arguments.dropFirst())
var onlyFile: String?
if let i = args.firstIndex(of: "--only"), i + 1 < args.count {
    onlyFile = args[i + 1]
    args.removeSubrange(i...i + 1)
}
guard args.first == "run", args.dropFirst().allSatisfy({ ["--dry-run", "--json", "--scheduled"].contains($0) }) else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
let dryRun = args.contains("--dry-run")
let json = args.contains("--json")
let cfg: Config
do {
    cfg = try Config.load()
} catch {
    FileHandle.standardError.write(Data("janitor: \(error)\n".utf8))
    exit(1)
}

let stamp = ISO8601DateFormatter()
func logLine(_ s: String) {
    let line = "\(stamp.string(from: Date())) \(dryRun ? "[dry-run] " : "")\(s)\n"
    if !json { FileHandle.standardOutput.write(Data(line.utf8)) }
    // Dry runs come from people previewing; the log is the record of real runs.
    guard !dryRun else { return }
    try? FileManager.default.createDirectory(at: Paths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let size = try? FileManager.default.attributesOfItem(atPath: Paths.log.path)[.size] as? Int, size > 5_000_000 {
        let old = Paths.log.path + ".1"
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.moveItem(atPath: Paths.log.path, toPath: old)
    }
    if let h = FileHandle(forWritingAtPath: Paths.log.path) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        h.closeFile()
    } else {
        try? Data(line.utf8).write(to: Paths.log)
    }
}

// launchd wakes the job hourly; most wakes end here without a log line.
if args.contains("--scheduled"),
   Janitor.scheduledSkipReason(cfg, lastStart: Report.load()?.startedAt, freeBytes: freeDiskBytes()) != nil {
    exit(0)
}

var only: Set<String>?
if let onlyFile {
    guard let text = try? String(contentsOfFile: onlyFile, encoding: .utf8) else {
        FileHandle.standardError.write(Data("janitor: cannot read \(onlyFile)\n".utf8))
        exit(2)
    }
    only = Set(text.split(separator: "\n").map(String.init))
}

do {
    logLine("run started")
    let report = try Janitor.run(cfg, dryRun: dryRun, only: only, log: logLine)
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
