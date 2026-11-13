# HeimdallFront (macOS app)

A SwiftUI front end for this patched Heimdall. It flashes a full Samsung stock firmware from an
Apple Silicon Mac, no Windows needed.

What it does:

1. **Choose** a firmware `.zip` (samfw, samfrew…) or a folder with its `BL_`/`AP_`/`CP_`/`CSC_` `.tar.md5` files.
   `HOME_CSC` is never used: flashing `CSC` is what changes the carrier code, and it **wipes the phone**.
2. **Verify & Extract** streams each archive once. It checks the MD5, decompresses every `.lz4` image straight
   to `~/Library/Caches/HeimdallFront/<firmware>/` and maps the images to partitions with the firmware's own PIT.
   Disk needed is about the firmware size, not 2-3x.
3. **Flash** runs a single Heimdall session with live per-partition progress. Enter Download Mode fresh
   right before flashing: the phone accepts one session per entry.

## Build

Needs the Xcode Command Line Tools (full Xcode isn't required) and Homebrew `libusb` + `lz4`.

```bash
brew install cmake libusb pkgconf lz4
../build.sh            # builds ../build/bin/heimdall
./build-app.sh         # runs the self-test, then builds build/HeimdallFront.app
open build/HeimdallFront.app
```

Headless use (verify, extract and map, without flashing):

```bash
build/HeimdallFront.app/Contents/MacOS/HeimdallFront --extract <firmware.zip|folder> <out-dir>
```

The app is ad-hoc signed and links Homebrew's `libusb`, so it runs on Macs that have
`brew install libusb lz4`.
