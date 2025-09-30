#!/usr/bin/env bash
# Secure firmware-level erasure with hardened fallbacks and verifiable reporting
# Targets: NVMe & ATA/SATA on Linux

set -euo pipefail

# -------- CONFIG --------
RETRY_MAX=10
VERIFY_SAMPLES=256          # random sector samples for verify
LOG_DIR="./"                # where to write JSON/PDF later; keep local for now
PASSPHRASE="pqliar"         # ATA security password (temporary, discarded after)
# ------------------------

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { red "Missing dependency: $1"; exit 127; }
}

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

json_escape() {
  python3 - <<'PY' "$1"
import json,sys
print(json.dumps(sys.argv[1]))
PY
}

device_short() {
  basename "$1" | tr -c '[:alnum:]_-' '_'
}

abort_if_root_device() {
  local dev="$1"
  # root FS backing device (e.g., /dev/nvme0n1p3). We will compare base disk.
  local root_src; root_src="$(findmnt -n -o SOURCE /)"
  # Normalize to base disk (/dev/nvme0n1 or /dev/sda)
  to_base() {
    local x="$1"
    # strip partition suffixes (nvme0n1p3 -> nvme0n1 ; sda3 -> sda)
    x="${x#/dev/}"
    echo "/dev/${x%%p*[0-9]}${x%%[0-9]}"
  }
  local root_base dev_base
  root_base="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"
  if [[ -n "$root_base" ]]; then root_base="/dev/$root_base"; else root_base="$(to_base "$root_src")"; fi
  dev_base="$(lsblk -no PKNAME "$dev" 2>/dev/null || true)"
  if [[ -n "$dev_base" ]]; then dev_base="/dev/$dev_base"; else dev_base="$(to_base "$dev")"; fi
  if [[ "$dev_base" == "$root_base" ]]; then
    red "Refusing to operate on the root/system disk: $dev_base"
    exit 9
  fi
}

ensure_unmounted() {
  local dev="$1"
  # Fail if any partition of the device is mounted
  if lsblk -nr -o MOUNTPOINT "$dev" | grep -q "/"; then
    red "Some partitions of $dev are mounted. Unmount all before proceeding."
    exit 10
  fi
}

retry() {
  local attempts=0
  local delay=2
  while true; do
    if "$@"; then return 0; fi
    attempts=$((attempts+1))
    if (( attempts >= RETRY_MAX )); then return 1; fi
    sleep "$delay"
    delay=$((delay*2)); if (( delay > 30 )); then delay=30; fi
  done
}

# HPA/DCO handling: force native max, then DCO restore
unlock_hidden_areas() {
  local dev="$1"; yellow "[HPA/DCO] Probing $dev"
  if hdparm -N "$dev" 2>/dev/null | grep -qi "native"; then
    local native_max
    native_max="$(hdparm -N "$dev" 2>/dev/null | awk '/native/ {print $6}')"
    if [[ -n "$native_max" ]]; then
      yellow "[HPA] Forcing native max sectors: $native_max"
      hdparm -N "p${native_max}" "$dev" >/dev/null 2>&1 || true
    fi
  fi
  # DCO restore (may require power cycle on some drives; we best-effort it)
  hdparm --dco-identify "$dev" >/dev/null 2>&1 || true
  hdparm --dco-restore  "$dev" >/dev/null 2>&1 || true
}

is_nvme() { [[ "$(basename "$1")" == nvme* ]]; }

nvme_secure() {
  local dev="$1"
  yellow "[NVMe] Secure flow on $dev"
  # Prefer SANITIZE (block erase) where supported
  if nvme sanitize -n1 --sanact=block-erase "$dev" >/dev/null 2>&1; then
    green "[NVMe] Sanitize (block-erase) issued."
    return 0
  fi
  # Crypto erase (near-instant on SEDs)
  if nvme format "$dev" --ses=2 >/dev/null 2>&1; then
    green "[NVMe] format --ses=2 (crypto-erase) done."
    return 0
  fi
  # Fallback to user-data erase
  if nvme format "$dev" --ses=1 >/dev/null 2>&1; then
    yellow "[NVMe] format --ses=1 (user-data erase) done."
    return 0
  fi
  return 1
}

ata_secure() {
  local dev="$1"
  yellow "[ATA] Secure flow on $dev"
  # set user password
  hdparm --user-master u --security-set-pass "$PASSPHRASE" "$dev" >/dev/null 2>&1 || true
  # Try enhanced erase first
  if hdparm --security-erase-enhanced "$PASSPHRASE" "$dev" >/dev/null 2>&1; then
    green "[ATA] security-erase-enhanced completed."
    hdparm --security-disable "$PASSPHRASE" "$dev" >/dev/null 2>&1 || true
    return 0
  fi
  # Fallback to standard
  if hdparm --security-erase "$PASSPHRASE" "$dev" >/dev/null 2>&1; then
    yellow "[ATA] security-erase completed."
    hdparm --security-disable "$PASSPHRASE" "$dev" >/dev/null 2>&1 || true
    return 0
  fi
  # Disable password if set (best-effort)
  hdparm --security-disable "$PASSPHRASE" "$dev" >/dev/null 2>&1 || true
  return 1
}

blkdiscard_fast() {
  local dev="$1"
  if command -v blkdiscard >/dev/null 2>&1; then
    yellow "[Fallback] blkdiscard $dev (TRIM entire device)"
    blkdiscard -f "$dev" >/dev/null 2>&1 || return 1
    return 0
  fi
  return 1
}

shred_wipe() {
  local dev="$1"
  yellow "[Fallback] shred -n 3 -z $dev"
  shred -n 3 -z "$dev"
}

dd_header_footer() {
  local dev="$1"
  yellow "[Fallback] Zeroing header & tail"
  # Zero first 100 MiB
  dd if=/dev/zero of="$dev" bs=1M count=100 conv=fsync status=none || true
  # Zero last 100 MiB
  local bytes; bytes="$(blockdev --getsize64 "$dev")"
  if [[ -n "$bytes" && "$bytes" -gt 209715200 ]]; then
    dd if=/dev/zero of="$dev" bs=1M seek=$((bytes/1048576 - 100)) count=100 conv=fsync status=none || true
  fi
}

verify_random_samples() {
  local dev="$1"
  local sz sectors
  sz="$(blockdev --getsize64 "$dev")" || return 1
  sectors=$((sz/512))
  (( sectors > 0 )) || return 1
  local n="$VERIFY_SAMPLES"
  local i=0 ok=0 fail=0
  while (( i < n )); do
    # derive a pseudo-random sector using $RANDOM; combine two for wider range
    local r=$(( ( (RANDOM<<15) ^ RANDOM ) % sectors ))
    # Read 1 sector
    local buf
    buf="$(dd if="$dev" bs=512 skip="$r" count=1 status=none 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    if [[ -z "$buf" ]]; then fail=$((fail+1)); i=$((i+1)); continue; fi
    # Check if all 00 or all ff
    if echo "$buf" | grep -qiE '^(00)+$'; then ok=$((ok+1))
    elif echo "$buf" | grep -qiE '^(ff)+$'; then ok=$((ok+1))
    else fail=$((fail+1))
    fi
    i=$((i+1))
  done
  echo "$ok/$n OK, $fail/$n FAIL"
  if (( fail == 0 )); then return 0; else return 1; fi
}

write_report() {
  local dev="$1" start="$2" end="$3" method="$4" status="$5" notes="$6"
  local short; short="$(device_short "$dev")"
  local out="${LOG_DIR}/wipe_report_${short}_$(date -u +%Y%m%dT%H%M%SZ).json"
  cat > "$out" <<JSON
{
  "problem_code": "SIH25070",
  "device": "$dev",
  "method_used": "$method",
  "start_time_utc": "$start",
  "end_time_utc": "$end",
  "status": "$status",
  "notes": $(printf '%s' "$notes" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g'),
  "host": "$(hostname)",
  "kernel": "$(uname -r)",
  "tool": "secure_erase.sh",
  "verify_samples": $VERIFY_SAMPLES
}
JSON
  echo "$out"
}

main() {
  if (( EUID != 0 )); then red "Run as root."; exit 1; fi
  if [[ $# -lt 1 ]]; then red "Usage: $0 /dev/<disk>"; exit 1; fi
  local DEV="$1"
  # Safety placeholder you mentioned: if someone keeps xxxxxxxxxxxxx, abort
  if [[ "$DEV" == *"xxxxxxxxxxxxx"* ]]; then
    red "Safety placeholder detected in device arg. Refusing to run."
    exit 2
  fi

  require lsblk; require hdparm; require dd; require od
  # nvme & blkdiscard optional; shred optional but recommended
  command -v nvme >/dev/null 2>&1 || yellow "nvme not found; NVMe sanitize may be unavailable."
  command -v blkdiscard >/dev/null 2>&1 || yellow "blkdiscard not found; SSD TRIM fallback unavailable."
  command -v shred >/dev/null 2>&1 || yellow "shred not found; slower dd-based fallback will be used."

  abort_if_root_device "$DEV"
  ensure_unmounted "$DEV"

  local START END METHOD STATUS NOTES
  START="$(ts)"
  unlock_hidden_areas "$DEV" || true

  # Decide path: NVMe vs ATA
  if is_nvme "$DEV"; then
    METHOD="nvme_sanitize_or_format"
    if retry nvme_secure "$DEV"; then
      STATUS="FirmwareEraseOK"
      NOTES="NVMe sanitize/format path succeeded."
    else
      yellow "[NVMe] Firmware path failed, engaging fallback."
      METHOD="fallback_blkdiscard+shred"
      if blkdiscard_fast "$DEV"; then
        shred_wipe "$DEV" || true
        dd_header_footer "$DEV" || true
        STATUS="FallbackOK"
        NOTES="blkdiscard succeeded; shred+dd added redundancy."
      else
        shred_wipe "$DEV" || true
        dd_header_footer "$DEV" || true
        STATUS="FallbackDegraded"
        NOTES="blkdiscard unavailable/failed; performed shred+dd only."
      fi
    fi
  else
    METHOD="ata_security_erase"
    if retry ata_secure "$DEV"; then
      STATUS="FirmwareEraseOK"
      NOTES="ATA enhanced/standard security erase path succeeded."
    else
      yellow "[ATA] Firmware path failed, engaging fallback."
      METHOD="fallback_blkdiscard+shred"
      if blkdiscard_fast "$DEV"; then
        shred_wipe "$DEV" || true
        dd_header_footer "$DEV" || true
        STATUS="FallbackOK"
        NOTES="blkdiscard succeeded; shred+dd added redundancy."
      else
        shred_wipe "$DEV" || true
        dd_header_footer "$DEV" || true
        STATUS="FallbackDegraded"
        NOTES="blkdiscard unavailable/failed; performed shred+dd only."
      fi
    fi
  fi

  # Verification
  yellow "[Verify] Random sector sampling..."
  if verify_random_samples "$DEV"; then
    green "[Verify] PASS"
    STATUS="${STATUS}+Verified"
  else
    red "[Verify] FAIL"
    STATUS="${STATUS}+VerifyFail"
    NOTES="${NOTES}\nRandom-sector verify found non-blank data."
  fi

  END="$(ts)"
  local REPORT
  REPORT="$(write_report "$DEV" "$START" "$END" "$METHOD" "$STATUS" "$NOTES")"
  blue "Wipe report: $REPORT"
  if [[ "$STATUS" == *"VerifyFail"* ]]; then
    red "WARNING: Verification failed. Consider rerunning sanitize or add manual review."
    exit 20
  fi
  green "Completed."
}

main "$@"
