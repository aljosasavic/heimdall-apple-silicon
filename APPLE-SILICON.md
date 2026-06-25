# Heimdall on Apple Silicon — flash Samsung Galaxy natively from an M-series Mac

A fork of [grimler's Heimdall](https://git.sr.ht/~grimler/Heimdall) (v2.2.2) with a
small but crucial fix that lets it flash **full stock firmware — including the huge
`SUPER` partition — natively on Apple Silicon Macs (M1/M2/M3/M4)**, with **no Windows,
no Linux, and no VM**.

✅ Tested end-to-end: **Galaxy S22 (SM-S901B)** fully restored from a **MacBook with M4**,
macOS 26, soft-bricked with `set_policy_failed`.

---

## The problem

On Apple Silicon macOS, stock Heimdall detects the phone, handshakes, and flashes the
*small* partitions fine — then **dies on the first large bulk transfer** (e.g. `SUPER`,
~9 GB) with:

```
Uploading SUPER
5%  libusb: error [submit_bulk_transfer] bulk transfer failed (dir = Out): pipe is stalled (code = 0xe000404f)
... (repeats) ...
ERROR: Failed to send file part packet!
ERROR: SUPER upload failed!
```

macOS halts (`kIOUSBPipeStalled`) the bulk OUT endpoint partway through a long transfer.
Upstream Heimdall's retry loop re-issued the same transfer **without clearing the halted
pipe**, so every retry hit the identical stall and the flash aborted.

## The fix

When a bulk transfer fails with `LIBUSB_ERROR_PIPE`, call `libusb_clear_halt()` on the
endpoint **before** retrying. The pipe un-stalls and the transfer continues. Applied to
both `SendBulkTransfer` and `ReceiveBulkTransfer` in `heimdall/source/BridgeManager.cpp`
(see `PATCH.diff`). Ten lines; that's the whole fix.

With it, a full multi-GB firmware flash completes natively from the Mac.

---

## Build (macOS, Apple Silicon)

```bash
brew install cmake libusb pkgconf       # build deps
cd heimdall-apple-silicon
cmake -B build -DCMAKE_BUILD_TYPE=Release -DDISABLE_FRONTEND=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build build -j
sudo cp build/bin/heimdall /opt/homebrew/bin/heimdall
```

(A prebuilt arm64 binary is in `prebuilt/heimdall-macos-arm64` if you'd rather not build.)

---

## Flash a full stock firmware (the whole workflow)

1. **Download the firmware** for your exact model/region (e.g. from samfw.com). You get a
   zip with `BL_*.tar.md5`, `AP_*.tar.md5`, `CP_*.tar.md5`, `CSC_*.tar.md5`. Put them in a
   folder, e.g. `~/firmware`.

2. **Run the helper** (extracts the tars, lz4-decompresses every image, reads the
   partition→file mapping straight out of the firmware's own PIT, and flashes everything):

   ```bash
   brew install lz4
   sudo ./flash-firmware.sh ~/firmware
   ```

3. Put the phone in **Download mode** first (Vol-Down + Vol-Up, then plug in USB, Vol-Up to
   confirm). `sudo` is required so libusb can claim the USB interface on macOS.

The script asks Heimdall to print the bundled `.pit` offline, maps each `*.img`/`*.bin` to
its partition name, and issues one `heimdall flash --<PARTITION> <file> ...` for the lot.

> ⚠️ This wipes the device (it flashes `USERDATA`/`CSC`). For a no-wipe flash use the
> `HOME_CSC` instead of `CSC` and drop `userdata.img`.

---

## Credits & license

- Original: **Benjamin Dobell** — Glass Echidna Heimdall.
- Maintained fork: **~grimler** (modern device + protocol support, the `v2.2.2` base here).
- Apple-Silicon large-transfer stall fix: this fork.

Licensed under the **MIT License** (see `LICENSE`), same as upstream Heimdall.
