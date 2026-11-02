import AppKit
import ServiceManagement
import SwiftUI

// MARK: Shared pieces

private let blue = Color(red: 0.25, green: 0.55, blue: 1.0)
private let red = Color(red: 1.0, green: 0.3, blue: 0.3)

struct PopoverShell<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.headline)
            content
            Divider()
            SettingsFooter()
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack {
            VStack { Divider() }
            Text(text.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).fixedSize()
            VStack { Divider() }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var dot: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

/// Filled area chart. `inverted` draws downward from the top edge.
struct Spark: View {
    let values: [Double]
    let color: Color
    var maxValue: Double?
    var inverted = false

    var body: some View {
        GeometryReader { g in
            let m = max(maxValue ?? (values.max() ?? 0), 1)
            let w = g.size.width
            let h = g.size.height
            let n = max(values.count, 2)
            let step = w / CGFloat(Hub.historyLength - 1)
            let x0 = w - CGFloat(n - 1) * step
            Path { p in
                p.move(to: CGPoint(x: x0, y: inverted ? 0 : h))
                for (i, v) in values.enumerated() {
                    let y = CGFloat(min(v / m, 1)) * h
                    p.addLine(to: CGPoint(x: x0 + CGFloat(i) * step, y: inverted ? y : h - y))
                }
                p.addLine(to: CGPoint(x: x0 + CGFloat(values.count - 1) * step, y: inverted ? 0 : h))
                p.closeSubpath()
            }
            .fill(color.opacity(0.75))
        }
    }
}

/// Download above the midline, upload below, each on its own scale.
struct DualSpark: View {
    let top: [Double]
    let bottom: [Double]
    var topColor = blue
    var bottomColor = red

    var body: some View {
        VStack(spacing: 0) {
            Spark(values: top, color: topColor)
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
            Spark(values: bottom, color: bottomColor, inverted: true)
        }
        .padding(4)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct UsageBar: View {
    let fraction: Double
    var color: Color = blue

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color).frame(width: g.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

struct ProcessTable: View {
    let rows: [ProcRow]
    let columns: [String]
    let format: (ProcRow) -> [String]

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Proses")
                Spacer()
                ForEach(columns, id: \.self) { Text($0).frame(width: 70, alignment: .trailing) }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("Mengambil data…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { r in
                HStack {
                    Text(r.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    ForEach(Array(format(r).enumerated()), id: \.offset) { Text($0.element).frame(width: 70, alignment: .trailing) }
                }
                .font(.system(size: 11)).monospacedDigit()
            }
        }
    }
}

// MARK: Settings

final class Modules: ObservableObject {
    static let shared = Modules()
    private let d = UserDefaults.standard

    @Published var network: Bool { didSet { d.set(network, forKey: "mod.network"); onChange?() } }
    @Published var ram: Bool { didSet { d.set(ram, forKey: "mod.ram"); onChange?() } }
    @Published var disk: Bool { didSet { d.set(disk, forKey: "mod.disk"); onChange?() } }
    @Published var vpn: Bool { didSet { d.set(vpn, forKey: "mod.vpn"); onChange?() } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    var onChange: (() -> Void)?

    private init() {
        d.register(defaults: ["mod.network": true, "mod.ram": true, "mod.disk": true, "mod.vpn": true])
        network = d.bool(forKey: "mod.network")
        ram = d.bool(forKey: "mod.ram")
        disk = d.bool(forKey: "mod.disk")
        vpn = d.bool(forKey: "mod.vpn")
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct SettingsFooter: View {
    @ObservedObject var m = Modules.shared

    var body: some View {
        HStack {
            Text("MenuHub").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Toggle("Network", isOn: $m.network)
                Toggle("RAM", isOn: $m.ram)
                Toggle("Disk & SSD", isOn: $m.disk)
                Toggle("VPN", isOn: $m.vpn)
                Divider()
                Toggle("Jalankan saat login", isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
                Divider()
                Button("Edit konfigurasi…") { Config.reveal() }
                Button("Keluar MenuHub") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

// MARK: Network

struct NetworkView: View {
    @ObservedObject var hub = Hub.shared

    var body: some View {
        PopoverShell(title: "Network") {
            HStack {
                bigStat(Fmt.speed(hub.down), "Download", blue)
                bigStat(Fmt.speed(hub.up), "Upload", red)
            }
            SectionTitle("Riwayat")
            DualSpark(top: hub.downHist, bottom: hub.upHist).frame(height: 80)
            SectionTitle("Interface")
            VStack(spacing: 5) {
                InfoRow(label: "Total upload", value: Fmt.bytes(hub.totalTx), dot: red)
                InfoRow(label: "Total download", value: Fmt.bytes(hub.totalRx), dot: blue)
                InfoRow(label: "Interface", value: hub.iface ?? "Tidak terhubung")
                InfoRow(label: "IP lokal", value: hub.localIP ?? "–")
                InfoRow(label: "IP publik", value: hub.publicIP ?? "…")
            }
            SectionTitle("Proses teratas")
            ProcessTable(rows: hub.topNet, columns: ["↓", "↑"]) { [Fmt.speed($0.a), Fmt.speed($0.b)] }
        }
    }

    private func bigStat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .medium)).monospacedDigit()
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: RAM

struct RAMView: View {
    @ObservedObject var hub = Hub.shared

    var body: some View {
        let m = hub.mem
        PopoverShell(title: "RAM") {
            HStack(spacing: 24) {
                pressureBadge(m.pressure)
                ZStack {
                    ring(m)
                    Text("\(Int((m.fraction * 100).rounded()))%").font(.system(size: 18, weight: .semibold)).monospacedDigit()
                }
                .frame(width: 86, height: 86)
            }
            SectionTitle("Riwayat")
            Spark(values: hub.memHist, color: blue, maxValue: 1)
                .padding(4)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(height: 60)
            SectionTitle("Rincian")
            VStack(spacing: 5) {
                InfoRow(label: "Terpakai", value: Fmt.bytes(m.used))
                segmented(m).frame(height: 6)
                InfoRow(label: "App", value: Fmt.bytes(m.app), dot: blue)
                InfoRow(label: "Wired", value: Fmt.bytes(m.wired), dot: .orange)
                InfoRow(label: "Compressed", value: Fmt.bytes(m.compressed), dot: red)
                InfoRow(label: "Bebas", value: Fmt.bytes(m.free), dot: .gray)
                InfoRow(label: "Swap", value: Fmt.bytes(m.swap))
            }
            SectionTitle("Proses teratas")
            ProcessTable(rows: hub.topMem, columns: ["Memori"]) { [Fmt.bytes(UInt64($0.a))] }
        }
    }

    private func parts(_ m: Sys.Memory) -> [(Double, Color)] {
        let t = Double(max(m.total, 1))
        return [(Double(m.app) / t, blue), (Double(m.wired) / t, .orange), (Double(m.compressed) / t, red)]
    }

    private func ring(_ m: Sys.Memory) -> some View {
        var start = 0.0
        let segs = parts(m).map { p -> (Double, Double, Color) in
            defer { start += p.0 }
            return (start, start + p.0, p.1)
        }
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 9)
            ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                Circle().trim(from: s.0, to: s.1).stroke(s.2, lineWidth: 9).rotationEffect(.degrees(-90))
            }
        }
    }

    private func segmented(_ m: Sys.Memory) -> some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(Array(parts(m).enumerated()), id: \.offset) { _, p in
                    Rectangle().fill(p.1).frame(width: g.size.width * CGFloat(p.0))
                }
                Rectangle().fill(Color.gray.opacity(0.4))
            }
            .clipShape(Capsule())
        }
    }

    private func pressureBadge(_ level: Int) -> some View {
        let (text, color): (String, Color) = level >= 4 ? ("Kritis", red) : level >= 2 ? ("Waspada", .orange) : ("Normal", .green)
        return VStack(spacing: 6) {
            Image(systemName: "gauge.with.needle").font(.system(size: 34)).foregroundStyle(color)
            Text("Tekanan: \(text)").font(.caption).foregroundStyle(.secondary)
        }
    }
}
