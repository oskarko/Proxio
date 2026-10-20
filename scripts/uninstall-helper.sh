#!/bin/sh
# Removes Proxio's privileged helper (dev.proxio.helper) from this Mac and, optionally, turns off
# any web proxy that points at Proxio.
#
#   scripts/uninstall-helper.sh            show what is installed, ask before changing anything
#   scripts/uninstall-helper.sh --yes      no questions
#
# The preferred way is Proxio → Settings → System → Uninstall, which also removes the Login Items entry.
# This script is the fallback when the app is gone or the helper is stuck. It needs sudo for launchctl.
set -u
LABEL=dev.proxio.helper
YES=0
[ "${1:-}" = "--yes" ] && YES=1

confirm() {
  [ "$YES" = 1 ] && return 0
  printf '%s [y/N] ' "$1"
  read -r answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

echo "== Helper =="
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  echo "Loaded: system/$LABEL"
  if confirm "Unload $LABEL (sudo)?"; then
    sudo launchctl bootout "system/$LABEL" && echo "Unloaded."
  fi
else
  echo "Not loaded."
fi

echo
echo "== System proxy =="
networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//' | while IFS= read -r service; do
  for kind in webproxy securewebproxy; do
    out=$(networksetup "-get$kind" "$service" 2>/dev/null)
    host=$(printf '%s\n' "$out" | awk -F': ' '/^Server/ {print $2}')
    enabled=$(printf '%s\n' "$out" | awk -F': ' '/^Enabled/ {print $2}')
    if [ "$enabled" = "Yes" ] && { [ "$host" = "127.0.0.1" ] || [ "$host" = "localhost" ]; }; then
      port=$(printf '%s\n' "$out" | awk -F': ' '/^Port/ {print $2}')
      echo "$service: $kind -> $host:$port"
      if confirm "Turn off $kind on \"$service\"?"; then
        networksetup "-set${kind}state" "$service" off && echo "  off."
      fi
    fi
  done
done

echo
echo "Done. If Proxio still appears under System Settings → General → Login Items,"
echo "open the app and use Settings → System → Uninstall, or remove the entry there by hand."
