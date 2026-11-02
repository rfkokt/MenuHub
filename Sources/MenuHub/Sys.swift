import Darwin
import Foundation
import IOKit
import SystemConfiguration

/// Thin wrappers over kernel and IOKit counters. Everything here is a cheap
/// syscall; nothing spawns a process except `run`.
enum Sys {
    // MARK: Network

    struct IfaceBytes { var rx: UInt64; var tx: UInt64 }

    private static let dynamicStore = SCDynamicStoreCreate(nil, "MenuHub" as CFString, nil, nil)

    static func primaryInterface() -> String? {
        guard let store = dynamicStore,
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return dict["PrimaryInterface"] as? String
    }

    /// 64-bit byte counters per interface (getifaddrs only exposes 32-bit ones that wrap at 4 GB).
    static func interfaceBytes() -> [String: IfaceBytes] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }

        var result: [String: IfaceBytes] = [:]
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let m2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(m2.ifm_index), &name) != nil {
                        result[String(cString: name)] = IfaceBytes(rx: m2.ifm_data.ifi_ibytes, tx: m2.ifm_data.ifi_obytes)
                    }
                }
                guard hdr.ifm_msglen > 0 else { break }
                offset += Int(hdr.ifm_msglen)
            }
        }
        return result
    }

    static func ipv4Address(of iface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard String(cString: ifa.ifa_name) == iface,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    // MARK: Memory

    struct Memory {
        var total: UInt64 = 0
        var app: UInt64 = 0
        var wired: UInt64 = 0
        var compressed: UInt64 = 0
        var swap: UInt64 = 0
        /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
        var pressure: Int = 1

        var used: UInt64 { app + wired + compressed }
        var free: UInt64 { total > used ? total - used : 0 }
        var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    }

    /// Same breakdown as Activity Monitor: Memory Used = App + Wired + Compressed.
    static func memory() -> Memory {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var m = Memory()
        m.total = ProcessInfo.processInfo.physicalMemory
        guard kr == KERN_SUCCESS else { return m }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        m.wired = UInt64(stats.wire_count) * page
        m.compressed = UInt64(stats.compressor_page_count) * page

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swap = swap.xsu_used }

        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { m.pressure = Int(level) }
        return m
    }

    // MARK: Disk

    struct DiskIO { var intRead: UInt64 = 0; var intWrite: UInt64 = 0; var extRead: UInt64 = 0; var extWrite: UInt64 = 0 }

    /// Cumulative bytes read/written, split by whether the physical device is internal or external.
    static func diskIO() -> DiskIO {
        var io = DiskIO()
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return io }
        defer { IOObjectRelease(iter) }
        var drv = IOIteratorNext(iter)
        while drv != 0 {
            defer { IOObjectRelease(drv); drv = IOIteratorNext(iter) }
            var location = ""
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(drv, kIOServicePlane, &parent) == KERN_SUCCESS {
                if let pc = IORegistryEntryCreateCFProperty(parent, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] {
                    location = pc["Physical Interconnect Location"] as? String ?? ""
                }
                IOObjectRelease(parent)
            }
            guard location == "Internal" || location == "External",
                  let st = IORegistryEntryCreateCFProperty(drv, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            let r = (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let w = (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            if location == "Internal" { io.intRead += r; io.intWrite += w } else { io.extRead += r; io.extWrite += w }
        }
        return io
    }

    /// (total, available) bytes, matching `df`.
    static func volume(_ path: String) -> (total: UInt64, free: UInt64)? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let bs = UInt64(s.f_bsize)
        return (UInt64(s.f_blocks) * bs, UInt64(s.f_bavail) * bs)
    }

    static func isMountPoint(_ path: String) -> Bool {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return false }
        let mounted = withUnsafePointer(to: s.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mounted == path
    }

    // MARK: Processes

    /// Short names (p_comm, max 16 chars) of all running processes.
    static func processNames() -> Set<String> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [] }
        var names = Set<String>()
        for p in procs.prefix(size / stride) {
            let name = withUnsafePointer(to: p.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            names.insert(name)
        }
        return names
    }

    // MARK: Helpers

    /// Runs a command off the main thread and delivers stdout on the main thread.
    static func run(_ path: String, _ args: [String] = [], completion: ((String) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(NSHomeDirectory())/.local/bin"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var text = ""
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                text = String(decoding: data, as: UTF8.self)
            } catch {}
            if let completion { DispatchQueue.main.async { completion(text) } }
        }
    }

    /// Last `bytes` of a file as text.
    static func tail(_ path: String, bytes: UInt64) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let end = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: end > bytes ? end - bytes : 0)
        guard let data = try? fh.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Last capture of `pattern` group 1 in `text`.
    static func lastMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
    }
}

enum Fmt {
    static func speed(_ bytesPerSec: Double) -> String {
        let kb = bytesPerSec / 1024
        if kb < 1000 { return "\(Int(kb.rounded())) KB/s" }
        let mb = kb / 1024
        return mb < 100 ? String(format: "%.1f MB/s", mb) : "\(Int(mb)) MB/s"
    }

    static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1000 { return String(format: "%.1f TB", gb / 1024) }
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        return String(format: "%.1f MB", Double(b) / 1_048_576)
    }

    /// Whole GiB, rounded down, like `df -g`.
    static func gib(_ b: UInt64) -> String { "\(b / 1_073_741_824)GB" }
}
