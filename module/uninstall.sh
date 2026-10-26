#!/system/bin/sh
# A kernel written to boot outlives a module. Automatic restoration during
# uninstall is unsafe after an OTA or another root/kernel change.
umask 077
mkdir -p /data/adb/ursa_ndt_f60
printf '%s\n' \
  'Module removed. Boot was NOT restored. Backups remain in this directory.' \
  'Use the matching package restore.sh or fastboot with boot-before.img.' \
  > /data/adb/ursa_ndt_f60/uninstalled.txt
