#!/bin/bash
# Flash a full Samsung stock firmware with (patched) Heimdall on Apple Silicon macOS.
#
# Usage:  sudo ./flash-firmware.sh <firmware-dir> [test|test-flash]
#   <firmware-dir>  folder containing BL_*.tar.md5 AP_*.tar.md5 CP_*.tar.md5 CSC_*.tar.md5
#   test            only read the PIT off the phone (no writes) to verify USB works
#   test-flash      build and validate flash mapping, but do not write to device
#
# Phone must be in Download mode and connected. Requires: heimdall (this fork), lz4, tar.
set -e

FWDIR="${1:?usage: sudo ./flash-firmware.sh <firmware-dir> [test|test-flash]}"
MODE="${2:-flash}"
HEIMDALL="$(command -v heimdall || echo /opt/homebrew/bin/heimdall)"
WORK="$FWDIR/.heimdall-work"

if [ "$MODE" = "test" ]; then
  echo ">>> Reading PIT from the device (proves USB transfers work, writes nothing)..."
  exec "$HEIMDALL" print-pit --no-reboot
fi

if [ "$MODE" != "flash" ] && [ "$MODE" != "test-flash" ]; then
  echo "ERROR: mode must be one of: flash, test, test-flash"
  exit 1
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
echo ">>> 2) Mapping firmware flash filenames to live device partition names ..."

DEVPIT_TXT="$WORK/device.pit.txt"
"$HEIMDALL" print-pit --no-reboot >"$DEVPIT_TXT" 2>/dev/null || {
  echo "ERROR: failed to read live device PIT"
  exit 1
}

ARGS=()
TOTAL_MAPPABLE=0
MISSING=()
MAPFILE="$WORK/.flash-map.txt"
: > "$MAPFILE"
while read -r part fn; do
  part="${part//$'\r'/}"
  fn="${fn//$'\r'/}"
  part="${part## }"
  part="${part%% }"
  fn="${fn## }"
  fn="${fn%% }"
  [ -z "$fn" ] && continue

  img="$WORK/$fn"
  if [ ! -e "$img" ]; then
    matches=()
    while IFS= read -r m; do
      matches+=("$m")
    done < <(find "$WORK" -maxdepth 1 -type f -iname "$fn" -print 2>/dev/null)

    if [ ${#matches[@]} -gt 1 ]; then
      echo "ERROR: ambiguous image match for PIT filename '$fn':"
      printf '   %s\n' "${matches[@]}"
      echo "Refusing to continue to avoid flashing the wrong file."
      exit 1
    fi

    if [ ${#matches[@]} -eq 1 ]; then
      img="${matches[0]}"
    else
      img=""
    fi
  fi

  if [ -n "$img" ]; then
    existing_img="$(awk -F'|' -v p="$part" '$1==p {print $2; exit}' "$MAPFILE")"
    if [ -n "$existing_img" ]; then
      if [ "$existing_img" = "$img" ]; then
        continue
      fi
      echo "ERROR: conflicting mapping for partition '$part':"
      echo "   $existing_img"
      echo "   $img"
      echo "Refusing to continue to avoid flashing the wrong file."
      exit 1
    fi

    echo "$part|$img" >> "$MAPFILE"
    ARGS+=(--"$part" "$img")
    echo "   $part <- $(basename "$img")"
    TOTAL_MAPPABLE=$((TOTAL_MAPPABLE + 1))
  else
    MISSING+=("$part:$fn")
  fi
done < <(awk '
  FNR==NR {
    if ($1=="Partition" && $2=="Name:") d_part=$3;
    else if ($1=="Flash" && $2=="Filename:") {
      d_fn=$3;
      if (d_part!="" && d_fn!="" && d_fn!="-") dev[d_fn]=d_part;
      d_part=""; d_fn="";
    }
    next;
  }
  {
    if ($1=="Flash" && $2=="Filename:") f_fn=$3;
    else if ($1=="Partition" && $2=="Name:") {
      f_part=$3;
      if (f_fn!="" && f_fn!="-" && (f_fn in dev)) print dev[f_fn], f_fn;
      f_fn=""; f_part="";
    }
  }
' "$DEVPIT_TXT" <("$HEIMDALL" print-pit --file "$PIT" 2>/dev/null))

if [ ${#MISSING[@]} -gt 0 ]; then
  echo ">>> Missing firmware files referenced by PIT mapping:"
  printf '   %s\n' "${MISSING[@]}"
fi

[ ${#ARGS[@]} -eq 0 ] && { echo "ERROR: nothing to flash (no image matched the PIT)"; exit 1; }

if [ "$MODE" = "test-flash" ]; then
  echo ">>> test-flash: planned flash has $TOTAL_MAPPABLE partition/file pair(s)."
  if [ ${#MISSING[@]} -gt 0 ]; then
    echo "RESULT: READY WITH WARNINGS (some PIT-referenced files are missing, but they are not part of the planned flash args)."
    echo "The flash command should still run with the mapped files shown above."
    echo "Review missing entries to decide whether a partial flash is acceptable for your use case."
    echo "Flash command preview (formatted for readability):"
    printf '   - %q\n' "$HEIMDALL" flash "${ARGS[@]}"
    exit 0
  fi

  echo "RESULT: READY (no missing mapped files)."
  echo "Command preview (one arg per line):"
  printf '   - %q\n' "$HEIMDALL" flash "${ARGS[@]}"
  exit 0
fi

echo ">>> 3) Flashing ${#ARGS[@]} partitions (device reboots when done)..."
"$HEIMDALL" flash "${ARGS[@]}"
