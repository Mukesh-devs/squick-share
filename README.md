# squick-share

A native macOS menu bar client for Google's Quick Share (formerly Nearby Share), written in Swift.

**Status: Phase 0 (research) complete.** There is no app yet. See [`docs/PROTOCOL_NOTES.md`](docs/PROTOCOL_NOTES.md).

## Layout

- `Packages/QuickShareCore`: protocol, crypto and networking, with no UI. A Swift package.
  - `proto/`: Google's Apache-2.0 `.proto` files, vendored unmodified (see `proto/SOURCES.md`).
  - `Sources/QuickShareCore/Protos/`: generated Swift. Regenerate with `scripts/generate-protos.sh`.
- `docs/`: protocol notes, and later compatibility and testing docs.

## Build and test the core package

```sh
cd Packages/QuickShareCore
swift test
```

Regenerating protobuf code requires `brew install protobuf swift-protobuf`.

## Not supported

Wi-Fi Direct (not available to macOS apps), WebRTC relay, and Google-account "contacts" visibility.
