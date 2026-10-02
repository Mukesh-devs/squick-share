# Vendored protocol definitions

These `.proto` files are copied **unmodified** from Google's Apache-2.0 repositories.
They are not taken from NearDrop or RQuickShare. See `LICENSE-APACHE-2.0`.

| File | Upstream path | Repository @ commit |
|---|---|---|
| `google-nearby/connections/implementation/proto/offline_wire_formats.proto` | same | https://github.com/google/nearby @ `640b7090af3b72018d62086d3e639393d5d6877a` |
| `google-nearby/sharing/proto/wire_format.proto` | same | google/nearby @ `640b7090` |
| `google-nearby/proto/sharing_enums.proto` | same | google/nearby @ `640b7090` |
| `google-ukey2/ukey.proto` | `src/main/proto/ukey.proto` | https://github.com/google/ukey2 @ `10fc737aa901e873a3367e7e26b88eb01cd55d69` |
| `google-ukey2/securegcm.proto` | `src/main/proto/securegcm.proto` | google/ukey2 @ `10fc737a` |
| `google-ukey2/securemessage.proto` | `src/main/proto/securemessage.proto` | google/ukey2 @ `10fc737a` |
| `google-ukey2/device_to_device_messages.proto` | `src/main/proto/device_to_device_messages.proto` | google/ukey2 @ `10fc737a` |

`wire_format.proto` imports `google/protobuf/timestamp.proto`, a well-known type that ships
with the swift-protobuf runtime, so it is not vendored here.

Regenerate the Swift code with `scripts/generate-protos.sh`.
