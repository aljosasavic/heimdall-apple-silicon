#!/bin/bash
# Build (patched) Heimdall CLI on Apple Silicon macOS and install it to /opt/homebrew/bin.
# Deps:  brew install cmake libusb pkgconf
set -e
cd "$(dirname "$0")"

export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:/opt/homebrew/opt/libusb/lib/pkgconfig:$PKG_CONFIG_PATH"

cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DDISABLE_FRONTEND=ON \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build build -j

echo
echo "Built: $(pwd)/build/bin/heimdall"
if [ -w /opt/homebrew/bin ]; then
  cp build/bin/heimdall /opt/homebrew/bin/heimdall
  echo "Installed: /opt/homebrew/bin/heimdall  ($(heimdall version 2>/dev/null | head -1))"
else
  echo "Run: sudo cp build/bin/heimdall /opt/homebrew/bin/heimdall"
fi
