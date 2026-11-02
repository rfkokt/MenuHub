import AppKit

/// FortiClient and GlobalProtect status, read from each client's own log.
/// Connect/disconnect/restart need commands from the config; without them the
/// menu only shows status and opens the app.
final class VPNModel {
    static let shared = VPNModel()

    static let fortiApp = "com.fortinet.FortiClient"
    static let gpApp = "com.paloaltonetworks.GlobalProtect.client"
    static let fortiLog = "/Library/Application Support/Fortinet/FortiClient/Logs/vpn-controller.log"
    static let gpLog = "/Library/Logs/PaloAltoNetworks/GlobalProtect/PanGPS.log"

    private(set) var fortiInstalled = false
    private(set) var gpInstalled = false
    private(set) var fortiState = "Disconnected"
    private(set) var fortiTrayRunning = true
    private(set) var gpState = "Disconnected"
    private(set) var gpServiceRunning = true

    var anyInstalled: Bool { fortiInstalled || gpInstalled }
    var fortiUp: Bool { fortiState == "Connected" }
    var gpUp: Bool { gpState == "Connected" }
    var warning: Bool { (fortiInstalled && !fortiTrayRunning) || (gpInstalled && !gpServiceRunning) }

    var onChange: (() -> Void)?

    func start() {
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
    }

    func refresh() {
        let ws = NSWorkspace.shared
        fortiInstalled = ws.urlForApplication(withBundleIdentifier: Self.fortiApp) != nil
        gpInstalled = ws.urlForApplication(withBundleIdentifier: Self.gpApp) != nil
        guard anyInstalled else { onChange?(); return }

        let procs = Sys.processNames()
        if fortiInstalled {
            fortiTrayRunning = procs.contains("FortiTray")
            fortiState = Sys.tail(Self.fortiLog, bytes: 2_000_000)
                .flatMap { Sys.lastMatch(#"Changing state from \[[^\]]*\] to \[([^\]]*)\]"#, in: $0) } ?? "Disconnected"
        }
        if gpInstalled {
            gpServiceRunning = procs.contains("PanGPS")
            gpState = gpServiceRunning
                ? Sys.tail(Self.gpLog, bytes: 500_000).flatMap { Sys.lastMatch(#"Set state to ([A-Za-z ]*)"#, in: $0) } ?? "Disconnected"
                : "Service mati"
        }
        onChange?()
    }

    func run(_ argv: [String]?) {
        guard let argv else { return }
        Sys.run(argv) { _ in self.refresh() }
        // State changes take a few seconds to reach the logs.
        for delay in [3.0, 8.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.refresh() }
        }
    }

    func open(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
