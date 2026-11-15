# New UI screenshots (for review)

Rendered from the app with `./scripts/make-screenshots.sh --out docs/screenshots-new` on macOS 15 (CI),
at 2x, with neutral sample data (device name "MacBook Pro", sample phones). Nothing here is used by the
README or the documentation site yet; `docs/images/` still holds the old popover screenshots.

## App icon

An original mark: an S of two arcs with ball ends, its middle bar split into two arrows meeting in the
centre (send → ← receive), on a rich Apple-style blue (sky blue at the top to deep blue at the
bottom). The app's accent colour uses the same blue. Drawn by `scripts/make-icon.swift`. On macOS 26 with the Dark icon style,
macOS darkens it automatically (charcoal tile, blue S).

![App icon](app-icon.png)

## Main window

The main window has a sidebar with four pages: **Send** (⌘1), **Receive** (⌘2), **History** (⌘3) and
**Settings** (⌘,). The sidebar shows a badge when a request is waiting or a transfer is running, and the
"This Mac" card at the bottom shows whether this Mac can be found. The toolbar's buttons change with the
page: Send Text and Choose Files on Send, the Downloads folder on Receive, a filter and search on
History, and a search field on Settings.

## Welcome

Shown once, the first time the window opens.

| Light | Dark |
|---|---|
| ![](welcome-light.png) | ![](welcome-dark.png) |

## Send

| Light | Dark |
|---|---|
| ![](window-send-light.png) | ![](window-send-dark.png) |

**Busy:** a request waiting (strip with Accept and Decline), progress rings and the PIN on the devices,
a finished send, and a transfer in progress with its document icons.

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

**Busy:** a request with its document icons, PIN digits, Accept and Decline, and a transfer coming in.

| Light | Dark |
|---|---|
| ![](window-receive-busy-light.png) | ![](window-receive-busy-dark.png) |

## History

Grouped by day. Filter with All / Received / Sent, search with ⌘F, double-click (or select and press
Return) to open, right-click for Show in Finder, Copy and Remove, or drag a received file out to Finder.

| Light | Dark |
|---|---|
| ![](window-history-light.png) | ![](window-history-dark.png) |

## Settings

| Light | Dark |
|---|---|
| ![](window-settings-light.png) | ![](window-settings-dark.png) |

| Search | Trusted Devices | Diagnostics |
|---|---|---|
| ![](settings-search.png) | ![](settings-trusted.png) | ![](settings-diagnostics.png) |

## Menu bar menu

| Busy, light | Busy, dark | Idle, light | Idle, dark |
|---|---|---|---|
| ![](menu-light.png) | ![](menu-dark.png) | ![](menu-idle-light.png) | ![](menu-idle-dark.png) |

The menu is a real macOS menu; these images show its custom rows (status, request, transfers) as they
render, with the standard items drawn alongside for reference.

![Menu bar icon states](menubar-icons.png)

## Requests and received text

There is no pop-up window: requests arrive as a notification with Accept and Decline, and wait on the
Receive page (see Receive, busy) and in the menu bar. Received links and text arrive as a notification
with Open Link and Copy, and as a banner in the window. No window pops up.
