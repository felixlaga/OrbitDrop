#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/tests
SOURCES=()
for SOURCE in Sources/OrbitDrop/*.swift; do
  if [ "$(basename "$SOURCE")" != main.swift ]; then SOURCES+=("$SOURCE"); fi
done
for TEST in Tests/*Tests.swift; do
  NAME="$(basename "$TEST" .swift)"
  xcrun swiftc -swift-version 5 "${SOURCES[@]}" "$TEST" -o "build/tests/$NAME" -framework AppKit -framework PDFKit -framework Vision -framework CoreImage -framework UniformTypeIdentifiers
  "build/tests/$NAME"
done
echo "All offline tests passed. No app windows were opened."
