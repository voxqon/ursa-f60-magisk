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
  grep -Fxq "partition=$F60_BOOT" "$candidate/device.txt" || return 1
  [ -f "$candidate/boot-before.img" ] &&
  [ -f "$candidate/boot-after.img" ] && [ -f "$candidate/SHA256SUMS" ] || return 1
  F60_MANAGED_BACKUP=$candidate
}

f60_manage_status() {
  supported=0 ready=0 running=0 driver=0 busy=0 auto=0
  disk_state=unknown
  F60_MANAGED_BACKUP=
  if [ -d "$F60_STATE/lock" ] || [ -d "$F60_STATE/manage-lock" ]; then
    busy=1
  fi
  if f60_load >/dev/null 2>&1; then
    supported=1
    f60_running_fix && running=1
    f60_driver_bound && driver=1
    if [ "$(id -u)" = 0 ] && f60_environment >/dev/null 2>&1; then
      ready=1
      if [ "$busy" = 0 ] && f60_managed_backup; then
        before_sha=$(awk '$2 == "boot-before.img" {print $1}' "$F60_MANAGED_BACKUP/SHA256SUMS")
        after_sha=$(awk '$2 == "boot-after.img" {print $1}' "$F60_MANAGED_BACKUP/SHA256SUMS")
        boot_sha=$(f60_hash "$F60_BOOT")
        disk_state=changed
        if [ "${#boot_sha}" = 64 ] && [ "$boot_sha" = "$before_sha" ]; then
          disk_state=stock
          [ "$(cat "$F60_MANAGED_BACKUP/write-status" 2>/dev/null)" = restored ] && disk_state=restored
        elif [ "${#boot_sha}" = 64 ] && [ "$boot_sha" = "$after_sha" ]; then
          disk_state=fixed
        fi
      fi
    fi
  fi
  root_name=Magisk
  [ -x /data/adb/apd ] && root_name=APatch
  f60_module_enabled || ready=0
  [ -f "$F60_STATE/auto-repair" ] && auto=1
  f60_field protocol 2
  f60_field supported "$supported"
  f60_field adaptive "${F60_FAMILY:-0}"
  f60_field ready "$ready"
  f60_field busy "$busy"
  f60_field auto "$auto"
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
  if [ "$1" = auto-off ]; then
    rm -f "$F60_STATE/auto-repair"
    return "$?"
  fi
  f60_module_enabled ||
    { f60_error "Enable the module and cancel removal before continuing."; return 1; }
  mkdir -p "$F60_STATE" && chmod 700 "$F60_STATE" || return 1
  case "$1" in
    install) f60_install ;;
    auto-on)
      f60_load && f60_environment && [ "$F60_ROOT" = apatch ] ||
        { f60_error "Automatic repair requires a supported APatch environment."; return 1; }
      touch "$F60_STATE/auto-repair"
      ;;
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
    for log in manage.log auto.log; do
      [ -s "$F60_STATE/$log" ] || continue
      printf '=== %s ===\n' "$log"
      tail -n 125 "$F60_STATE/$log"
    done
    exit 0
    ;;
  install|uninstall|auto-on|auto-off|auto-repair)
    [ "$(id -u)" = 0 ] || { f60_error "Root required."; exit 1; }
    # Keep concurrent pages from overwriting one another's operation log.
    if [ "$1" = auto-repair ]; then
      [ -x /data/adb/apd ] && [ -f "$F60_STATE/auto-repair" ] && f60_module_enabled || exit 0
      # Keep the last operation log on normal boots with the working driver.
      f60_driver_bound && exit 0
      if f60_load >/dev/null 2>&1 && f60_running_fix; then exit 0; fi
    fi
    mkdir -p "$F60_STATE" && chmod 700 "$F60_STATE" || exit 1
    mkdir "$F60_STATE/manage-lock" 2>/dev/null ||
      { f60_error "Another management operation is in progress."; exit 1; }
    trap 'rmdir "$F60_STATE/manage-lock" 2>/dev/null' EXIT
    if [ "$1" = auto-repair ]; then
      f60_install auto > "$F60_STATE/auto.log" 2>&1
      exit "$?"
    fi
    if [ "$1" = auto-on ] || [ "$1" = auto-off ]; then
      f60_manage_operation "$@"
      exit "$?"
    fi
    f60_manage_operation "$@" > "$F60_STATE/manage.log" 2>&1
    result=$?
    cat "$F60_STATE/manage.log"
    exit "$result"
    ;;
  *) f60_error "Allowed commands: status, log, install, uninstall, auto-on, auto-off (writes require --confirm)."; exit 2 ;;
esac
