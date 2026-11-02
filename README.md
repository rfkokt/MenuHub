# MenuHub

A lightweight macOS menu bar app (~20 MB) that shows network, memory, disk and VPN status.
It replaces Stats plus a couple of SwiftBar plugins with one native app that reads counters
straight from the kernel instead of spawning shell scripts every few seconds.

The interface is in Indonesian.

## Features

**Works out of the box**

- **Network**: live ↑/↓ speed in the menu bar. The popover shows history, totals since boot,
  interface, local and public IP (from `api.ipify.org`, at most every 10 minutes and only
  while the popover is open), and the top processes by traffic.
- **RAM**: usage %, memory pressure, App / Wired / Compressed / Free / Swap breakdown,
  history, and the top processes by memory.
- **Disk**: free space on the startup disk and every external drive, live read/write speed,
  how many processes are using each drive, Open in Finder and Eject. Drive changes come
  from DiskArbitration events, so nothing polls `diskutil`.
- **VPN**: FortiClient and GlobalProtect status, read from each client's log. This item only
  appears when one of them is installed.

Process lists are only collected while a popover is open.

**Optional, via `~/.config/menuhub/config.json`**

- Watch specific drives, including "plugged in but not mounted", with health checks,
  custom eject commands and folder shortcuts
- A cleanup submenu driven by your own scripts
- Auto-mount-on-wake status from a log file
- VPN connect / disconnect / restart commands

See [`config.example.json`](config.example.json). Open the config from the gear menu in any
popover, or from **Edit konfigurasi…** at the bottom of the Disk menu. Changes apply the next
time a menu opens.

| Key | Purpose |
|---|---|
| `drives[].name` | Volume name, e.g. `MySSD` for `/Volumes/MySSD` |
| `drives[].uuid` | Volume or media UUID (`diskutil info /Volumes/MySSD`), detects unmounted drives |
| `drives[].eject` | Command that replaces the built-in eject |
| `drives[].verify`, `healthFile` | Health check command and the file it writes: `YYYY-MM-DD HH:MM\|OK` (or `ERROR`, `RUNNING`) |
| `drives[].verifyFlagFile` | If this file exists when the drive mounts, `verify` runs once |
| `drives[].clearOnMount` | Files deleted whenever the drive is mounted |
| `drives[].folders` | Folders on the drive listed under "Lainnya" |
| `cleanup.sizes` | Command that prints `label<TAB>value` lines |
| `cleanup.actions` | Menu entries: `{ "title", "run": [argv] }` or `{ "title", "open": URL/app }`. Use `"title": "-"` for a separator |
| `wake` | `log`, `process` that must be running, `start` command, `ignore` substrings |
| `vpn.forti`, `vpn.globalProtect` | `connect`, `disconnect` and `restart` commands |
| `vpn.extra` | Extra commands. Add `"terminal": true` to show their output in a terminal |

Paths may start with `~`.

## URL commands

Your scripts can talk to MenuHub:

```bash
open -g "menuhub://refresh"                                  # re-read disk and VPN state now
open -g "menuhub://notify?title=Hi&body=Text&href=https://…" # notification; clicking opens href
```

## Build

Requires macOS 13+ and a Swift toolchain (the Xcode Command Line Tools are enough).

```bash
./build.sh   # builds, signs and installs ~/Applications/MenuHub.app
```

`build.sh` signs with your Apple Development or Developer ID certificate when one is
available, so permissions survive rebuilds. Otherwise it uses an ad-hoc signature.

Turn on **Jalankan saat login** (launch at login) from the gear menu.

## Permissions

- **Removable Volumes**: requested the first time a configured health check runs on an
  external drive.
- **Notifications**: requested the first time a script calls `menuhub://notify`.
