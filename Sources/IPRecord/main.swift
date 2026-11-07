import AppKit
import SwiftUI
import ServiceManagement
import IPRecordCore

@MainActor final class GateDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!; var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "IP Record 原生验收")
        let menu = NSMenu(); menu.addItem(withTitle: "原生验证窗口", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "退出 IP Record", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.menu = menu
        Task {
            let directory = Bundle.main.resourceURL!.appendingPathComponent("ip2region")
            let geo = GeoResolver(directory: directory)
            let health = await geo.databaseHealth()
            let a = await geo.lookup(IPAddress("113.118.113.77")!), b = await geo.lookup(IPAddress("2604:a840:3::a04d")!)
            let snapshot = await Task.detached { NetworkSnapshotter().readSnapshot(path: "gate") }.value
            async let v4 = PublicIPProbe().probe(.v4); async let v6 = PublicIPProbe().probe(.v6)
            let results = await [v4, v6]
            var registration = "not_attempted"
            if CommandLine.arguments.contains("--login-gate") {
                do { try SMAppService.mainApp.register(); registration = "accepted" } catch { registration = "failed: " + error.localizedDescription }
            }
            let report: [String: String] = ["bundle": Bundle.main.bundleIdentifier ?? "missing", "resources": "\(health)", "C_v4": a.status, "C_v6": b.status, "interfaces": "\(snapshot.addresses.count)", "DNS_groups": "\(snapshot.dns.count)", "proxy_read": snapshot.proxy.status.rawValue, "v4_probe": results[0].status + ":" + (results[0].error ?? "ok"), "v6_probe": results[1].status + ":" + (results[1].error ?? "ok"), "login_status": "\(SMAppService.mainApp.status.rawValue)", "registration": registration]
            let output = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/IPRecord-gates.json")
            try? jsonEncoder().encode(report).write(to: output, options: .atomic)
        }
    }
    @objc func showWindow() { if window == nil { window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240), styleMask: [.titled,.closable], backing: .buffered, defer: false); window?.isReleasedWhenClosed = false; window?.title = "IP Record · 原生验证"; window?.contentView = NSHostingView(rootView: Text("原生菜单栏和捆绑资源验证").padding()); window?.center() }; window?.makeKeyAndOrderFront(nil); NSApp.activate() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
let app = NSApplication.shared
let delegate = GateDelegate()
app.delegate = delegate
app.run()
