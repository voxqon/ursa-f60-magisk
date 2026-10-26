#!/system/bin/sh
if [ "$ASH_STANDALONE" != 1 ]; then
  export ASH_STANDALONE=1
  if [ -x /data/adb/ap/bin/busybox ]; then
    exec /data/adb/ap/bin/busybox sh "$0" "$@"
  fi
  exec /data/adb/magisk/busybox sh "$0" "$@"
fi
MODPATH=${0%/*}
. "$MODPATH/lib.sh"
f60_restore "$@"
