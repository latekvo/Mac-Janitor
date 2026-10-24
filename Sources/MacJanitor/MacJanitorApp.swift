import AppKit
import SwiftUI

struct MacJanitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.live()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        if store.busy != nil {
            Image(systemName: "hourglass")
        } else if store.isLowDisk {
            // Menu-bar images render as templates; a non-template image keeps its red.
            Image(nsImage: Self.warning)
        } else {
            Image(systemName: "sparkles")
        }
    }

    private static let warning: NSImage = {
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Low disk space")!
            .withSymbolConfiguration(config)!
        image.isTemplate = false
        return image
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, even when run as a bare binary without the bundle's LSUIElement.
        NSApp.setActivationPolicy(.accessory)
    }
}
