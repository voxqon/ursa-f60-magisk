#!/system/bin/sh
# APatch runs this after Android has finished booting with the updated ROM.
MODDIR=${0%/*}
[ -x /data/adb/apd ] && [ -f /data/adb/ursa_ndt_f60/auto-repair ] || exit 0
export ASH_STANDALONE=1
exec /data/adb/ap/bin/busybox sh "$MODDIR/manage.sh" auto-repair
