import Foundation

// `MacJanitor --snapshot <dir>` renders fixture states to PNGs and exits.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    MainActor.assumeIsolated { Snapshot.render(to: URL(fileURLWithPath: args[i + 1])) }
    exit(0)
}
MacJanitorApp.main()
