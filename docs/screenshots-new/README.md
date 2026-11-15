# New UI screenshots (for review)

Rendered from the app with `./scripts/make-screenshots.sh --out docs/screenshots-new` on macOS 15 (CI),
at 2x, with neutral sample data (device name "MacBook Pro", sample phones). Nothing here is used by the
README or the documentation site yet; `docs/images/` still holds the old popover screenshots.

## App icon

An original mark: an S of two arcs with ball ends, its middle bar split into two arrows meeting in the
centre (send → ← receive). Drawn by `scripts/make-icon.swift`. On macOS 26 with the Dark icon style,
macOS darkens it automatically (charcoal tile, blue S).

![App icon](app-icon.png)

## Main window

The main window has a sidebar with four pages: **Send** (⌘1), **Receive** (⌘2), **History** (⌘3) and
**Settings** (⌘,). The sidebar shows a badge when a request is waiting or a transfer is running, and the
bottom of the sidebar shows whether this Mac can be found.

## Send

| Light | Dark |
|---|---|
| ![](window-send-light.png) | ![](window-send-dark.png) |

**Busy:** a received link (banner with Open Link / Copy), a request waiting (strip with Accept and
Decline), an item to send, progress rings and PIN on the devices, a declined send, and the transfers
in progress.

| Light | Dark |
|---|---|
| ![](window-send-busy-light.png) | ![](window-send-busy-dark.png) |

| Searching (no devices yet) | QR code (experimental) |
|---|---|
| ![](window-searching.png) | ![](window-qr.png) |

## Receive

| Light | Dark |
|---|---|
| ![](window-receive-light.png) | ![](window-receive-dark.png) |

**Busy:** a request with its PIN, and a transfer coming in.

| Light | Dark |
|---|---|
| ![](window-receive-busy-light.png) | ![](window-receive-busy-dark.png) |

## History

Search with ⌘F; click a row and press Return (or double-click) to open it.

| Light | Dark |
|---|---|
| ![](window-history-light.png) | ![](window-history-dark.png) |

## Settings

| Light | Dark |
|---|---|
| ![](window-settings-light.png) | ![](window-settings-dark.png) |

| General | Trusted Devices | Diagnostics |
|---|---|---|
| ![](settings-general.png) | ![](settings-trusted.png) | ![](settings-diagnostics.png) |

## Menu bar menu

| Busy, light | Busy, dark | Idle, light | Idle, dark |
|---|---|---|---|
| ![](menu-light.png) | ![](menu-dark.png) | ![](menu-idle-light.png) | ![](menu-idle-dark.png) |

The menu is a real macOS menu; these images show its custom rows (status, request, transfers) as they
render, with the standard items drawn alongside for reference.

![Menu bar icon states](menubar-icons.png)

## Incoming request

As it appears on the Receive page. There is no pop-up window: requests arrive as a notification with
Accept and Decline, and wait in the window and the menu bar.

| Light | Dark |
|---|---|
| ![](request-light.png) | ![](request-dark.png) |

Received links and text arrive as a notification with Open Link and Copy, and as a banner in the
window (see Send, busy). No window pops up.
