[中文](README.md) | **English**

# PocketStudio

A native macOS app that talks to DJI Osmo Pocket cameras over **Bluetooth and Wi-Fi**: live view, recording the stream on the Mac, photo / video / mode switching, and gimbal control from the keyboard, trackpad, or an on-screen stick. Battery, SD card, and gimbal attitude are shown in the UI.

The name has no model number on purpose. **Osmo Pocket 3 works today.** The project is laid out as a family, so Pocket 4 / Pocket 4P can be added later. The interface is Simplified Chinese. The app is pure Swift and AppKit — no SwiftUI.

The protocol is a byte-for-byte port of [sniffingpickles/DJI-Wifi-Connect](https://github.com/sniffingpickles/DJI-Wifi-Connect). Gimbal recenter / mode commands also follow [yigitkonur/lib-osmo-ble](https://github.com/yigitkonur/lib-osmo-ble) and field captures from [OpenPocketCine](https://opencapture.org/openpocketcine/docs/). Protocol notes, concurrency rules, and what real-device logs showed are in [AGENTS.md](AGENTS.md) (Chinese).

> Educational and research software. Not affiliated with DJI. The protocol comes from community reverse engineering and can change with firmware. Released under the [MIT License](LICENSE).
>
> Author: [@zqqf16](https://github.com/zqqf16)

Landing page: https://zqqf16.github.io/PocketStudio/

## Features

- Wake the camera Wi-Fi hotspot over Bluetooth, join it, and finish the UDP handshake
- Hardware-decode the H.264 live view with VideoToolbox
- Shutter, start / stop recording, and switch capture modes (the shutter follows the current mode)
- Gimbal from keyboard, trackpad, drag-on-video, and an on-screen stick; recenter, Follow / Lock / FPV, and speed
- Battery, SD card, recording state, and gimbal attitude
- Save the live stream on the Mac (MP4 passthrough, or raw `.h264`)
- Reconnect with backoff after a drop; if a photo puts the camera into playback, the app tries to exit playback and restore the preview

## Requirements

| | |
|---|---|
| OS | macOS 26 (Tahoe) or later |
| Xcode | Xcode 26 or later (macOS 26 SDK) |
| Mac | Bluetooth 4.0+ and Wi-Fi |
| Camera | DJI Osmo Pocket 3 (Pocket 4 / 4P are not implemented yet) |
| Dependencies | None — system frameworks only |

## Build and run

`PocketStudio.xcodeproj` is already generated. Clone and open it.

```bash
git clone https://github.com/zqqf16/PocketStudio.git
cd PocketStudio
open PocketStudio.xcodeproj
```

1. Select the **PocketStudio** scheme and **My Mac**.
2. Signing defaults to Sign to Run Locally. If Xcode complains, open the PocketStudio target → **Signing & Capabilities** and pick your Apple ID as the team (a free account is enough).
3. Press **⌘R**. The first launch opens onboarding.
4. Run tests with **⌘U**.

After editing `project.yml`, regenerate the project:

```bash
brew install xcodegen
xcodegen generate
```

## First connection

1. **Quit DJI Mimo** completely on both the phone and the Mac. It holds the camera and the handshake will fail.
2. Turn the Pocket 3 on.
3. Grant the permissions onboarding asks for:
   - **Bluetooth** (required) wakes the camera hotspot.
   - **Local Network** (required) talks to the camera at `192.168.2.1:9004`.
   - **Location**. macOS requires it before an app may read the Wi-Fi name (SSID) and join the hotspot automatically. If you deny it, the connect page falls back to the copy-password steps.
4. You can leave the camera **Wi-Fi name and password** empty. **Auto-fetch Wi-Fi** is on by default: after pairing, the app reads the hotspot name and password from the camera and stores them in the Keychain per device. Fill them in if the read fails (newer firmware may encrypt the reply) or if you turn auto-fetch off. The name usually looks like `OsmoPocket3-XXXX`. On the camera: **swipe down from the top → Settings (gear) → Wireless / Wi-Fi**.
5. Click **Connect** in the toolbar. The app scans, pairs (the camera may ask you to confirm the first time), waits about 20 seconds for the hotspot, joins it, handshakes, starts video, and reports connected. Bluetooth stays up while Wi-Fi joins, then disconnects.

### When the system blocks it

| What you see | Why | What to do |
|---|---|---|
| Camera not found / Bluetooth permission denied | The first prompt was declined | System Settings → Privacy & Security → **Bluetooth** → enable PocketStudio, then relaunch |
| UDP handshake timeout | No Local Network permission, not on the camera Wi-Fi, or Mimo is still running | System Settings → Privacy & Security → **Local Network** → enable PocketStudio. Confirm the menu-bar Wi-Fi is the camera hotspot and quit DJI Mimo. If it still fails, switch on **BSD socket compatibility mode** in Settings, or turn off "send only on the Wi-Fi interface" |
| "Join the camera Wi-Fi manually" | macOS refused an automatic network switch (no Location permission, or MDM) | Copy the password, open Wi-Fi settings, select `OsmoPocket3-XXXX`, paste with ⌘V, join, then return to the app. It continues once it sees a `192.168.2.x` address (up to 3 minutes) |
| Hotspot missing from the list | It is not up yet | Wait about 20 seconds, or press Connect again so Bluetooth wakes it |
| Connected, but the view is black | No displayable picture yet | Refresh Video in the toolbar, or disconnect and connect again. The last frame stays on screen while it recovers |
| The Mac has no internet after connecting | The camera hotspot has no uplink | Expected. Disconnect and the Mac returns to the previous network |

The Local Network prompt is triggered with the Bonjour service `_pocketstudio._tcp`. Onboarding shows not requested / waiting / allowed / denied.

The App Sandbox is **off**. CoreWLAN's automatic Wi-Fi join is often denied inside the sandbox, and this app is not aimed at the App Store. The entitlements file already lists Bluetooth, network, location, and file access. Set `com.apple.security.app-sandbox` to `true` in `PocketStudio/Resources/PocketStudio.entitlements` if you need the sandbox (automatic Wi-Fi join may then fall back to the manual guide).

## Controls

| Action | How |
|---|---|
| Move the gimbal | Hold **arrow keys / W A S D** (release to stop); the stick at the lower left; drag on the picture; two-finger trackpad scroll |
| Slow move | **Q / E** (yaw), **R / F** (pitch) |
| E-stop the gimbal | **Esc**, **.**, or ⌘. |
| Recenter | **C** / ⌘0 |
| Gimbal speed | **1–9** (0.1–0.9), or the slider at the lower right |
| Shutter (photo, or start / stop recording, depending on mode) | **Space / Return**, or the round button under the picture (white = photo, red = record, red square = stop) |
| Photo | **P** / ⇧⌘P |
| Start / stop camera recording | **O** / ⇧⌘R |
| Cycle capture mode | The segmented control beside the shutter, or **M**. Locked while recording |
| Show / hide the picture | **V** |
| Stats | **I** |
| Record the stream on the Mac | Record to Mac in the toolbar / ⌥⌘R. Files go to Movies/PocketStudio, as MP4 or raw H.264 |
| Snapshot | Snapshot in the toolbar / ⇧⌘S (PNG) |
| Refresh video | ⌘R (rebuild the link after the old session is released; falls back to a Bluetooth wake) |
| Recenter / mode / speed / flip | Lower-right panel / ⌘0 |

After a drop, reconnect waits 1.5s, then 3s, 5s, 8s… and wakes the camera over Bluetooth again (rejoining its Wi-Fi if the Mac has left it). If a still sends the camera into playback and the preview stops, the app sends exit-playback. Gimbal packets are capped at 25 Hz so they don't stall the camera's command window.

## Layout

```
PocketStudio/
├── project.yml                  XcodeGen spec (regenerate after adding files or targets)
├── PocketStudio.xcodeproj       Generated Xcode project
├── PocketStudio/
│   ├── Core/                    Platform-neutral protocol (builds and tests on Linux)
│   ├── Platform/                Bluetooth, Wi-Fi, UDP, H.264 decode, recording
│   ├── App/                     Launch, menus, connection flow, settings
│   ├── Views/                   AppKit UI
│   └── Resources/               Info.plist, entitlements, app icon
├── PocketStudioTests/           Protocol, gimbal, camera commands, local fake-camera loopback
├── Tools/run-linux-tests.sh     SwiftPM test runner that does not need Xcode
├── LICENSE                      MIT
└── AGENTS.md                    Protocol and concurrency notes for contributors
```

Bundle ID: `com.pocketstudio.app`.

## Tests

```bash
# Swift 6.2+. On a Mac, the toolchain that ships with Xcode is enough.
./Tools/run-linux-tests.sh
# Run again with the default actor isolation set to nonisolated:
ISOLATION=nonisolated ./Tools/run-linux-tests.sh
```

The suite covers CRC, DUML, UDP headers / handshake / ACK, BLE frames, camera and gimbal commands, status parsing, H.264 access units, and a handshake-plus-video loopback against a fake camera on localhost. Reference bytes match the upstream Python project.

## Status

- **On a real Pocket 3:** connect, live view, and gimbal control work. The speed-command axis order `[pitch, roll, yaw]` is confirmed on device. Default sign of each axis is still worth checking in Settings; flip an axis there if it moves the wrong way.
- **Not supported yet:** Osmo Pocket 4, Pocket 4P, and other DJI cameras.
- **Protocol layer:** builds and unit-tests on macOS and Linux. AppKit, CoreBluetooth, and VideoToolbox code compiles on macOS only.

Limits, and the on-device bugs already chased down (a flooded command window, playback after a photo, a watchdog tearing down a healthy link), are written up in [AGENTS.md](AGENTS.md).

## Credits

- [sniffingpickles/DJI-Wifi-Connect](https://github.com/sniffingpickles/DJI-Wifi-Connect) — protocol source
- [eerimoq/moblin](https://github.com/eerimoq/moblin) — BLE pairing
- [yigitkonur/lib-osmo-ble](https://github.com/yigitkonur/lib-osmo-ble) — extra gimbal commands
- [OpenPocketCine](https://opencapture.org/openpocketcine/docs/) — Pocket 3 camera / gimbal commands and status fields
- [samuelsadok/dji_protocol](https://github.com/samuelsadok/dji_protocol) — UDP protocol notes

## License and contact

[MIT License](LICENSE) · Copyright © 2026 [zqqf16](https://github.com/zqqf16)

Bugs, device logs, and model support: open an [issue](https://github.com/zqqf16/PocketStudio/issues).
