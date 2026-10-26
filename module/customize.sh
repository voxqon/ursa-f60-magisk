#!/system/bin/sh

[ "$BOOTMODE" = true ] || abort "Install from the Magisk or APatch app in Android only."
touch "$MODPATH/skip_mount" || abort "Cannot create skip_mount."
chmod 0755 "$MODPATH/payload/tools/magiskboot" "$MODPATH/payload/tools/kptools" ||
  abort "Cannot prepare packaged boot tools."
. "$MODPATH/lib.sh"
f60_load && f60_environment || abort "Unsupported device, ROM build or root environment."
set_perm_recursive "$MODPATH" 0 0 0755 0644
for script in action.sh restore.sh uninstall.sh manage.sh; do
  set_perm "$MODPATH/$script" 0 0 0755
done
set_perm "$MODPATH/payload/tools/magiskboot" 0 0 0755
set_perm "$MODPATH/payload/tools/kptools" 0 0 0755
ui_print "- F60 management page installed. Boot was NOT written."
ui_print "- Open WebUI after the module is enabled to install or uninstall the repair."
ui_print "- APatch supports WebUI; Magisk requires a compatible WebUI viewer."
