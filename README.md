# squick-share

A native macOS menu bar app, written in Swift, that speaks Google's **Quick Share** protocol (formerly Nearby Share) over Wi-Fi.
It sends and receives files, folders, text and links with Android phones, Quick Share for Windows and RQuickShare on Linux.

> **Status:** feature-complete for Wi-Fi LAN. It works Mac-to-Mac and passes 74 automated tests,
> but it has **not yet been tested with a real Android phone, Windows PC or Linux machine**.
> See [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) and [docs/TESTING.md](docs/TESTING.md).

## Features

- **Receive** from phones: an accept/decline prompt and a notification with the sender, files, sizes and the **4-digit PIN**. Files stream to your chosen folder (default `~/Downloads`). Duplicate names get " (1)", " (2)". Received links get **Open Link** and **Copy**. Nothing is ever opened automatically.
- **Send** files, folders (relative paths preserved), text and links. Drop them on the menu bar popover, use **Choose Files…**, or use **Share › squick-share** in Finder and Safari.
- **QR code** pairing for phones that aren't discoverable (Android only shows itself while its Receive screen is open; Samsung phones need the QR code).
- Live **progress, speed and ETA**, cancel on both sides, and recent transfers with **Show in Finder**.
- **Visibility**: Everyone, Hidden, or Visible for 10 minutes (with a countdown).
- **Trusted devices**: optional auto-accept from devices you approved once.
- **Diagnostics**: verbose protocol logging and **Copy Diagnostic Log** (no file contents, names, paths or keys), plus advanced toggles for protocol details that still need device testing.
- Launch at login, notifications on/off, limit to Wi-Fi or Ethernet, light and dark mode, VoiceOver labels.

## Requirements

- macOS 13 Ventura or later, on Apple Silicon or Intel.
- The Mac and the other device on the **same Wi-Fi network** (not a guest network that isolates devices).
- To build: Xcode 15 or later (tested with Xcode 26).

## Install (build from source)

```sh
git clone <this repo> squick-share && cd squick-share
./scripts/build-release.sh --install       # universal Release build, ad-hoc signed, installed to /Applications
```

On first launch, **allow Local Network access** (essential) and notifications.
To use the Finder/Safari share menu, enable **squick-share** under System Settings › General › Login Items & Extensions › Sharing (macOS 15+), or Privacy & Security › Extensions › Sharing (macOS 13–14).

### Signing options

| Option | Command | Runs on |
|---|---|---|
| Ad-hoc (default) | `./scripts/build-release.sh` | The Mac that built it. Other Macs: right-click › Open, or `xattr -dr com.apple.quarantine squick-share.app`. |
| Free Apple ID ("Personal Team") | `TEAM_ID=XXXXXXXXXX ./scripts/build-release.sh` | Your Macs. Find the team ID in Xcode › Settings › Accounts. |
| Developer ID + notarization | `TEAM_ID=… SIGN_IDENTITY="Developer ID Application" NOTARY_PROFILE=notary ./scripts/build-release.sh` | Any Mac. Needs the paid Apple Developer Program; create the profile with `xcrun notarytool store-credentials`. |

The app has App Sandbox and Hardened Runtime turned on. Bundle ID: `tech.mukesh.squick-share` (set in `project.yml`).

## Using it

- **Receive**: on the phone, Share › **Quick Share** › pick your Mac. Check the PIN matches, then click **Accept**.
- **Send**: drop files on the popover and click the phone in the list. If it isn't listed, open **Files › Quick Share › Receive** on the phone, or click **Show QR Code** and scan it.
- On Xiaomi/Redmi phones, use **Quick Share** (Google), not "Xiaomi Share".

Troubleshooting steps are in [docs/TESTING.md](docs/TESTING.md#if-the-mac-does-not-appear-on-the-phone).

## Supported and not supported

| | |
|---|---|
| Supported | Wi-Fi LAN (mDNS/Bonjour + TCP): send and receive files, folders, text and links. QR-code pairing. |
| Not supported | **Wi-Fi Direct** and Wi-Fi hotspot mediums (not available to normal macOS apps). **WebRTC relay** over the internet. Google-account **"Your devices" / "Contacts"** visibility (needs Google servers; use Everyone). Bluetooth transfers and BLE discovery. Wi-Fi credentials, app (APK) and stream attachments. |
| Known limits | Both devices must be on the same network. Android phones are only discoverable from the Mac while their Receive screen is open (or through the QR code). Zero-byte files are skipped (Google receivers reject them). Trusted devices are recognized by name and type only. |

## Security

- Every incoming name is sanitized: path separators, `..`, control and bidi-override characters, leading dots, and length. Files are written only inside the chosen folder, and symlinks in the path are refused.
- Strict frame ordering: no payloads before UKEY2 completes and you accept. Limits on frame size (5 MiB), file count, text size and total size (free-space check). Timeouts for every protocol stage.
- Encrypted channel: UKEY2 (P-256 ECDH) with AES-256-CBC + HMAC-SHA256. The MAC is checked in constant time before decrypting, and sequence numbers are strict.
- Logs use `os.Logger` and contain no file contents, file names, paths or keys. Keys and IDs come from the system's secure random generator.
- Received files are never opened automatically.

## Project layout

```
SquickShare.xcodeproj         generated from project.yml (XcodeGen); committed
SquickShare/                  app: SwiftUI menu bar UI, settings, notifications
ShareExtension/               Finder / Safari share extension
Packages/QuickShareCore/      protocol, crypto, networking; no UI (Swift 6 language mode)
  proto/                      Google's Apache-2.0 .proto files, unmodified (see SOURCES.md)
  Sources/QuickShareCore/     Crypto/, Transport/, Discovery/, Transfer/, Protos/ (generated)
  Sources/SquickShareCLI/     squick-share-cli: receive / send / browse from Terminal
  Tests/QuickShareCoreTests/  unit, loopback, fuzz and mDNS integration tests
docs/                         PROTOCOL_NOTES, COMPATIBILITY, TESTING
scripts/                      build-release, generate-protos, gen-test-vectors.py, make-icon
```

The public API of `QuickShareCore` is small (`QuickShareReceiver`, `QuickShareSender`, `NearbyBrowser`, `QRCodeSession`, plus value types), so it could be replaced with another core later.

## Development

```sh
cd Packages/QuickShareCore && swift test           # 74 tests, about 20 s
swift run squick-share-cli receive --verbose        # receive in Terminal
xcodegen generate                                   # after editing project.yml (brew install xcodegen)
./scripts/generate-protos.sh                        # after changing .proto files (brew install protobuf swift-protobuf)
python3 scripts/gen-test-vectors.py                 # regenerate independent crypto vectors (pip install cryptography)
```

Debug builds understand `squickshare://debug-snapshot` (renders the main views to PNGs in the app's temporary folder) and
`squickshare://debug-send?to=NAME`. Release builds do not include these hooks.

## Credits and licenses

- Protocol definitions: Google's [nearby](https://github.com/google/nearby) and [ukey2](https://github.com/google/ukey2) repositories (Apache-2.0). The `.proto` files are vendored unmodified with their license in `Packages/QuickShareCore/proto/`.
- squick-share's own code doesn't have a license yet. Choose one before publishing.
