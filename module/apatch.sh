#!/system/bin/sh
# KernelPatch 0.13.9 preset ABI from the pinned upstream preset.h.
# Keep credentials opaque: never pass existing keys in argv or print them.
f60_apatch_copy_settings() (
  source_image=$1 source_offset=$2 target_image=$3 target_offset=$4
  dd if="$source_image" of="$target_image" bs=1 \
    skip="$((source_offset + 232))" seek="$((target_offset + 232))" \
    count=96 conv=notrunc 2>/dev/null &&
  dd if="$source_image" of="$target_image" bs=1 \
    skip="$((source_offset + 904))" seek="$((target_offset + 904))" \
    count=512 conv=notrunc 2>/dev/null
)

f60_apatch_settings_equal() (
  source_dir=$1 target_dir=$2
  for region in credentials additional; do
    cmp -s "$source_dir/$region" "$target_dir/$region" || exit 1
  done
)

f60_apatch_kernel() {
  # A stock/fixed kernel with this exact payload is the complete whitelist.
  # kptools reconstruction below also checks every generated offset and hook.
  "$F60_MB" decompress "$1/unpack/kernel" "$1/kernel.plain" || return 1
  F60_KP_OFFSET=
  for base_size in "$STOCK_PLAIN_SIZE" "$FIXED_PLAIN_SIZE"; do
    offset=$(((base_size + 4095) / 4096 * 4096))
    [ "$offset" != "$F60_KP_OFFSET" ] || continue
    f60_range "$1/kernel.plain" "$offset" 8 > "$1/kp.magic" || return 1
    [ "$(od -An -v -tx1 "$1/kp.magic" | tr -d ' \n')" = 4b50313135380000 ] || continue
    [ -z "$F60_KP_OFFSET" ] ||
      { f60_error "Ambiguous KernelPatch payload."; return 1; }
    F60_KP_OFFSET=$offset
    F60_BASE_SIZE=$base_size
  done
  [ -n "$F60_KP_OFFSET" ] ||
    { f60_error "No supported KernelPatch 0.13.9 image."; return 1; }
  [ "$(f60_size "$1/kernel.plain")" = "$((F60_KP_OFFSET + KPIMG_SIZE + 128))" ] &&
  f60_zero_range "$1/kernel.plain" "$1" "$((F60_KP_OFFSET + KPIMG_SIZE))" 128 ||
    { f60_error "Embedded KPM/extra items are unsupported; nothing written."; return 1; }
  f60_range "$1/kernel.plain" "$F60_KP_OFFSET" "$KPIMG_SIZE" > "$1/kp.mask" &&
  cp "$F60_PAYLOAD_ROOT/tools/kpimg" "$1/template.mask" &&
  f60_zero "$1/kp.mask" 64 1352 &&
  f60_zero "$1/template.mask" 64 1352 &&
  cmp -s "$1/kp.mask" "$1/template.mask" ||
    { f60_error "Unknown KernelPatch code or version."; return 1; }
  f60_range "$1/kernel.plain" 0 "$F60_BASE_SIZE" > "$1/kernel.base" &&
  dd if="$1/kernel.plain" of="$1/kernel.base" bs=1 \
    skip="$((F60_KP_OFFSET + 224))" count=8 conv=notrunc 2>/dev/null &&
  dd if="$1/kernel.plain" of="$1/kernel.base" bs=1 \
    skip="$((F60_KP_OFFSET + 88))" seek=16 count=8 conv=notrunc 2>/dev/null || return 1
  case "$(f60_hash "$1/kernel.base")" in
    "$STOCK_PLAIN_SHA") F60_KERNEL_STATE=stock ;;
    "$FIXED_PLAIN_SHA") F60_KERNEL_STATE=fixed ;;
    *) f60_error "Unknown base kernel under KernelPatch."; return 1 ;;
  esac
  "$F60_KP" -p -i "$1/kernel.base" -k "$F60_PAYLOAD_ROOT/tools/kpimg" \
    -S f60-validation-placeholder -o "$1/kernel.expected" > "$1/kptools.log" 2>&1 ||
    { f60_error "KernelPatch reconstruction failed."; return 1; }
  f60_apatch_copy_settings "$1/kernel.plain" "$F60_KP_OFFSET" \
    "$1/kernel.expected" "$F60_KP_OFFSET" &&
  cmp -s "$1/kernel.expected" "$1/kernel.plain" ||
    { f60_error "KernelPatch hooks/settings differ from the pinned patcher."; return 1; }
  f60_range "$1/kernel.plain" "$((F60_KP_OFFSET + 232))" 96 > "$1/credentials" &&
  f60_range "$1/kernel.plain" "$((F60_KP_OFFSET + 904))" 512 > "$1/additional" || return 1
  printf '%s\n' "$F60_KP_OFFSET" > "$1/kp.offset"
}

f60_apatch_rebase() (
  before=$1
  "$F60_MB" decompress "$F60_PAYLOAD/kernel" "$before/fixed.base" &&
  [ "$(f60_hash "$before/fixed.base")" = "$FIXED_PLAIN_SHA" ] || exit 1
  "$F60_KP" -p -i "$before/fixed.base" -k "$F60_PAYLOAD_ROOT/tools/kpimg" \
    -S f60-validation-placeholder -o "$before/fixed.patched" > "$before/rebase.log" 2>&1 ||
    { f60_error "Cannot patch the F60 kernel for APatch."; exit 1; }
  new_offset=$(((FIXED_PLAIN_SIZE + 4095) / 4096 * 4096))
  old_offset=$(cat "$before/kp.offset") || exit 1
  f60_apatch_copy_settings "$before/kernel.plain" "$old_offset" \
    "$before/fixed.patched" "$new_offset" &&
  "$F60_MB" compress=gzip "$before/fixed.patched" "$before/unpack/kernel"
)
