#!/system/bin/sh

# Only known non-code build fields may vary in the adaptive fallback.
f60_family_header() (
  os_version=$(f60_le32 "$1/header.mask" 44) || exit 1
  [ "$((os_version >> 11))" = "$FAMILY_HEADER_OS" ] || exit 1
  cp "$1/header.mask" "$1/header.family" &&
  f60_zero "$1/header.family" 44 4 &&
  [ "$(f60_hash "$1/header.family")" = "$FAMILY_HEADER_SHA" ]
)

f60_family_metadata() (
  export LC_ALL=C
  # Layout and lengths are pinned by the structural hash. Bind the fingerprint
  # to the running ursa build and preserve the exact value and its salt.
  f60_range "$1/vbmeta" "$FAMILY_FINGERPRINT_OFFSET" "$FAMILY_FINGERPRINT_SIZE" > "$1/fingerprint" &&
  awk -F / -v size="$FAMILY_FINGERPRINT_SIZE" -v build="$TARGET_INCREMENTAL" '
    length($0) == size && NF == 6 && $1 == "Xiaomi" && $2 == "lineage_ursa" &&
    $3 == "ursa:15" && $4 ~ /^[A-Za-z0-9._-]+$/ &&
    $5 == build ":userdebug" && $6 == "release-keys" { valid = 1 }
    END { exit !(NR == 1 && valid) }
  ' "$1/fingerprint" &&
  f60_range "$1/vbmeta" "$FAMILY_SALT_OFFSET" 32 > "$1/salt" &&
  [ "$(f60_size "$1/salt")" = 32 ] &&
  f60_zero "$1/vbmeta.mask" "$FAMILY_FINGERPRINT_OFFSET" "$FAMILY_FINGERPRINT_SIZE" &&
  f60_zero "$1/vbmeta.mask" "$FAMILY_SALT_OFFSET" 32 &&
  [ "$(f60_hash "$1/vbmeta.mask")" = "$FAMILY_VBMETA_SHA" ]
)

f60_family_dtbs() (
  export LC_ALL=C
  dtb=$1/unpack/kernel_dtb
  total=$(f60_size "$dtb") || exit 1
  off=0 count=0
  : > "$1/dtb.hashes" || exit 1
  while [ "$off" -lt "$total" ]; do
    [ "$count" -lt "$FAMILY_DTB_COUNT" ] && [ "$((total - off))" -ge 40 ] || exit 1
    [ "$(od -An -v -tx1 -j "$off" -N 4 "$dtb" | tr -d ' \n')" = d00dfeed ] || exit 1
    length=$(f60_uint "$dtb" "$((off + 4))" 4) || exit 1
    [ "$length" -ge 40 ] && [ "$length" -le "$((total - off))" ] || exit 1
    f60_range "$dtb" "$off" "$length" > "$1/dtb.part" &&
    [ "$(f60_size "$1/dtb.part")" = "$length" ] || exit 1
    digest=$(f60_hash "$1/dtb.part") || exit 1
    printf '%s\n' "$digest" >> "$1/dtb.hashes" || exit 1
    off=$((off + length)) count=$((count + 1))
  done
  [ "$count" = "$FAMILY_DTB_COUNT" ] || exit 1
  sort "$1/dtb.hashes" > "$1/dtb.sorted" &&
  tr -d '\n' < "$1/dtb.sorted" > "$1/dtb.set" &&
  [ "$(f60_hash "$1/dtb.set")" = "$FAMILY_DTB_SET_SHA" ]
)

f60_family_stock() (
  export LC_ALL=C
  base=$1/kernel.base
  [ "$(f60_size "$base")" = "$STOCK_PLAIN_SIZE" ] || exit 1
  cp "$base" "$1/kernel.mask" || exit 1
  for field in host time; do
    case "$field" in
      host) fields=$FAMILY_HOST_FIELDS width=12 pattern='^[0-9a-f]{12}$' ;;
      time) fields=$FAMILY_TIME_FIELDS width=28 pattern='^[A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-9][0-9] [0-9:]{8} UTC [0-9]{4}$' ;;
    esac
    first=
    for offset in $(printf '%s' "$fields" | tr '+' ' '); do
      f60_range "$base" "$offset" "$width" > "$1/build.$offset" &&
      [ "$(f60_size "$1/build.$offset")" = "$width" ] &&
      grep -aEq "$pattern" "$1/build.$offset" &&
      f60_zero "$1/kernel.mask" "$offset" "$width" || exit 1
      if [ -n "$first" ]; then
        cmp -s "$first" "$1/build.$offset" || exit 1
      else
        first=$1/build.$offset
      fi
    done
  done
  end=$(f60_le32 "$base" "$FAMILY_BUILTIN_PTR") || exit 1
  length=$((end - FAMILY_BUILTIN_OFFSET))
  size_field=$((FAMILY_BUILTIN_OFFSET + FAMILY_BUILTIN_LIMIT))
  [ "$length" -ge 18 ] && [ "$length" -le "$FAMILY_BUILTIN_LIMIT" ] &&
  [ "$(f60_le32 "$base" "$size_field")" = "$length" ] &&
  f60_zero_range "$base" "$1" "$end" "$((size_field - end))" &&
  f60_range "$base" "$FAMILY_BUILTIN_OFFSET" "$length" > "$1/builtin.gz" &&
  [ "$(od -An -v -tx1 -N 4 "$1/builtin.gz" | tr -d ' \n')" = 1f8b0800 ] &&
  [ "$(f60_le32 "$1/builtin.gz" "$((length - 4))")" = 512 ] &&
  gzip -dc "$1/builtin.gz" > "$1/builtin.cpio" &&
  [ "$(f60_size "$1/builtin.cpio")" = 512 ] || exit 1
  for offset in $(printf '%s' "$FAMILY_BUILTIN_MTIMES" | tr '+' ' '); do
    f60_range "$1/builtin.cpio" "$offset" 8 > "$1/mtime" &&
    grep -aEq '^[0-9A-Fa-f]{8}$' "$1/mtime" &&
    f60_zero "$1/builtin.cpio" "$offset" 8 || exit 1
  done
  [ "$(f60_hash "$1/builtin.cpio")" = "$FAMILY_BUILTIN_CPIO_SHA" ] &&
  f60_zero "$1/kernel.mask" "$FAMILY_BUILD_ID_OFFSET" 8 &&
  f60_zero "$1/kernel.mask" "$FAMILY_BUILTIN_PTR" 4 &&
  f60_zero "$1/kernel.mask" "$FAMILY_BUILTIN_OFFSET" "$((FAMILY_BUILTIN_LIMIT + 4))" &&
  [ "$(f60_hash "$1/kernel.mask")" = "$FAMILY_STOCK_SHA" ]
)

f60_hash_in_set() {
  [ ${#1} = 64 ] || return 1
  case "+$2+" in *"+$1+"*) return 0 ;; esac
  return 1
}
