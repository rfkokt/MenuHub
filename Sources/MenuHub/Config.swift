import AppKit

/// Optional per-user extras, read from ~/.config/menuhub/config.json.
/// Without the file MenuHub still shows network, memory, all drives and installed VPN clients;
/// the config only adds personal commands and drives to watch.
struct Config: Codable {
    /// A menu entry: runs `run` (argv), or opens `open` (URL, path or app name).
    struct Command: Codable {
        var title: String
        var run: [String]?
        var open: String?
        /// Show the command's output in a terminal window instead of running it silently.
        var terminal: Bool?
    }

    /// A drive to watch even while it is unplugged or unmounted.
    struct Drive: Codable {
        var name: String
        /// Volume or media UUID (`diskutil info <disk> | grep UUID`). Enables "plugged in but not mounted".
        var uuid: String?
        /// Replaces the built-in eject.
        var eject: [String]?
        /// Health check command, and the file it writes ("YYYY-MM-DD HH:MM|OK|ERROR|RUNNING").
        var verify: [String]?
        var healthFile: String?
        /// When this file exists at mount time, `verify` runs once in the background.
        var verifyFlagFile: String?
        /// Files deleted whenever the drive is mounted.
        var clearOnMount: [String]?
        /// Folders on the drive offered under "Lainnya".
        var folders: [String]?
    }

    struct Cleanup: Codable {
        /// Prints "label<TAB>value" lines describing what can be cleaned.
        var sizes: [String]?
        var actions: [Command]?
        var log: String?
    }

    struct Wake: Codable {
        var log: String
        /// Process that must be running for auto-mount on wake, and how to start it.
        var process: String?
        var start: [String]?
        /// Log lines containing any of these are skipped when showing the last event.
        var ignore: [String]?
    }

    struct VPNClient: Codable {
        var connect: [String]?
        var disconnect: [String]?
        var restart: [String]?
    }

    struct VPN: Codable {
        var forti: VPNClient?
        var globalProtect: VPNClient?
        var extra: [Command]?
    }

    var drives: [Drive]?
    var cleanup: Cleanup?
    var wake: Wake?
    var vpn: VPN?

    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/.config/menuhub/config.json")

    private static var cached: (Config, Date)?

    /// Re-reads the file only when it changed.
    static var current: Config {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date ?? .distantPast
        if let c = cached, c.1 == modified { return c.0 }
        var config = Config()
        if let data = try? Data(contentsOf: url) {
            do {
                config = try JSONDecoder().decode(Config.self, from: data)
            } catch {
                NSLog("MenuHub: cannot read \(url.path): \(error)")
            }
        }
        cached = (config, modified)
        return config
    }

    /// Opens the config in the default editor, creating an empty one first.
    static func reveal() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "{\n}\n".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
}

/// `~/x` → absolute path.
func expand(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

extension Sys {
    /// Runs an argv from the config; the first element may use `~`.
    static func run(_ argv: [String], completion: ((String) -> Void)? = nil) {
        guard let first = argv.first else { completion?(""); return }
        run(expand(first), Array(argv.dropFirst()), completion: completion)
    }

    static func perform(_ cmd: Config.Command, completion: (() -> Void)? = nil) {
        if let argv = cmd.run {
            if cmd.terminal == true {
                openInTerminal(argv)
                completion?()
            } else {
                run(argv) { _ in completion?() }
            }
        } else if let target = cmd.open {
            if target.contains("://") {
                if let url = URL(string: target) { NSWorkspace.shared.open(url) }
            } else if target.hasPrefix("/") || target.hasPrefix("~") {
                NSWorkspace.shared.open(URL(fileURLWithPath: expand(target)))
            } else {
                NSWorkspace.shared.launchApplication(target)
            }
            completion?()
        }
    }

    /// Shows a command's output in Ghostty when installed, otherwise Terminal.
    static func openInTerminal(_ argv: [String]) {
        let quoted = argv.enumerated().map { i, a in
            let s = i == 0 ? expand(a) : a
            return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
        let cmd = "\(quoted); echo; read -k1 '?Tekan tombol apa saja untuk menutup…'"
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil {
            run("/usr/bin/open", ["-na", "Ghostty", "--args", "-e", "/bin/zsh", "-c", cmd])
        } else {
            let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            run("/usr/bin/osascript", ["-e", "tell application \"Terminal\" to do script \"\(escaped)\"",
                                      "-e", "tell application \"Terminal\" to activate"])
        }
    }
}
