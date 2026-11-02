import AppKit
import DiskArbitration

/// The startup disk plus every external volume. Drives listed in the config are also
/// tracked while unplugged or unmounted. Disk events come from DiskArbitration, so
/// nothing polls diskutil.
final class StorageModel: ObservableObject {
    static let shared = StorageModel()

    struct Volume: Identifiable {
        var id: String { path }
        let name: String
        let path: String
        let total: UInt64
        let free: UInt64
        /// Set when this volume belongs to a drive from the config.
        var configured: Config.Drive?
        var health: (date: String, state: String)?
        var users: Int?
    }

    /// A configured drive that is plugged in but not mounted, or not plugged in at all.
    struct MissingDrive {
        let drive: Config.Drive
        let plugged: Bool
    }

    @Published private(set) var mac: (total: UInt64, free: UInt64) = (0, 0)
    @Published private(set) var volumes: [Volume] = []
    @Published private(set) var missing: [MissingDrive] = []
    @Published private(set) var cleanable: [(label: String, value: String)] = []
    @Published private(set) var lastCleanLine: String?
    @Published private(set) var wakeWatcherOn = true
    @Published private(set) var lastWake: (time: String, message: String, failed: Bool)?
    @Published private(set) var busy = false

    var onChange: (() -> Void)?

    private var presentUUIDs = Set<String>()
    private var session: DASession?
    private var cleanableFetched: Date?
    private var verifiedThisMount = Set<String>()
    private var users: [String: Int] = [:]

    func start() {
        watchDisks()
        refresh()
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
    }

    var hasProblem: Bool {
        missing.contains { $0.plugged } || volumes.contains { $0.health?.state == "ERROR" }
    }

    func refresh() {
        let config = Config.current
        if let v = Sys.volume("/System/Volumes/Data") { mac = v }

        let drives = config.drives ?? []
        var found: [Volume] = []
        var mountedNames = Set<String>()
        for url in Self.externalVolumes() {
            let path = url.path
            guard let space = Sys.volume(path) else { continue }
            let name = FileManager.default.displayName(atPath: path)
            var v = Volume(name: name, path: path, total: space.total, free: space.free, users: users[path])
            if let drive = drives.first(where: { $0.name == name }) {
                v.configured = drive
                mountedNames.insert(drive.name)
                v.health = Self.readHealth(drive)
                onMounted(drive)
            }
            found.append(v)
        }
        // Configured drives first, in config order.
        volumes = found.sorted { a, b in
            let ia = drives.firstIndex { $0.name == a.name } ?? Int.max
            let ib = drives.firstIndex { $0.name == b.name } ?? Int.max
            return ia != ib ? ia < ib : a.name < b.name
        }
        missing = drives.filter { !mountedNames.contains($0.name) }.map { d in
            MissingDrive(drive: d, plugged: d.uuid.map { presentUUIDs.contains($0.uppercased()) } ?? false)
        }
        verifiedThisMount.formIntersection(mountedNames)

        if let wake = config.wake {
            wakeWatcherOn = wake.process.map { Sys.processNames().contains($0) } ?? true
            lastWake = Self.readLastWake(wake)
        } else {
            lastWake = nil
        }
        onChange?()
    }

    /// Mounted, browsable volumes that are not on the internal disk.
    private static func externalVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return v.volumeIsInternal == false && v.volumeIsBrowsable == true && v.volumeIsLocal == true
        }
    }

    private func onMounted(_ drive: Config.Drive) {
        let fm = FileManager.default
        for f in drive.clearOnMount ?? [] { try? fm.removeItem(atPath: expand(f)) }
        if let flag = drive.verifyFlagFile, let verify = drive.verify,
           fm.fileExists(atPath: expand(flag)), !verifiedThisMount.contains(drive.name) {
            verifiedThisMount.insert(drive.name)
            Sys.run(verify)
        }
    }

    /// Slower checks that only run while the menu is open.
    func refreshDetails() {
        refresh()
        let config = Config.current

        for v in volumes {
            Sys.run("/usr/sbin/lsof", ["-t", v.path]) { out in
                self.users[v.path] = Set(out.split(separator: "\n")).count
                self.refresh()
            }
        }

        if let log = config.cleanup?.log {
            lastCleanLine = Sys.tail(expand(log), bytes: 2000)?.split(separator: "\n").last.map { String($0.prefix(70)) }
        }
        if let sizes = config.cleanup?.sizes,
           cleanableFetched == nil || Date().timeIntervalSince(cleanableFetched!) > 300 {
            cleanableFetched = Date()
            Sys.run(sizes) { out in
                self.cleanable = out.split(separator: "\n").compactMap { line in
                    let f = line.split(separator: "\t", maxSplits: 1)
                    return f.count == 2 ? (String(f[0]), String(f[1])) : nil
                }
                self.onChange?()
            }
        }
    }

    // MARK: Actions

    func perform(_ cmd: Config.Command) {
        busy = true
        Sys.perform(cmd) {
            self.busy = false
            self.cleanableFetched = nil
            self.refreshDetails()
        }
    }

    private func runAndRefresh(_ argv: [String]) {
        busy = true
        Sys.run(argv) { _ in
            self.busy = false
            self.refreshDetails()
        }
    }

    func eject(_ v: Volume) {
        if let custom = v.configured?.eject {
            runAndRefresh(custom)
            return
        }
        busy = true
        let url = URL(fileURLWithPath: v.path)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) } catch { failure = error }
            DispatchQueue.main.async {
                self.busy = false
                if let failure {
                    let alert = NSAlert(error: failure)
                    alert.messageText = "Gagal eject \(v.name)"
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
                self.refresh()
            }
        }
    }

    func verify(_ drive: Config.Drive) {
        if let verify = drive.verify { runAndRefresh(verify) }
    }

    func mount(_ drive: Config.Drive) {
        if let uuid = drive.uuid { runAndRefresh(["/usr/sbin/diskutil", "mount", uuid]) }
    }

    func startWakeWatcher() {
        if let start = Config.current.wake?.start { runAndRefresh(start) }
    }

    // MARK: Files

    private static func readHealth(_ drive: Config.Drive) -> (String, String)? {
        guard let file = drive.healthFile,
              let raw = try? String(contentsOfFile: expand(file), encoding: .utf8) else { return nil }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    /// Last meaningful line of a "YYYY-MM-DD HH:MM:SS message" log.
    private static func readLastWake(_ wake: Config.Wake) -> (String, String, Bool)? {
        guard let text = Sys.tail(expand(wake.log), bytes: 20_000) else { return nil }
        let ignore = wake.ignore ?? []
        guard let line = text.split(separator: "\n").last(where: { l in !ignore.contains { l.contains($0) } }),
              line.count > 20 else { return nil }
        let time = String(line.dropFirst(11).prefix(5))
        let message = String(line.dropFirst(20))
        let lower = message.lowercased()
        let failed = ["gagal", "fail", "error"].contains { lower.contains($0) }
        return (time, message, failed)
    }

    // MARK: DiskArbitration

    private func watchDisks() {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return }
        session = s
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(s, nil, { disk, ctx in
            guard let ctx else { return }
            let me = Unmanaged<StorageModel>.fromOpaque(ctx).takeUnretainedValue()
            me.presentUUIDs.formUnion(StorageModel.uuids(of: disk))
            me.refresh()
        }, ctx)
        DARegisterDiskDisappearedCallback(s, nil, { disk, ctx in
            guard let ctx else { return }
            let me = Unmanaged<StorageModel>.fromOpaque(ctx).takeUnretainedValue()
            me.presentUUIDs.subtract(StorageModel.uuids(of: disk))
            me.refresh()
        }, ctx)
        DARegisterDiskDescriptionChangedCallback(s, nil, nil, { _, _, ctx in
            guard let ctx else { return }
            Unmanaged<StorageModel>.fromOpaque(ctx).takeUnretainedValue().refresh()
        }, ctx)
        DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// Volume and media UUIDs, so the config may use either.
    private static func uuids(of disk: DADisk) -> Set<String> {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return [] }
        var out = Set<String>()
        for key in [kDADiskDescriptionVolumeUUIDKey, kDADiskDescriptionMediaUUIDKey] {
            if let v = desc[key as String], CFGetTypeID(v as CFTypeRef) == CFUUIDGetTypeID() {
                out.insert((CFUUIDCreateString(nil, (v as! CFUUID)) as String).uppercased())
            }
        }
        return out
    }
}
