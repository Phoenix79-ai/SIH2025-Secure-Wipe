#!/usr/bin/env bash
# Software fallback wipe for Linux with SSD-aware trim and verification
# Author: SIH25070 Team (hardened per mentor guidance)
set -euo pipefail

VERIFY_SAMPLES=256
LOG_DIR="./"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { red "Missing dependency: $1"; exit 127; }
}

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
device_short() { basename "$1" | tr -c '[:alnum:]_-' '_'; }

abort_if_root_device() {
  local dev="$1"
  local root_src; root_src="$(findmnt -n -o SOURCE /)"
  local root_base dev_base
  root_base="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"
  [[ -n "$root_base" ]] && root_base="/dev/$root_base" || root_base="$root_src"
  dev_base="$(lsblk -no PKNAME "$dev" 2>/dev/null || true)"
  [[ -n "$dev_base" ]] && dev_base="/dev/$dev_base" || dev_base="$dev"
  if [[ "$dev_base" == "$root_base" ]]; then
    red "Refusing to operate on the root/system disk: $dev_base"
    exit 9
  fi
}

ensure_unmounted() {
  local dev="$1"
  if lsblk -nr -o MOUNTPOINT "$dev" | grep -q "/"; then
    red "Some partitions of $dev are mounted. Unmount all before proceeding."
    exit 10
  fi
}

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
  hdparm --dco-identify "$dev" >/dev/null 2>&1 || true
  hdparm --dco-restore  "$dev" >/dev/null 2>&1 || true
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
  if command -v shred >/dev/null 2>&1; then
    yellow "[Fallback] shred -n 3 -z $dev"
    shred -n 3 -z "$dev"
  else
    yellow "[Fallback] shred not found; performing full zero pass via dd"
    dd if=/dev/zero of="$dev" bs=16M status=progress conv=fsync || true
  fi
}

dd_header_footer() {
  local dev="$1"
  yellow "[Fallback] Zeroing header & tail"
  dd if=/dev/zero of="$dev" bs=1M count=100 conv=fsync status=none || true
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
    local r=$(( ( (RANDOM<<15) ^ RANDOM ) % sectors ))
    local buf
    buf="$(dd if="$dev" bs=512 skip="$r" count=1 status=none 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    if [[ -z "$buf" ]]; then fail=$((fail+1)); i=$((i+1)); continue; fi
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
  local dev="$1" start="$2" end="$3" status="$4" notes="$5"
  local short; short="$(device_short "$dev")"
  local out="${LOG_DIR}/wipe_report_sw_${short}_$(date -u +%Y%m%dT%H%M%SZ).json"
  cat > "$out" <<JSON
{
  "problem_code": "SIH25070",
  "device": "$dev",
  "method_used": "software_fallback_trim+shred+dd",
  "start_time_utc": "$start",
  "end_time_utc": "$end",
  "status": "$status",
  "notes": "$(printf '%s' "$notes" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')",
  "host": "$(hostname)",
  "kernel": "$(uname -r)",
  "tool": "wipe_linux.sh",
  "verify_samples": $VERIFY_SAMPLES
}
JSON
  echo "$out"
}

main() {
  if (( EUID != 0 )); then red "Run as root."; exit 1; fi
  if [[ $# -lt 1 ]]; then red "Usage: $0 /dev/<disk>"; exit 1; fi
  local DEV="$1"
  if [[ "$DEV" == *"xxxxxxxxxxxxx"* ]]; then
    red "Safety placeholder detected in device arg. Refusing to run."
    exit 2
  fi

  require lsblk; require hdparm; require dd; require od
  command -v blkdiscard >/dev/null 2>&1 || yellow "blkdiscard not found; SSD TRIM fallback unavailable."
  command -v shred >/dev/null 2>&1 || yellow "shred not found; zero-only pass will be used."

  abort_if_root_device "$DEV"
  ensure_unmounted "$DEV"
  unlock_hidden_areas "$DEV" || true

  local START END STATUS NOTES
  START="$(ts)"
  if blkdiscard_fast "$DEV"; then
    NOTES="blkdiscard succeeded."
  else
    NOTES="blkdiscard unavailable/failed."
  fi

  shred_wipe "$DEV" || true
  dd_header_footer "$DEV" || true

  yellow "[Verify] Random sector sampling..."
  if verify_random_samples "$DEV"; then
    STATUS="FallbackOK+Verified"
  else
    STATUS="FallbackDegraded+VerifyFail"
    NOTES="${NOTES}\nRandom-sector verify found non-blank data."
  fi

  END="$(ts)"
  local REPORT
  REPORT="$(write_report "$DEV" "$START" "$END" "$STATUS" "$NOTES")"
  blue "Wipe report: $REPORT"
  if [[ "$STATUS" == *"VerifyFail"* ]]; then
    red "WARNING: Verification failed. Consider manual review or rerun with firmware sanitize."
    exit 20
  fi
  green "Completed."
}

main "$@"
