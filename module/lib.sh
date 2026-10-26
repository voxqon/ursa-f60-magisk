#!/system/bin/sh

# Installed scripts run in the root manager's BusyBox standalone ash.
F60_STATE=/data/adb/ursa_ndt_f60
F60_MODULE=${MODPATH:-${0%/*}}
F60_PAYLOAD_ROOT=$F60_MODULE/payload
F60_PAYLOAD=$F60_PAYLOAD_ROOT
. "$F60_MODULE/apatch.sh"

f60_error() { echo "ERROR: $*" >&2; return 1; }
f60_hash() { sha256sum "$1" | awk '{print $1}'; }
f60_size() { stat -c %s "$1"; }
f60_range() {
  dd if="$1" bs=65536 iflag=skip_bytes,count_bytes skip="$2" count="$3" 2>/dev/null
}
f60_zero() {
  dd if=/dev/zero of="$1" bs=1 seek="$2" count="$3" conv=notrunc 2>/dev/null
}
f60_uint() (
  # Only small offsets/sizes are accepted, so arithmetic cannot overflow.
  values=$(od -An -v -tu1 -j "$2" -N "$3" "$1") || exit 1
  set -- $values
  [ "$#" -gt 0 ] || exit 1
  value=0
  for byte do
    value=$((value * 256 + byte))
    [ "$value" -le 134217728 ] || exit 1
  done
  echo "$value"
)
f60_le32() (
  values=$(od -An -v -tu1 -j "$2" -N 4 "$1") || exit 1
  set -- $values
  [ "$#" = 4 ] || exit 1
  echo "$(($1 + $2 * 256 + $3 * 65536 + $4 * 16777216))"
)
f60_be64_write() {
  (
    value=$3
    # All accepted image sizes fit into 32 bits. Emit eight big endian bytes.
    printf '\000\000\000\000'
    for shift in 24 16 8 0; do
      octal=$(printf '%03o' "$(((value >> shift) & 255))") || exit 1
      printf "\\$octal"
    done
  ) | dd of="$1" bs=1 seek="$2" count=8 conv=notrunc 2>/dev/null
}

f60_load() {
  [ -f "$F60_PAYLOAD_ROOT/engine.env" ] || return 1
  (cd "$F60_PAYLOAD_ROOT" && sha256sum -c SHA256SUMS) || return 1
  . "$F60_PAYLOAD_ROOT/engine.env"
  f60_select_profile
}

f60_select_profile() {
  current_version=$(getprop ro.lineage.version)
  current_incremental=$(getprop ro.build.version.incremental)
  current_sdk=$(getprop ro.build.version.sdk)
  major=$(printf '%s' "$current_version" | awk -F '[.-]' '{print $1}')
  case "$major" in ''|*[!0-9]*) f60_error "Not a LineageOS version."; return 1 ;; esac
  [ "$major" -ge 20 ] ||
    { f60_error "LineageOS 20 or later is required."; return 1; }
  selected=
  for profile in "$F60_PAYLOAD_ROOT"/profiles/*; do
    [ -f "$profile/manifest.env" ] || continue
    if grep -Fxq "TARGET_VERSION='$current_version'" "$profile/manifest.env" &&
       grep -Fxq "TARGET_INCREMENTAL='$current_incremental'" "$profile/manifest.env" &&
       grep -Fxq "TARGET_SDK='$current_sdk'" "$profile/manifest.env"; then
      [ -z "$selected" ] ||
        { f60_error "Ambiguous ROM profiles."; return 1; }
      selected=$profile
    fi
  done
  [ -n "$selected" ] || {
    f60_error "No matching kernel payload for $current_version / $current_incremental."
    f60_error "A matching ROM boot image, source revision and rebuilt kernel must be added first."
    return 1
  }
  F60_PAYLOAD=$selected
  . "$F60_PAYLOAD/manifest.env"
}

f60_environment() {
  [ "$(id -u)" = 0 ] || { f60_error "Root required."; return 1; }
  [ "$(getprop ro.product.device)" = ursa ] &&
  [ "$(getprop ro.lineage.device)" = ursa ] &&
  [ "$(getprop ro.lineage.version)" = "$TARGET_VERSION" ] &&
  [ "$(getprop ro.build.version.incremental)" = "$TARGET_INCREMENTAL" ] &&
  [ "$(getprop ro.build.version.sdk)" = "$TARGET_SDK" ] ||
    { f60_error "Unsupported device or ROM build."; return 1; }
  [ "$(getprop ro.boot.verifiedbootstate)" = orange ] ||
    { f60_error "Unlocked bootloader (orange) required."; return 1; }
  [ -z "$(getprop ro.boot.slot_suffix)" ] &&
  [ -z "$(getprop ro.boot.slot)" ] ||
    { f60_error "A/B layouts are unsupported."; return 1; }
  F60_ROOT=magisk
  if [ -x /data/adb/apd ]; then
    [ "$(cat /data/adb/ap/version)" = "$APATCH_CODE" ] ||
      { f60_error "This package requires APatch $APATCH_CODE."; return 1; }
    F60_ROOT=apatch
    F60_KP=$F60_PAYLOAD_ROOT/tools/kptools
    [ "$(f60_hash /data/adb/ap/bin/kptools)" = "$KPTOOLS_ARM64_SHA" ] &&
    [ "$(f60_hash "$F60_KP")" = "$KPTOOLS_ARM64_SHA" ] ||
      { f60_error "Unknown KernelPatch tools."; return 1; }
    F60_MB=$F60_PAYLOAD_ROOT/tools/magiskboot
    chmod 0755 "$F60_KP" "$F60_MB" ||
      { f60_error "Cannot prepare the verified packaged tools."; return 1; }
  else
    [ "$(magisk -V 2>/dev/null)" = "$MAGISK_CODE" ] ||
      { f60_error "Requires Magisk $MAGISK_NAME or APatch $APATCH_CODE."; return 1; }
    F60_MB=/data/adb/magisk/magiskboot
  fi
  [ -x "$F60_MB" ] && [ "$(f60_hash "$F60_MB")" = "$MAGISKBOOT_ARM64_SHA" ] ||
    { f60_error "Unknown magiskboot executable."; return 1; }
  F60_BOOT=$(readlink -f /dev/block/bootdevice/by-name/boot) || return 1
  IMAGE_SIZE=$PARTITION_SIZE
  [ -b "$F60_BOOT" ] &&
  [ "$(blockdev --getsize64 "$F60_BOOT")" = "$IMAGE_SIZE" ] ||
    { f60_error "Unexpected boot partition or size."; return 1; }
  [ ! -e /dev/block/bootdevice/by-name/init_boot ] &&
  [ ! -e /dev/block/bootdevice/by-name/boot_a ] ||
    { f60_error "Unexpected boot partition layout."; return 1; }
}

f60_header() {
  [ "$(f60_size "$1")" = "$IMAGE_SIZE" ] || return 1
  f60_range "$1" 0 4096 > "$2/header.mask" || return 1
  # Only kernel size, ramdisk size and the legacy boot checksum may differ.
  f60_zero "$2/header.mask" 8 4 &&
  f60_zero "$2/header.mask" 16 4 &&
  f60_zero "$2/header.mask" 576 32 || return 1
  [ "$(f60_hash "$2/header.mask")" = "$HEADER_MASK_SHA" ] ||
    { f60_error "Unknown boot header, cmdline or layout."; return 1; }
  F60_KSIZE=$(f60_le32 "$1" 8) || return 1
  F60_RSIZE=$(f60_le32 "$1" 16) || return 1
  [ "$F60_KSIZE" -ge 10000000 ] && [ "$F60_KSIZE" -le 40000000 ] &&
  [ "$F60_RSIZE" -ge 1 ] && [ "$F60_RSIZE" -le 20000000 ] || return 1
  F60_ROFF=$((4096 + (F60_KSIZE + 4095) / 4096 * 4096))
  F60_END=$((F60_ROFF + (F60_RSIZE + 4095) / 4096 * 4096))
  [ "$F60_END" -lt "$((IMAGE_SIZE - 8192))" ] || return 1
}

f60_metadata() {
  # Templates pin all metadata except Magisk's flags and stale hash/size fields.
  f60_range "$1" "$((IMAGE_SIZE - 64))" 64 > "$2/footer" || return 1
  F60_VOFF=$(f60_uint "$2/footer" 20 8) || return 1
  [ "$F60_VOFF" = "$F60_END" ] &&
  [ "$(f60_uint "$2/footer" 12 8)" = "$F60_END" ] || return 1
  cp "$2/footer" "$2/footer.mask" &&
  f60_zero "$2/footer.mask" 12 16 || return 1
  [ "$(f60_hash "$2/footer.mask")" = "$FOOTER_MASK_SHA" ] || return 1
  f60_range "$1" "$F60_VOFF" "$VBMETA_SIZE" > "$2/vbmeta" || return 1
  F60_FLAGS=$(f60_uint "$2/vbmeta" 120 4) || return 1
  case "$F60_FLAGS" in 0|3) ;; *) return 1 ;; esac
  cp "$2/vbmeta" "$2/vbmeta.mask" &&
  f60_zero "$2/vbmeta.mask" 120 4 &&
  f60_zero "$2/vbmeta.mask" "$HASH_SIZE_OFFSET" 8 &&
  f60_zero "$2/vbmeta.mask" "$HASH_DIGEST_OFFSET" 32 || return 1
  [ "$(f60_hash "$2/vbmeta.mask")" = "$VBMETA_MASK_SHA" ] ||
    { f60_error "Unknown AVB algorithm or metadata."; return 1; }
  if [ "$3" = strict ]; then
    [ "$(f60_uint "$2/vbmeta" "$HASH_SIZE_OFFSET" 8)" = "$F60_END" ] || return 1
    # Use a file to make a failed range read visible, instead of a hidden pipe error.
    cat "$F60_PAYLOAD/salt" > "$2/hash-input" &&
    f60_range "$1" 0 "$F60_END" >> "$2/hash-input" || return 1
    digest=$(f60_hash "$2/hash-input") || return 1
    actual=$(od -An -v -tx1 -j "$HASH_DIGEST_OFFSET" -N 32 "$2/vbmeta" |
      tr -d ' \n') || return 1
    [ "$digest" = "$actual" ] ||
      { f60_error "AVB boot digest mismatch."; return 1; }
  fi
}

f60_zero_range() {
  [ "$4" -gt 0 ] || return 0
  f60_range "$1" "$3" "$4" > "$2/padding" &&
  [ "$(f60_size "$2/padding")" = "$4" ] &&
  truncate -s 0 "$2/zeros" && truncate -s "$4" "$2/zeros" &&
  cmp -s "$2/padding" "$2/zeros"
}

f60_tail_padding() {
  padding_start=$((F60_VOFF + VBMETA_SIZE))
  # Some flashers copy the original image footer to the physical partition end,
  # leaving one identical footer at the original download size.
  if [ "$IMAGE_SIZE" -gt "$SOURCE_IMAGE_SIZE" ]; then
    f60_range "$1" "$((SOURCE_IMAGE_SIZE - 64))" 64 > "$2/inner.footer" || return 1
    if cmp -s "$2/inner.footer" "$2/footer"; then
      [ "$padding_start" -le "$((SOURCE_IMAGE_SIZE - 64))" ] &&
      f60_zero_range "$1" "$2" "$padding_start" "$((SOURCE_IMAGE_SIZE - 64 - padding_start))" &&
      f60_zero_range "$1" "$2" "$SOURCE_IMAGE_SIZE" "$((IMAGE_SIZE - 64 - SOURCE_IMAGE_SIZE))"
      return "$?"
    fi
  fi
  f60_zero_range "$1" "$2" "$padding_start" "$((IMAGE_SIZE - 64 - padding_start))"
}

f60_components() {
  f60_header "$1" "$2" && f60_metadata "$1" "$2" "$3" || return 1
  f60_zero_range "$1" "$2" 596 12 &&
  f60_zero_range "$1" "$2" "$((4096 + F60_KSIZE))" "$((F60_ROFF - 4096 - F60_KSIZE))" &&
  f60_zero_range "$1" "$2" "$((F60_ROFF + F60_RSIZE))" "$((F60_END - F60_ROFF - F60_RSIZE))" &&
  f60_tail_padding "$1" "$2" ||
    { f60_error "Unknown bytes in boot padding."; return 1; }
  f60_range "$1" 4096 "$F60_KSIZE" > "$2/kernel.raw" &&
  f60_range "$1" "$F60_ROFF" "$F60_RSIZE" > "$2/ramdisk.raw" || return 1
  kernel_sha=$(f60_hash "$2/kernel.raw")
  if [ "${F60_ROOT:-magisk}" != apatch ]; then
    case "$kernel_sha" in
    "$STOCK_KERNEL_SHA") F60_KERNEL_STATE=stock ;;
    "$FIXED_KERNEL_SHA") F60_KERNEL_STATE=fixed ;;
    *) f60_error "Unknown kernel or appended device trees."; return 1 ;;
    esac
  fi
  # Verify the legacy SHA-1 boot ID independently of magiskboot.
  cat "$2/kernel.raw" > "$2/id-input" &&
  f60_range "$1" 8 4 >> "$2/id-input" &&
  cat "$2/ramdisk.raw" >> "$2/id-input" &&
  f60_range "$1" 16 4 >> "$2/id-input" &&
  dd if=/dev/zero bs=1 count=8 >> "$2/id-input" 2>/dev/null || return 1
  expected=$(sha1sum "$2/id-input" | awk '{print $1}')
  actual=$(od -An -v -tx1 -j 576 -N 20 "$1" | tr -d ' \n')
  if [ "$expected" != "$actual" ]; then
    # KP 0.13.9 hashes past the compressed kernel before appending the DTBs.
    # Accept its input ID only after the complete component whitelist below;
    # generated outputs must always carry the canonical Magiskboot SHA-1 ID.
    if [ "${F60_ROOT:-magisk}" = apatch ] && [ "$3" = relaxed ]; then
      echo "APatch input has a noncanonical legacy ID; full component verification required."
    else
      f60_error "Legacy boot checksum mismatch."
      return 1
    fi
  fi
  mkdir "$2/unpack" || return 1
  (cd "$2/unpack" && "$F60_MB" unpack -n "$1") || return 1
  [ "$(f60_hash "$2/unpack/kernel_dtb")" = "$DTB_SHA" ] || return 1
  if [ "${F60_ROOT:-magisk}" = apatch ]; then
    [ "$(f60_hash "$2/ramdisk.raw")" = "$STOCK_RAMDISK_SHA" ] ||
      { f60_error "APatch requires the unmodified target ROM ramdisk."; return 1; }
    f60_apatch_kernel "$2"
    return "$?"
  fi
  # Only a Magisk-patched partition ramdisk is accepted, even on a temporary boot.
  "$F60_MB" decompress "$2/ramdisk.raw" "$2/ramdisk.cpio" || return 1
  "$F60_MB" cpio "$2/ramdisk.cpio" test
  [ "$?" = 1 ] ||
    { f60_error "Partition ramdisk is not Magisk-patched; root would be lost."; return 1; }
  # Work on a copy. Never change the ramdisk that will be written to boot.
  cp "$2/ramdisk.cpio" "$2/restored.cpio" &&
  "$F60_MB" cpio "$2/restored.cpio" restore || return 1
  [ "$(f60_hash "$2/restored.cpio")" = "$STOCK_CPIO_CANONICAL_SHA" ] ||
    { f60_error "Ramdisk contains changes beyond the expected Magisk patch."; return 1; }
}

f60_finalize_avb() {
  f60_header "$1" "$2" || return 1
  # Preserve the validated current vbmeta and its flags, replacing size and digest.
  cp "$3/vbmeta" "$2/vbmeta" &&
  f60_be64_write "$2/vbmeta" "$HASH_SIZE_OFFSET" "$F60_END" || return 1
  cat "$F60_PAYLOAD/salt" > "$2/hash-input" &&
  f60_range "$1" 0 "$F60_END" >> "$2/hash-input" || return 1
  digest=$(f60_hash "$2/hash-input") || return 1
  printf '%s' "$digest" | xxd -r -p > "$2/digest"
  [ "$(f60_size "$2/digest")" = 32 ] || return 1
  dd if="$2/digest" of="$2/vbmeta" bs=1 seek="$HASH_DIGEST_OFFSET" conv=notrunc 2>/dev/null ||
    return 1
  cp "$3/footer" "$2/footer" &&
  f60_be64_write "$2/footer" 12 "$F60_END" &&
  f60_be64_write "$2/footer" 20 "$F60_END" || return 1
  # Remove all previous padding/metadata before placing the regenerated structures.
  truncate -s "$F60_END" "$1" &&
  cat "$2/vbmeta" >> "$1" &&
  truncate -s "$((IMAGE_SIZE - 64))" "$1" &&
  cat "$2/footer" >> "$1" || return 1
}

f60_read_boot() {
  dd if="$F60_BOOT" of="$1" bs=4096 count="$((IMAGE_SIZE / 4096))" 2>/dev/null &&
  [ "$(f60_size "$1")" = "$IMAGE_SIZE" ]
}

f60_write_verified() {
  # Last read guards against another boot modifier since preparation.
  f60_read_boot "$F60_WORK/guard.img" &&
  cmp -s "$2" "$F60_WORK/guard.img" ||
    { f60_error "Boot changed during preparation. Nothing written."; return 1; }
  # Keep recovery information on disk before the first partition write.
  printf 'write-started\n' > "$F60_BACKUP/write-status" &&
  sync || return 1
  if dd if="$1" of="$F60_BOOT" bs=4096 conv=fsync 2>/dev/null &&
     f60_read_boot "$F60_WORK/readback.img" &&
     cmp -s "$1" "$F60_WORK/readback.img"; then
    printf 'verified\n' > "$F60_BACKUP/write-status"
    sync
    return 0
  fi
  echo "Write/readback failed; restoring the exact pre-write partition image." >&2
  if dd if="$2" of="$F60_BOOT" bs=4096 conv=fsync 2>/dev/null &&
     f60_read_boot "$F60_WORK/rollback.img" &&
     cmp -s "$2" "$F60_WORK/rollback.img"; then
    printf 'rolled-back\n' > "$F60_BACKUP/write-status"
    f60_error "Write failed; original boot restored. Do not reboot to test the fix."
  else
    printf 'RECOVERY-REQUIRED\n' > "$F60_BACKUP/write-status"
    f60_error "Restore failed. DO NOT REBOOT; copy the backup and recover via fastboot."
  fi
  sync
  return 1
}

f60_prepare() {
  umask 077
  f60_load && f60_environment || return 1
  mkdir -p "$F60_STATE" && chmod 700 "$F60_STATE" || return 1
  free_kib=$(df -Pk "$F60_STATE" | awk 'END {print $4}')
  case "$free_kib" in ''|*[!0-9]*) return 1 ;; esac
  [ "$free_kib" -ge 1048576 ] ||
    { f60_error "At least 1 GiB free on /data is required for backup and verification."; return 1; }
  mkdir "$F60_STATE/lock" 2>/dev/null ||
    { f60_error "Another operation or interrupted lock exists: $F60_STATE/lock"; return 1; }
  F60_WORK=$(mktemp -d "$F60_STATE/work.XXXXXX") || {
    rmdir "$F60_STATE/lock"
    return 1
  }
  # On interruption retain files/lock for diagnosis; never automatically write on a signal.
  trap 'echo "Interrupted; work files and lock retained. Check boot before reboot." >&2; exit 1' HUP INT TERM
}

f60_cleanup() {
  # Only remove the exact temporary child created above.
  case "$F60_WORK" in "$F60_STATE"/work.*)
    [ -d "$F60_WORK" ] && rm -rf "$F60_WORK"
  esac
  rmdir "$F60_STATE/lock" 2>/dev/null
  trap - HUP INT TERM
}

f60_new_backup() {
  F60_BACKUP=$(mktemp -d "$F60_STATE/backup-$(date +%Y%m%d-%H%M%S).XXXXXX") || return 1
  cp "$F60_WORK/before.img" "$F60_BACKUP/boot-before.img" &&
  cmp -s "$F60_WORK/before.img" "$F60_BACKUP/boot-before.img" || return 1
  {
    echo "device=ursa"
    echo "lineage=$TARGET_VERSION"
    echo "incremental=$TARGET_INCREMENTAL"
    echo "profile=$TARGET_ID"
    echo "partition=$F60_BOOT"
    echo "size=$IMAGE_SIZE"
    echo "root=${F60_ROOT:-magisk}"
    echo "magisk=$MAGISK_CODE"
    echo "apatch=$APATCH_CODE"
  } > "$F60_BACKUP/device.txt" || return 1
  (cd "$F60_BACKUP" && sha256sum boot-before.img device.txt > SHA256SUMS) || return 1
  sync
}

f60_build_candidate() {
  mkdir "$F60_WORK/before" "$F60_WORK/finalize" "$F60_WORK/after" || return 1
  f60_read_boot "$F60_WORK/before.img" &&
  f60_components "$F60_WORK/before.img" "$F60_WORK/before" relaxed || return 1
  if [ "$F60_KERNEL_STATE" = fixed ]; then
    if f60_metadata "$F60_WORK/before.img" "$F60_WORK/before" strict; then
      echo "Boot already contains the whitelisted F60 kernel and valid AVB metadata; no partition write."
      return 0
    fi
    echo "F60 kernel is present; refreshing the stale AVB digest."
  fi
  # -n keeps the original compressed ramdisk bytes, preserving current root.
  if [ "${F60_ROOT:-magisk}" = apatch ]; then
    f60_apatch_rebase "$F60_WORK/before" || return 1
  else
    cp "$F60_PAYLOAD/kernel" "$F60_WORK/before/unpack/kernel" || return 1
  fi
  (cd "$F60_WORK/before/unpack" &&
    PATCHVBMETAFLAG=false "$F60_MB" repack -n "$F60_WORK/before.img" "$F60_WORK/patched.img") ||
    return 1
  f60_finalize_avb "$F60_WORK/patched.img" "$F60_WORK/finalize" "$F60_WORK/before" &&
  f60_components "$F60_WORK/patched.img" "$F60_WORK/after" strict || return 1
  [ "$F60_KERNEL_STATE" = fixed ] &&
  cmp -s "$F60_WORK/before/ramdisk.raw" "$F60_WORK/after/ramdisk.raw" &&
  cmp -s "$F60_WORK/before/unpack/kernel_dtb" "$F60_WORK/after/unpack/kernel_dtb" &&
  cmp -s "$F60_WORK/before/header.mask" "$F60_WORK/after/header.mask" &&
  [ "$(f60_uint "$F60_WORK/before/vbmeta" 120 4)" = "$(f60_uint "$F60_WORK/after/vbmeta" 120 4)" ] ||
    { f60_error "Repacked image invariants failed."; return 1; }
  if [ "${F60_ROOT:-magisk}" = apatch ]; then
    f60_apatch_settings_equal "$F60_WORK/before" "$F60_WORK/after" ||
      { f60_error "APatch credentials or settings changed."; return 1; }
    echo "APatch KernelPatch code, hooks, credentials and settings verified."
  fi
}

f60_install_body() {
  f60_build_candidate || return 1
  [ -f "$F60_WORK/patched.img" ] || return 0
  f60_new_backup || return 1
  cp "$F60_WORK/patched.img" "$F60_BACKUP/boot-after.img" &&
  (cd "$F60_BACKUP" && sha256sum boot-after.img >> SHA256SUMS) &&
  sync || return 1
  f60_write_verified "$F60_BACKUP/boot-after.img" "$F60_BACKUP/boot-before.img" || return 1
  printf '%s\n' "$F60_BACKUP" > "$F60_STATE/latest-backup"
}

f60_install() {
  mkdir -p "$F60_STATE" && chmod 700 "$F60_STATE" || return 1
  if ! f60_prepare > "$F60_STATE/install.log" 2>&1; then
    cat "$F60_STATE/install.log"
    return 1
  fi
  # Tee is avoided here so ash preserves the install body's exit status.
  echo "Preparing whitelisted boot repair..."
  f60_install_body >> "$F60_STATE/install.log" 2>&1
  result=$?
  cat "$F60_STATE/install.log"
  f60_cleanup
  return "$result"
}

f60_restore_body() {
  F60_BACKUP=$1
  case "$F60_BACKUP" in "$F60_STATE"/backup-*) ;; *) return 1 ;; esac
  [ "$(readlink -f "$F60_BACKUP")" = "$F60_BACKUP" ] || return 1
  (cd "$F60_BACKUP" && sha256sum -c SHA256SUMS) || return 1
  grep -qx "lineage=$TARGET_VERSION" "$F60_BACKUP/device.txt" &&
  grep -qx "incremental=$TARGET_INCREMENTAL" "$F60_BACKUP/device.txt" &&
  grep -qx "partition=$F60_BOOT" "$F60_BACKUP/device.txt" || return 1
  mkdir "$F60_WORK/original" "$F60_WORK/current" || return 1
  f60_components "$F60_BACKUP/boot-before.img" "$F60_WORK/original" relaxed || return 1
  f60_read_boot "$F60_WORK/before.img" || return 1
  if cmp -s "$F60_WORK/before.img" "$F60_BACKUP/boot-before.img"; then
    echo "Original boot already present. No partition write."
    return 0
  fi
  # No restore over an OTA, a new root installation, or another kernel modifier.
  cmp -s "$F60_WORK/before.img" "$F60_BACKUP/boot-after.img" ||
    { f60_error "Current boot differs from this backup's result; refusing restore."; return 1; }
  f60_components "$F60_WORK/before.img" "$F60_WORK/current" strict || return 1
  f60_write_verified "$F60_BACKUP/boot-before.img" "$F60_WORK/before.img" || return 1
  printf 'restored\n' > "$F60_BACKUP/write-status"
  echo "Pre-install boot restored and read back. Reboot manually."
}

f60_restore() {
  [ "$1" = --restore ] && [ -n "$2" ] ||
    { f60_error "Usage: sh restore.sh --restore /data/adb/ursa_ndt_f60/backup-..."; return 1; }
  f60_prepare || return 1
  f60_restore_body "$2" > "$F60_STATE/restore.log" 2>&1
  result=$?
  cat "$F60_STATE/restore.log"
  f60_cleanup
  return "$result"
}

f60_status() {
  echo "Time: $(date)"
  echo "ROM: $(getprop ro.lineage.version)"
  echo "Kernel: $(uname -r)"
  echo "SELinux: $(getenforce)"
  if ! f60_load; then
    echo "UNSUPPORTED ROM: no matching verified profile. No boot writes performed."
    return 1
  fi
  echo "Matched profile: $TARGET_ID"
  [ "$(uname -r)" = "$FIXED_RELEASE" ] ||
    { echo "F60 kernel is not running. A temporary boot or pending reboot may explain this."; return 1; }
  driver=$(readlink -f /sys/bus/i2c/devices/3-0050/driver)
  [ "$driver" = /sys/bus/i2c/drivers/ndt_press_f60 ] ||
    { echo "NDT F60 I2C binding absent or unreadable."; return 1; }
  echo "NDT F60 kernel and driver binding detected."
  echo "Complete fingerprint enrollment and lockscreen authentication manually."
}
