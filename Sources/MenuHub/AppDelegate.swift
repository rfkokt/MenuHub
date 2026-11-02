import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private var ramItem: NSStatusItem!
    private var netItem: NSStatusItem!
    private var vpnItem: NSStatusItem!
    private var diskItem: NSStatusItem!
    private let popover = NSPopover()
    private let vpnMenu = NSMenu()
    private let diskMenu = NSMenu()
    private var diskMenuOpen = false
    private var macSpeedItem: NSMenuItem?
    private var extSpeedItem: NSMenuItem?
    private weak var popoverOwner: NSStatusItem?

    private let hub = Hub.shared
    private let storage = StorageModel.shared
    private let vpn = VPNModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // New items appear to the left of older ones, so create them right-to-left.
        ramItem = makeItem("ram", action: #selector(clickRAM))
        netItem = makeItem("network", action: #selector(clickNetwork))
        vpnItem = makeItem("vpn", action: nil)
        diskItem = makeItem("disk", action: nil)

        vpnMenu.delegate = self
        vpnItem.menu = vpnMenu
        diskMenu.delegate = self
        diskItem.menu = diskMenu

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        hub.onSample = { [weak self] in self?.drawNetwork(); self?.drawRAM(); self?.updateDiskSpeeds() }
        storage.onChange = { [weak self] in
            guard let self else { return }
            self.drawDisk()
            if self.diskMenuOpen { self.buildDiskMenu() }
        }
        vpn.onChange = { [weak self] in self?.drawVPN() }
        Modules.shared.onChange = { [weak self] in self?.applyVisibility() }

        applyVisibility()
        URLCommands.shared.start()
        hub.start()
        storage.start()
        vpn.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(URLCommands.shared.handle)
    }

    private func makeItem(_ name: String, action: Selector?) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "menuhub.\(name)"
        if let action {
            item.button?.target = self
            item.button?.action = action
        }
        return item
    }

    private func applyVisibility() {
        let m = Modules.shared
        netItem.isVisible = m.network
        ramItem.isVisible = m.ram
        diskItem.isVisible = m.disk
        vpnItem.isVisible = m.vpn && vpn.anyInstalled
    }

    // MARK: Drawing

    /// Two small lines of text stacked, like Stats. Template so it follows the menu bar color.
    private func twoLineImage(_ top: String, _ bottom: String, width: CGFloat) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: para]
        let img = NSImage(size: NSSize(width: width, height: 22), flipped: false) { rect in
            (top as NSString).draw(in: NSRect(x: 0, y: 10.5, width: rect.width, height: 11), withAttributes: attrs)
            (bottom as NSString).draw(in: NSRect(x: 0, y: 0.5, width: rect.width, height: 11), withAttributes: attrs)
            return true
        }
        img.isTemplate = true
        return img
    }

    private func drawNetwork() {
        guard netItem.isVisible else { return }
        netItem.button?.image = twoLineImage("↑ " + Fmt.speed(hub.up), "↓ " + Fmt.speed(hub.down), width: 62)
    }

    private func drawRAM() {
        guard ramItem.isVisible else { return }
        ramItem.button?.image = twoLineImage("RAM", "\(Int((hub.mem.fraction * 100).rounded()))%", width: 26)
    }

    private func symbol(_ name: String, color: NSColor?) -> NSImage? {
        guard var img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        if let color {
            img = img.withSymbolConfiguration(.init(paletteColors: [color])) ?? img
            img.isTemplate = false
        } else {
            img.isTemplate = true
        }
        return img
    }

    private func drawDisk() {
        let free = storage.mac.free / 1_073_741_824
        // Configured drives that are mounted get their free space in the title too.
        let title = ([Fmt.gib(storage.mac.free)] + storage.volumes.filter { $0.configured != nil }.map { Fmt.gib($0.free) })
            .joined(separator: " · ")

        let image: NSImage?
        if storage.hasProblem {
            image = symbol("externaldrive.badge.exclamationmark", color: .systemRed)
        } else if free < 15 {
            image = symbol("internaldrive.fill", color: .systemRed)
        } else if free < 30 {
            image = symbol("internaldrive.fill", color: .systemOrange)
        } else {
            image = symbol("internaldrive", color: nil)
        }
        diskItem.button?.image = image
        diskItem.button?.imagePosition = .imageLeading
        diskItem.button?.title = " " + title
        diskItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    private func drawVPN() {
        vpnItem.isVisible = Modules.shared.vpn && vpn.anyInstalled
        let color: NSColor = (vpn.fortiUp || vpn.gpUp) ? .systemGreen : vpn.warning ? .systemOrange : .systemGray
        vpnItem.button?.image = symbol("network", color: color)
    }

    // MARK: Popovers

    @objc private func clickNetwork() {
        toggle(netItem, NetworkView()) {
            self.hub.watchNetProcesses = true
            self.hub.refreshLocalIP()
            self.hub.refreshPublicIP()
        }
    }

    @objc private func clickRAM() {
        toggle(ramItem, RAMView()) { self.hub.watchMemProcesses = true }
    }

    private func toggle<V: View>(_ item: NSStatusItem, _ view: V, onOpen: @escaping () -> Void) {
        let wasOwner = popoverOwner === item && popover.isShown
        if popover.isShown { popover.performClose(nil) }
        guard !wasOwner, let button = item.button else { return }
        popover.contentViewController = NSHostingController(rootView: view)
        popoverOwner = item
        onOpen()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        // Drop the view tree and stop process sampling while nothing is shown.
        popover.contentViewController = nil
        popoverOwner = nil
        hub.watchNetProcesses = false
        hub.watchMemProcesses = false
    }

    // MARK: Menus

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === diskMenu else { return }
        diskMenuOpen = true
        storage.refreshDetails()
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === diskMenu { diskMenuOpen = false }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === diskMenu { buildDiskMenu() } else { buildVPNMenu() }
    }

    private func add(_ title: String, to m: NSMenu, symbol name: String? = nil, color: NSColor? = nil,
                     font: NSFont? = nil, _ action: (() -> Void)? = nil) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        var attrs: [NSAttributedString.Key: Any] = [:]
        if let color { attrs[.foregroundColor] = color }
        if let font { attrs[.font] = font }
        if !attrs.isEmpty { item.attributedTitle = NSAttributedString(string: title, attributes: attrs) }
        if let name { item.image = symbol(name, color: color) }
        m.addItem(item)
        return item
    }

    private func speedTitle(_ read: Double, _ write: Double) -> String {
        "Baca \(Fmt.speed(read))  ·  Tulis \(Fmt.speed(write))"
    }

    /// Refreshes only the throughput rows, so an open menu stays live without rebuilding.
    private func updateDiskSpeeds() {
        guard diskMenuOpen else { return }
        macSpeedItem?.title = speedTitle(hub.intRead, hub.intWrite)
        extSpeedItem?.title = speedTitle(hub.extRead, hub.extWrite)
    }

    private func buildDiskMenu() {
        let menu = diskMenu
        let st = storage
        let config = Config.current
        menu.removeAllItems()
        let gb: (UInt64) -> UInt64 = { $0 / 1_073_741_824 }
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        // Startup disk
        let used = st.mac.total > 0 ? Int((Double(st.mac.total - st.mac.free) / Double(st.mac.total) * 100).rounded(.up)) : 0
        _ = add("Macintosh HD — sisa \(gb(st.mac.free))GB dari \(gb(st.mac.total))GB (\(used)% kepakai)", to: menu, symbol: "internaldrive")
        macSpeedItem = add(speedTitle(hub.intRead, hub.intWrite), to: menu, symbol: "arrow.up.arrow.down")

        if let cleanup = config.cleanup {
            let cleanItem = add("Bisa dibersihin", to: menu, symbol: "sparkles") {}
            let cm = NSMenu()
            if cleanup.sizes != nil {
                if st.cleanable.isEmpty { _ = add("Menghitung…", to: cm) }
                for row in st.cleanable { _ = add("\(row.label): \(row.value)", to: cm, font: mono) }
                cm.addItem(.separator())
            }
            for cmd in cleanup.actions ?? [] {
                if cmd.title == "-" { cm.addItem(.separator()); continue }
                _ = add(cmd.title, to: cm) { st.perform(cmd) }
            }
            if let log = cleanup.log {
                cm.addItem(.separator())
                if let last = st.lastCleanLine {
                    _ = add("Terakhir: \(last)", to: cm, color: .secondaryLabelColor, font: .systemFont(ofSize: 11))
                }
                _ = add("Lihat log", to: cm, symbol: "doc.text") { Self.openInConsole(expand(log)) }
            }
            cleanItem.submenu = cm
        }

        // External drives
        extSpeedItem = nil
        if !st.volumes.isEmpty || !st.missing.isEmpty { menu.addItem(.separator()) }
        for (i, v) in st.volumes.enumerated() {
            _ = add("\(v.name) — sisa \(gb(v.free))GB dari \(gb(v.total))GB", to: menu, symbol: "externaldrive.fill")
            if i == 0 { extSpeedItem = add(speedTitle(hub.extRead, hub.extWrite), to: menu, symbol: "arrow.up.arrow.down") }
            if let n = v.users {
                _ = add(n > 0 ? "Dipakai \(n) proses" : "Tidak ada yang pakai", to: menu,
                        symbol: n > 0 ? "exclamationmark.triangle" : "circle")
            }
            if let drive = v.configured, drive.healthFile != nil {
                switch v.health?.state {
                case "OK":
                    _ = add("Kesehatan: OK (cek \(String(v.health!.date.dropFirst(5))))", to: menu, symbol: "heart.fill")
                case "RUNNING":
                    _ = add("Kesehatan: sedang dicek…", to: menu, symbol: "stethoscope")
                case "ERROR":
                    _ = add("Kesehatan: ADA ERROR — buka Disk Utility > First Aid", to: menu, symbol: "heart.slash.fill", color: .systemRed) {
                        NSWorkspace.shared.launchApplication("Disk Utility")
                    }
                default:
                    _ = add("Kesehatan: belum pernah dicek", to: menu, symbol: "heart")
                }
            }
            _ = add("Eject \(v.name)", to: menu, symbol: "eject.fill") { st.eject(v) }
            let more = add("Lainnya", to: menu, symbol: "ellipsis.circle") {}
            let mm = NSMenu()
            _ = add("Buka di Finder", to: mm, symbol: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: v.path)) }
            for folder in v.configured?.folders ?? [] {
                _ = add("Buka \(folder)", to: mm, symbol: "folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: v.path).appendingPathComponent(folder))
                }
            }
            if let drive = v.configured, drive.verify != nil, v.health?.state != "RUNNING" {
                _ = add("Cek kesehatan sekarang", to: mm, symbol: "stethoscope") { st.verify(drive) }
            }
            more.submenu = mm
        }
        for m in st.missing {
            if m.plugged {
                _ = add("\(m.drive.name) tercolok tapi belum ter-mount", to: menu, symbol: "externaldrive.badge.exclamationmark", color: .systemRed)
                _ = add("Mount sekarang", to: menu, symbol: "arrow.clockwise") { st.mount(m.drive) }
            } else {
                _ = add("\(m.drive.name) tidak terpasang", to: menu, symbol: "externaldrive.badge.xmark", color: .systemGray)
            }
        }

        // Auto-mount on wake
        if let wake = config.wake {
            let item: NSMenuItem
            if st.wakeWatcherOn {
                item = add("Auto-mount saat wake: aktif", to: menu, symbol: "bolt.circle") {}
            } else {
                item = add("Auto-mount saat wake: MATI", to: menu, symbol: "bolt.slash", color: .systemRed) {}
            }
            let wm = NSMenu()
            if !st.wakeWatcherOn, wake.start != nil { _ = add("Nyalakan", to: wm) { st.startWakeWatcher() } }
            if let w = st.lastWake {
                _ = add("Wake terakhir \(w.time): \(w.message)", to: wm, symbol: w.failed ? "xmark.octagon" : "clock",
                        color: w.failed ? .systemRed : nil)
            }
            _ = add("Lihat log", to: wm, symbol: "doc.text") { Self.openInConsole(expand(wake.log)) }
            item.submenu = wm
        }

        menu.addItem(.separator())
        _ = add("Refresh", to: menu) { st.refreshDetails() }
        _ = add("Edit konfigurasi…", to: menu) { Config.reveal() }
    }

    private static func openInConsole(_ path: String) {
        NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private func buildVPNMenu() {
        let menu = vpnMenu
        vpn.refresh()
        menu.removeAllItems()
        let cfg = Config.current.vpn
        let orange = NSColor.systemOrange
        func dot(_ up: Bool) -> String { up ? "🟢" : "⚪️" }

        func client(_ title: String, up: Bool, appID: String, running: Bool, warning: String, c: Config.VPNClient?) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sm = NSMenu()
            if !running {
                if let restart = c?.restart {
                    _ = add("⚠️ \(warning) — klik untuk restart", to: sm, color: orange) { self.vpn.run(restart) }
                } else {
                    _ = add("⚠️ \(warning)", to: sm, color: orange)
                }
            }
            if up, let off = c?.disconnect { _ = add("Disconnect", to: sm) { self.vpn.run(off) } }
            if !up, let on = c?.connect { _ = add("Connect", to: sm) { self.vpn.run(on) } }
            _ = add("Buka app", to: sm) { self.vpn.open(appID) }
            if let restart = c?.restart { _ = add("Restart", to: sm) { self.vpn.run(restart) } }
            item.submenu = sm
            menu.addItem(item)
        }

        if vpn.fortiInstalled {
            client("\(dot(vpn.fortiUp)) FortiClient — \(vpn.fortiState.components(separatedBy: "::")[0])", up: vpn.fortiUp,
                   appID: VPNModel.fortiApp, running: vpn.fortiTrayRunning, warning: "App FortiClient mati", c: cfg?.forti)
        }
        if vpn.gpInstalled {
            client("\(dot(vpn.gpUp)) GlobalProtect — \(vpn.gpState)", up: vpn.gpUp,
                   appID: VPNModel.gpApp, running: vpn.gpServiceRunning, warning: "Service mati", c: cfg?.globalProtect)
        }
        if let extra = cfg?.extra, !extra.isEmpty {
            menu.addItem(.separator())
            for cmd in extra {
                _ = add(cmd.title, to: menu) { Sys.perform(cmd) { self.vpn.refresh() } }
            }
        }
    }
}

/// NSMenuItem that runs a closure, so menus can be built inline.
final class ClosureMenuItem: NSMenuItem {
    private let handler: (() -> Void)?

    init(title: String, action handler: (() -> Void)?) {
        self.handler = handler
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = handler != nil
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler?() }
}
