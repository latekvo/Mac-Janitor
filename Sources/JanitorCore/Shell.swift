import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var ok: Bool { status == 0 }
}

public enum Shell {
    /// launchd starts jobs with a bare PATH that has none of these.
    public static let path = [
        "/opt/homebrew/bin", "/usr/local/bin", "\(Paths.home.path)/.docker/bin",
        "\(Paths.home.path)/Library/Android/sdk/platform-tools",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ].joined(separator: ":")

    /// Runs `args[0]` looked up on `path`. Exit status 124 means it was killed at `timeout`.
    @discardableResult
    public static func run(_ args: [String], cwd: String? = nil, timeout: TimeInterval = 120) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GH_PROMPT_DISABLED"] = "1"
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        // Drain both pipes concurrently; a full pipe buffer would block the child.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        do { try p.run() } catch {
            return ShellResult(status: 127, stdout: "", stderr: "\(args[0]): \(error.localizedDescription)")
        }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        p.waitUntilExit()
        timer.cancel()
        group.wait()
        let timedOut = p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGTERM
        return ShellResult(
            status: timedOut ? 124 : p.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: timedOut ? "timed out after \(Int(timeout))s" : String(decoding: errData, as: UTF8.self)
        )
    }
}
