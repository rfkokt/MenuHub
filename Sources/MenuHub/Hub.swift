import Foundation

struct ProcRow: Identifiable {
    let id: Int
    let name: String
    let a: Double
    let b: Double
}

/// Samples network, memory and disk throughput on one timer.
/// Process lists are only gathered while a popover that shows them is open.
final class Hub: ObservableObject {
    static let shared = Hub()
    static let interval: TimeInterval = 2
    static let historyLength = 90

    @Published private(set) var down = 0.0
    @Published private(set) var up = 0.0
    @Published private(set) var downHist: [Double] = []
    @Published private(set) var upHist: [Double] = []
    @Published private(set) var totalRx: UInt64 = 0
    @Published private(set) var totalTx: UInt64 = 0
    @Published private(set) var iface: String?
    @Published private(set) var localIP: String?
    @Published private(set) var publicIP: String?

    @Published private(set) var mem = Sys.Memory()
    @Published private(set) var memHist: [Double] = []

    @Published private(set) var intRead = 0.0
    @Published private(set) var intWrite = 0.0
    @Published private(set) var extRead = 0.0
    @Published private(set) var extWrite = 0.0
    @Published private(set) var intReadHist: [Double] = []
    @Published private(set) var intWriteHist: [Double] = []
    @Published private(set) var extReadHist: [Double] = []
    @Published private(set) var extWriteHist: [Double] = []

    @Published private(set) var topNet: [ProcRow] = []
    @Published private(set) var topMem: [ProcRow] = []

    var onSample: (() -> Void)?
    var watchNetProcesses = false { didSet { if watchNetProcesses { refreshTopNet() } } }
    var watchMemProcesses = false { didSet { if watchMemProcesses { refreshTopMem() } } }

    private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?
    private var lastDisk: (io: Sys.DiskIO, at: Date)?
    private var netBusy = false
    private var publicIPFetched: Date?

    func start() {
        sample()
        let t = Timer(timeInterval: Hub.interval, repeats: true) { [weak self] _ in self?.sample() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
    }

    private func push(_ v: Double, _ arr: inout [Double]) {
        arr.append(v)
        if arr.count > Hub.historyLength { arr.removeFirst(arr.count - Hub.historyLength) }
    }

    private func sample() {
        let now = Date()

        // Network: the primary interface only, so VPN tunnels are not counted twice.
        let primary = Sys.primaryInterface()
        if primary != iface { lastNet = nil; iface = primary; localIP = primary.flatMap(Sys.ipv4Address) }
        if let primary, let c = Sys.interfaceBytes()[primary] {
            if let last = lastNet, c.rx >= last.rx, c.tx >= last.tx {
                let dt = now.timeIntervalSince(last.at)
                down = Double(c.rx - last.rx) / dt
                up = Double(c.tx - last.tx) / dt
            }
            lastNet = (c.rx, c.tx, now)
            totalRx = c.rx
            totalTx = c.tx
        } else {
            down = 0; up = 0
        }
        push(down, &downHist)
        push(up, &upHist)

        mem = Sys.memory()
        push(mem.fraction, &memHist)

        let io = Sys.diskIO()
        if let last = lastDisk {
            let dt = now.timeIntervalSince(last.at)
            func rate(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double(a - b) / dt : 0 }
            intRead = rate(io.intRead, last.io.intRead)
            intWrite = rate(io.intWrite, last.io.intWrite)
            extRead = rate(io.extRead, last.io.extRead)
            extWrite = rate(io.extWrite, last.io.extWrite)
        }
        lastDisk = (io, now)
        push(intRead, &intReadHist)
        push(intWrite, &intWriteHist)
        push(extRead, &extReadHist)
        push(extWrite, &extWriteHist)

        if watchNetProcesses { refreshTopNet() }
        if watchMemProcesses { refreshTopMem() }
        onSample?()
    }

    func refreshLocalIP() {
        localIP = iface.flatMap(Sys.ipv4Address)
    }

    /// Looks up the public address at most every 10 minutes, and only when asked.
    func refreshPublicIP(force: Bool = false) {
        if !force, let t = publicIPFetched, Date().timeIntervalSince(t) < 600 { return }
        publicIPFetched = Date()
        var req = URLRequest(url: URL(string: "https://api.ipify.org")!)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let ip = data.map { String(decoding: $0, as: UTF8.self) }
            DispatchQueue.main.async { self.publicIP = ip?.isEmpty == false ? ip : nil }
        }.resume()
    }

    /// Per-process traffic over one second, from nettop's delta mode.
    private func refreshTopNet() {
        guard !netBusy else { return }
        netBusy = true
        Sys.run("/usr/bin/nettop", ["-P", "-x", "-d", "-L", "2", "-s", "1", "-J", "bytes_in,bytes_out"]) { out in
            self.netBusy = false
            // Two samples are printed; the second one holds the deltas.
            let blocks = out.components(separatedBy: "time,")
            guard let last = blocks.last else { return }
            var rows: [ProcRow] = []
            for line in last.split(separator: "\n").dropFirst() {
                let f = line.split(separator: ",", omittingEmptySubsequences: false)
                guard f.count >= 4, let inB = Double(f[2]), let outB = Double(f[3]) else { continue }
                var name = String(f[1])
                if let dot = name.lastIndex(of: "."), name[name.index(after: dot)...].allSatisfy(\.isNumber) {
                    name = String(name[..<dot])
                }
                rows.append(ProcRow(id: rows.count, name: name, a: inB, b: outB))
            }
            self.topNet = Array(rows.sorted { $0.a + $0.b > $1.a + $1.b }.prefix(8))
        }
    }

    private func refreshTopMem() {
        Sys.run("/bin/ps", ["-axo", "rss=,comm="]) { out in
            var rows: [(String, Double)] = []
            for line in out.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let sp = t.firstIndex(of: " "), let kb = Double(t[..<sp]) else { continue }
                let path = t[sp...].trimmingCharacters(in: .whitespaces)
                rows.append(((path as NSString).lastPathComponent, kb * 1024))
            }
            self.topMem = rows.sorted { $0.1 > $1.1 }.prefix(8).enumerated()
                .map { ProcRow(id: $0.offset, name: $0.element.0, a: $0.element.1, b: 0) }
        }
    }
}
