#!/system/bin/sh
MODPATH=${0%/*}
if pm path io.github.a13e300.ksuwebui >/dev/null 2>&1; then
  if am start -n io.github.a13e300.ksuwebui/.WebUIActivity \
    --es id ursa_ndt_f60 --es name "Ursa F60" >/dev/null 2>&1; then
    exit 0
  fi
fi
. "$MODPATH/lib.sh"
f60_status
echo
echo "Backup directories (copy boot-before.img to your computer):"
for backup in "$F60_STATE"/backup-*; do
  [ -d "$backup" ] && echo "$backup"
done
echo "Restore command (root shell, replace BACKUP_DIRECTORY):"
if [ -x /data/adb/ap/bin/busybox ]; then
  echo "ASH_STANDALONE=1 /data/adb/ap/bin/busybox sh $MODPATH/restore.sh --restore BACKUP_DIRECTORY"
else
  echo "ASH_STANDALONE=1 /data/adb/magisk/busybox sh $MODPATH/restore.sh --restore BACKUP_DIRECTORY"
fi
echo "Disabling/removing this module does not restore boot."
echo "Open this module's WebUI in APatch or a compatible WebUI viewer to manage the repair."
