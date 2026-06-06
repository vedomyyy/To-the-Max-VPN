# To the Max VPN!

> A cross-platform VPN client built with Flutter, powered by VLESS protocol.

![Platform](https://img.shields.io/badge/platform-Windows-blue?style=flat-square)
![Flutter](https://img.shields.io/badge/Flutter-3.x-54C5F8?style=flat-square&logo=flutter)
![Protocol](https://img.shields.io/badge/protocol-VLESS-orange?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

<p align="center">
  <img src="screenshots/screenshot2.png" width="230" alt="TUN mode"/>
  <img src="screenshots/screenshot3.png" width="230" alt="Proxy mode"/>
  <img src="screenshots/screenshot4.png" width="230" alt="Settings"/>
</p>

---

## Features

- **Two connection modes on Windows:**
  - **System Proxy** — routes browser and most app traffic via HTTP proxy. No admin rights required.
  - **TUN Tunnel** — captures all OS-level traffic via a virtual network adapter (WinTUN). Requires administrator privileges.
- **VLESS protocol** support with RAW/TCP, TLS, and Reality stream settings
- **System tray** integration — minimize to tray, status icon updates in real time, exit cleanly
- **Single instance** — clicking the shortcut a second time brings the existing window to focus
- **Live logs** — real-time connection log with color coding, copyable to clipboard
- **Ping display** — measures TCP round-trip time to the server before connecting
- **Persistent config** — saves your invite link across sessions

---

## Architecture

```
lib/
├── main.dart                    # App entry, window_manager + tray init
├── screens/
│   ├── home_screen.dart         # Main UI — connect button, mode toggle, stats
│   └── config_screen.dart       # Invite link input + live logs
└── services/
    ├── vpn_backend.dart          # Abstract backend interface
    ├── vpn_service.dart          # Facade — picks backend by platform
    ├── windows_vpn_backend.dart  # Windows: xray.exe + system proxy / TUN
    ├── android_vpn_backend.dart  # Android: flutter_v2ray (WIP)
    └── tray_service.dart         # Windows tray icon + context menu
```

### Windows — System Proxy mode

```
Flutter UI
  └─ WindowsVpnBackend
        ├─ extracts bundled xray.exe to AppData
        ├─ writes VLESS config JSON
        ├─ launches xray.exe (SOCKS5 :10808, HTTP :10809)
        └─ sets Windows registry proxy → 127.0.0.1:10809
```

### Windows — TUN Tunnel mode

```
Flutter UI
  └─ WindowsVpnBackend
        ├─ launches xray.exe (SOCKS5 :10808)
        ├─ extracts bundled tun2socks.exe + wintun.dll
        ├─ launches tun2socks → WinTUN adapter "tun0"
        ├─ assigns 10.0.0.1/30 to tun0
        ├─ adds bypass route: VPN server IP → real gateway
        └─ adds default route: 0.0.0.0/0 → tun0 (metric 1)
```

---

## Getting Started

### Prerequisites

- Flutter 3.x
- Windows 10/11 x64
- Visual Studio 2022 with **Desktop development with C++** workload

### Bundled binaries

Place these files before building:

| File | Path | Source |
|------|------|--------|
| `xray.exe` | `assets/xray/xray.exe` | [XTLS/Xray-core releases](https://github.com/XTLS/Xray-core/releases/latest) — `Xray-windows-64.zip` |
| `tun2socks.exe` | `assets/tun2socks/tun2socks.exe` | [xjasonlyu/tun2socks releases](https://github.com/xjasonlyu/tun2socks/releases/latest) — `tun2socks-windows-amd64.exe` |
| `wintun.dll` | `assets/tun2socks/wintun.dll` | [wintun.net](https://www.wintun.net) — `amd64/wintun.dll` |
| `*.ico` | `assets/tray/` | your own tray icons |

### Build

```bash
flutter pub get
flutter build windows
```

The output is at `build\windows\x64\runner\Release\vpn_client.exe`.

> **TUN mode requires the app to run as Administrator.** The manifest is already configured with `requireAdministrator`.

### Run in development

Open a terminal **as Administrator**, then:

```bash
flutter run -d windows
```

---

## Usage

1. Launch the app (UAC prompt will appear for admin rights)
2. Click the **gear icon** → paste your `vless://...` invite link → **Save**
3. Choose mode with the toggle at the bottom:
   - **System Proxy** — browsers and most apps
   - **TUN Tunnel** — all OS traffic
4. Tap the shield button to connect
5. Closing the window minimizes to tray. Right-click the tray icon → **Exit** to quit

---

## Roadmap

- [x] Windows — System Proxy mode
- [x] Windows — TUN Tunnel mode
- [x] System tray with live status
- [ ] Android support
- [ ] iOS support
- [ ] Auto-reconnect on network change
- [ ] Multiple server profiles

---

## Dependencies

| Package | Purpose |
|---------|---------|
| `window_manager` | Window controls, prevent-close → minimize to tray |
| `tray_manager` | System tray icon and context menu |
| `windows_single_instance` | Single app instance enforcement |
| `shared_preferences` | Persistent config storage |
| `path_provider` | AppData directory for extracted binaries |
| `flutter_v2ray` | Android VPN backend (WIP) |

---

## License

MIT
