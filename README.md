# Heimdall for Apple Silicon

**Flash Samsung Galaxy stock firmware natively from an Apple Silicon Mac (M1/M2/M3/M4/M5) — no Windows, no Linux, no virtual machine.**

This is a fork of [grimler's Heimdall](https://git.sr.ht/~grimler/Heimdall) (v2.2.2) with a
small but crucial fix that makes a **full firmware flash — including the multi-gigabyte
`SUPER` partition — complete reliably on macOS**, where upstream Heimdall aborts partway.

> ✅ **Verified end-to-end:** a soft-bricked **Galaxy S22 (SM-S901B)** with `set_policy_failed`
> was fully restored from a **MacBook with an M4** running macOS 26 — entirely natively.
>
> The fix lives at the macOS USB layer (not anything chip-specific), and the binary is a
> universal `arm64` build, so it applies to **every Apple Silicon Mac — M1 through M5** and
> beyond. M4 is what was tested hands-on; M1–M3 and M5 use the exact same code path.

---

## TL;DR

```bash
# 1. Build (Apple Silicon)
brew install cmake libusb pkgconf lz4
./build.sh                      # produces build/bin/heimdall, installs to /opt/homebrew/bin

# 2. Put the phone in Download mode, then flash a firmware folder
sudo ./flash-firmware.sh ~/path/to/firmware-folder
```

The firmware folder is just the unzipped `BL_*.tar.md5 / AP_*.tar.md5 / CP_*.tar.md5 /
CSC_*.tar.md5` from a stock firmware download.

---

## The problem this fixes

On Apple Silicon macOS, stock Heimdall detects the phone, handshakes, and flashes the
*small* partitions fine — then **dies on the first large bulk transfer** (typically `SUPER`,
~9 GB):

```
Uploading SUPER
5%  libusb: error [submit_bulk_transfer] bulk transfer failed (dir = Out): pipe is stalled (code = 0xe000404f)
...repeats...
ERROR: Failed to send file part packet!
ERROR: SUPER upload failed!
```

macOS halts (`kIOUSBPipeStalled`) the bulk OUT endpoint partway through a long transfer.
Upstream Heimdall's retry loop re-issued the same transfer **without clearing the halted
pipe**, so every retry hit the identical stall and the whole flash aborted.

## The fix

When a bulk transfer fails with `LIBUSB_ERROR_PIPE`, call `libusb_clear_halt()` on the
endpoint **before** retrying. The pipe un-stalls and the transfer continues. Applied to both
`SendBulkTransfer` and `ReceiveBulkTransfer` in `heimdall/source/BridgeManager.cpp`.

Ten lines — the full diff is in [`PATCH.diff`](PATCH.diff):

```c
// If the endpoint stalled (common on macOS during large transfers like
// SUPER), the pipe stays halted until cleared - every retry would hit the
// same stall. Clear the halt before re-sending the packet.
if (result == LIBUSB_ERROR_PIPE)
    libusb_clear_halt(deviceHandle, outEndpoint);
```

---

## Full guide

### 1. Build

```bash
brew install cmake libusb pkgconf lz4
./build.sh
```

`build.sh` runs cmake with `-DDISABLE_FRONTEND=ON` (CLI only — no Qt needed) and copies the
binary to `/opt/homebrew/bin/heimdall`. A prebuilt arm64 binary may also be attached to the
GitHub Releases of this repo.

### 2. Get the firmware

Download the stock firmware for your **exact model and region** (e.g. from samfw.com or
samfrew.com). Unzip it — you'll get four files:

```
BL_<model>_..._.tar.md5     # bootloader
AP_<model>_..._.tar.md5     # system (large; contains super.img.lz4, boot, etc.)
CP_<model>_..._.tar.md5     # modem
CSC_<region>_..._.tar.md5   # region / carrier (this also contains the .pit)
```

Put all four in one folder. **Samsung firmware is cryptographically signed** — the phone
rejects anything not signed by Samsung, so a mirror cannot tamper with what actually flashes.

> `CSC_*` performs a factory wipe. To keep user data, use the `HOME_CSC_*` file instead.

### 3. Enter Download mode

Power off the phone, then hold **Volume Down + Volume Up** together and plug in the USB
cable. Press **Volume Up** to confirm at the warning screen.

### 4. Flash

```bash
sudo ./flash-firmware.sh ~/path/to/firmware-folder
```

`sudo` is required so libusb can claim the USB interface on macOS. The script:

1. extracts the tarballs and `lz4`-decompresses every partition image,
2. reads the partition→file mapping straight out of the firmware's own `.pit` (offline, via
   `heimdall print-pit --file`),
3. issues a single `heimdall flash --<PARTITION> <file> ...` for the whole set,
4. the phone reboots into a clean system when done.

**First boot after a full flash + wipe takes several minutes** — let it sit.

### Dry run (verify USB before writing anything)

```bash
sudo ./flash-firmware.sh ~/path/to/firmware-folder test
```

This only reads the PIT off the device — if it prints the partition table, your USB path
works and a real flash will succeed.

---

## How it works

Heimdall talks to the bootloader-level **Loke** software over USB using Samsung's "Odin 3"
protocol, with [libusb](https://libusb.info) doing the transfers. The only thing standing
between macOS and a successful flash was unrecovered endpoint stalls on large transfers —
see [the fix](#the-fix) above.

## Troubleshooting

- **`ERROR: Claiming interface failed!`** — another process holds the device (e.g. a VM with
  USB passthrough still running), or you're not `root`. Run with `sudo` and make sure nothing
  else has grabbed the phone.
- **`pipe is stalled` and it still aborts** — make sure you're running *this* build, not a
  Homebrew/old Heimdall (`which heimdall` should be `/opt/homebrew/bin/heimdall`).
- **Stuck on boot logo > 15 min** — re-enter Download mode and re-flash; a fresh USB state
  often helps.

## Credits & license

- Original Heimdall: **Benjamin Dobell**, [Glass Echidna](https://glassechidna.com.au/).
- Maintained fork (v2.2.2 base): **Henrik Grimler** — <https://git.sr.ht/~grimler/Heimdall>.
- Apple-Silicon large-transfer stall fix: this fork.

Licensed under the **MIT License** (see [`LICENSE`](LICENSE)), same as upstream. Upstream's
original README is preserved at [`docs/README-upstream.md`](docs/README-upstream.md).

## Disclaimer

Flashing firmware can wipe your data and, if interrupted, can brick a device. Use the correct
firmware for your exact model, don't disconnect mid-flash, and proceed at your own risk.
