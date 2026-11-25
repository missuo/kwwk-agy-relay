#!/usr/bin/env bash
# Build a static (musl) Linux binary of kwwk-agy-relay.
#
# Needs an open-source Swift toolchain (swiftly) and the static Linux SDK
# for exactly that version; installs the SDK when it is missing.
#   Scripts/build-linux-static.sh [x86_64|aarch64] [swift-version]
set -euo pipefail
arch="${1:-x86_64}"
version="${2:-6.4.2}"
cd "$(dirname "$0")/.."

swift_run() { swiftly run swift "$@" "+${version}"; }
sdk="swift-${version}-RELEASE_static-linux-0.1.0"
if ! swift_run sdk list | grep -qx "$sdk"; then
    tmp="$(mktemp -d)"
    file="${sdk}.artifactbundle.tar.gz"
    curl -fsSL --retry 3 -o "$tmp/$file" \
        "https://download.swift.org/swift-${version}-release/static-sdk/swift-${version}-RELEASE/${file}"
    swift_run sdk install "$tmp/$file"
    rm -rf "$tmp"
fi

swiftly run swift build "+${version}" -c release \
    --swift-sdk "$sdk" --triple "${arch}-swift-linux-musl" \
    --scratch-path .build-linux --product kwwk-agy-relay

built="$(find .build-linux -type f -name kwwk-agy-relay -path "*${arch}*" -perm -u+x | head -n1)"
mkdir -p dist
out="dist/kwwk-agy-relay-linux-${arch}"
objcopy="$(swiftly run which llvm-objcopy "+${version}" 2>/dev/null || command -v llvm-objcopy || true)"
if [[ -n "$objcopy" ]]; then
    "$objcopy" --strip-all "$built" "$out"
else
    cp "$built" "$out"
fi
echo "$out ($(du -h "$out" | cut -f1))"
