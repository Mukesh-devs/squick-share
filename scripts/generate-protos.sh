#!/usr/bin/env bash
# Regenerates the Swift protobuf types for QuickShareCore from the vendored
# Google .proto files (see Packages/QuickShareCore/proto/SOURCES.md).
#
# Requires: protoc and protoc-gen-swift (brew install protobuf swift-protobuf).
# The protoc-gen-swift version must not be newer than the swift-protobuf
# runtime pinned in Packages/QuickShareCore/Package.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/Packages/QuickShareCore"
SRC="$PKG/proto"
OUT="$PKG/Sources/QuickShareCore/Protos"

command -v protoc >/dev/null || { echo "protoc not found" >&2; exit 1; }
command -v protoc-gen-swift >/dev/null || { echo "protoc-gen-swift not found" >&2; exit 1; }

rm -f "$OUT"/*.pb.swift

# Generated types stay internal so they never leak into QuickShareCore's public API.
OPTS="--swift_opt=Visibility=Internal --swift_opt=FileNaming=PathToUnderscores"

protoc $OPTS --proto_path="$SRC/google-nearby" --swift_out="$OUT" \
  connections/implementation/proto/offline_wire_formats.proto \
  sharing/proto/wire_format.proto \
  proto/sharing_enums.proto

protoc $OPTS --proto_path="$SRC/google-ukey2" --swift_out="$OUT" \
  ukey.proto securegcm.proto securemessage.proto device_to_device_messages.proto

echo "Generated with $(protoc --version), $(protoc-gen-swift --version):"
ls -1 "$OUT"
