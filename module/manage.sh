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
umask 077

# Fixed commands and encoded fields keep property values out of shell/HTML code.
f60_field() {
  printf '%s\t' "$1"
  printf '%s' "$2" | base64 | tr -d '\n'
  printf '\n'
}

f60_managed_backup() {
  F60_MANAGED_BACKUP=
  [ -f "$F60_STATE/latest-backup" ] || return 1
  candidate=$(cat "$F60_STATE/latest-backup") || return 1
  case "$candidate" in "$F60_STATE"/backup-*) ;; *) return 1 ;; esac
  [ -d "$candidate" ] && [ "$(readlink -f "$candidate")" = "$candidate" ] || return 1
  grep -Fxq "lineage=$TARGET_VERSION" "$candidate/device.txt" &&
  grep -Fxq "incremental=$TARGET_INCREMENTAL" "$candidate/device.txt" &&
  grep -Fxq "profile=$TARGET_ID" "$candidate/device.txt" &&
  grep -Fxq "partition=$F60_BOOT" "$candidate/device.txt" || return 1
  [ -f "$candidate/boot-before.img" ] &&
  [ -f "$candidate/boot-after.img" ] && [ -f "$candidate/SHA256SUMS" ] || return 1
  F60_MANAGED_BACKUP=$candidate
}

f60_manage_status() {
  supported=0 ready=0 running=0 driver=0 busy=0
  disk_state=unknown
  F60_MANAGED_BACKUP=
  if [ -d "$F60_STATE/lock" ] || [ -d "$F60_STATE/manage-lock" ]; then
    busy=1
  fi
  if f60_load >/dev/null 2>&1; then
    supported=1
    [ "$(uname -r)" = "$FIXED_RELEASE" ] && running=1
    [ "$(readlink -f /sys/bus/i2c/devices/3-0050/driver)" = /sys/bus/i2c/drivers/ndt_press_f60 ] &&
      driver=1
    if [ "$(id -u)" = 0 ] && f60_environment >/dev/null 2>&1; then
      ready=1
      if [ "$busy" = 0 ] && f60_managed_backup; then
        before_sha=$(awk '$2 == "boot-before.img" {print $1}' "$F60_MANAGED_BACKUP/SHA256SUMS")
        after_sha=$(awk '$2 == "boot-after.img" {print $1}' "$F60_MANAGED_BACKUP/SHA256SUMS")
        boot_sha=$(f60_hash "$F60_BOOT")
        disk_state=changed
        if [ "${#boot_sha}" = 64 ] && [ "$boot_sha" = "$before_sha" ]; then
          disk_state=restored
        elif [ "${#boot_sha}" = 64 ] && [ "$boot_sha" = "$after_sha" ]; then
          disk_state=fixed
        fi
      fi
    fi
  fi
  root_name=Magisk
  [ -x /data/adb/apd ] && root_name=APatch
  [ -e "$MODPATH/remove" ] && ready=0
  [ -e "$MODPATH/disable" ] && ready=0
  f60_field protocol 1
  f60_field supported "$supported"
  f60_field ready "$ready"
  f60_field busy "$busy"
  f60_field root "$root_name"
  f60_field rom "$(getprop ro.lineage.version)"
  f60_field kernel "$(uname -r)"
  f60_field running "$running"
  f60_field driver "$driver"
  f60_field disk "$disk_state"
  f60_field backup "$F60_MANAGED_BACKUP"
  f60_field version "$(sed -n 's/^version=//p' "$MODPATH/module.prop")"
}

f60_manage_operation() {
  [ "$2" = --confirm ] || { f60_error "Explicit confirmation is required."; return 2; }
  [ ! -e "$MODPATH/remove" ] && [ ! -e "$MODPATH/disable" ] ||
    { f60_error "Enable the module and cancel removal before continuing."; return 1; }
  mkdir -p "$F60_STATE" && chmod 700 "$F60_STATE" || return 1
  case "$1" in
    install) f60_install ;;
    uninstall)
      f60_load && f60_environment && f60_managed_backup ||
        { f60_error "No matching installation backup. Nothing written."; return 1; }
      f60_restore --restore "$F60_MANAGED_BACKUP"
      ;;
  esac
}

case "$1" in
  status) f60_manage_status ;;
  log)
    [ -f "$F60_STATE/manage.log" ] && tail -n 250 "$F60_STATE/manage.log"
    exit 0
    ;;
  install|uninstall)
    [ "$(id -u)" = 0 ] || { f60_error "Root required."; exit 1; }
    # Keep concurrent pages from overwriting one another's operation log.
    mkdir -p "$F60_STATE" || exit 1
    mkdir "$F60_STATE/manage-lock" 2>/dev/null ||
      { f60_error "Another management operation is in progress."; exit 1; }
    trap 'rmdir "$F60_STATE/manage-lock" 2>/dev/null' EXIT
    f60_manage_operation "$@" > "$F60_STATE/manage.log" 2>&1
    result=$?
    cat "$F60_STATE/manage.log"
    exit "$result"
    ;;
  *) f60_error "Allowed commands: status, log, install --confirm, uninstall --confirm."; exit 2 ;;
esac
