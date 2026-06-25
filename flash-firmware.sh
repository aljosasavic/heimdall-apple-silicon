#!/bin/bash
# Flash a full Samsung stock firmware with (patched) Heimdall on Apple Silicon macOS.
#
# Usage:  sudo ./flash-firmware.sh <firmware-dir> [test]
#   <firmware-dir>  folder containing BL_*.tar.md5 AP_*.tar.md5 CP_*.tar.md5 CSC_*.tar.md5
#   test            only read the PIT off the phone (no writes) to verify USB works
#
# Phone must be in Download mode and connected. Requires: heimdall (this fork), lz4, tar.
set -e

FWDIR="${1:?usage: sudo ./flash-firmware.sh <firmware-dir> [test]}"
MODE="${2:-flash}"
HEIMDALL="$(command -v heimdall || echo /opt/homebrew/bin/heimdall)"
WORK="$FWDIR/.heimdall-work"

if [ "$MODE" = "test" ]; then
  echo ">>> Reading PIT from the device (proves USB transfers work, writes nothing)..."
  exec "$HEIMDALL" print-pit --no-reboot
fi

echo ">>> 1) Extracting tarballs and lz4-decompressing images into $WORK ..."
mkdir -p "$WORK"; cd "$WORK"
for t in "$FWDIR"/BL_*.tar.md5 "$FWDIR"/AP_*.tar.md5 "$FWDIR"/CP_*.tar.md5 "$FWDIR"/CSC_*.tar.md5; do
  [ -e "$t" ] && { echo "   $(basename "$t")"; tar xf "$t" 2>/dev/null || true; }
done
for f in *.lz4; do
  [ -e "$f" ] || continue
  out="${f%.lz4}"; [ -e "$out" ] || lz4 -d -q "$f" "$out"
done

PIT="$(ls "$WORK"/*.pit 2>/dev/null | head -1)"
[ -z "$PIT" ] && { echo "ERROR: no .pit found in firmware (it's usually inside CSC)"; exit 1; }
echo ">>> 2) Mapping partitions from $(basename "$PIT") ..."

ARGS=()
while read -r part fn; do
  [ -z "$fn" ] && continue
  if [ -e "$WORK/$fn" ]; then ARGS+=(--"$part" "$WORK/$fn"); echo "   $part <- $fn"; fi
done < <("$HEIMDALL" print-pit --file "$PIT" 2>/dev/null | awk '
  /Partition Name:/{name=$3}
  /Flash Filename:/{fn=$3; if(fn!="" && fn!="-") print name, fn}')

[ ${#ARGS[@]} -eq 0 ] && { echo "ERROR: nothing to flash (no image matched the PIT)"; exit 1; }

echo ">>> 3) Flashing ${#ARGS[@]} partitions (device reboots when done)..."
"$HEIMDALL" flash "${ARGS[@]}"
