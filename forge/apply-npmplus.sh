#!/bin/sh
# Idempotent WireGuard setup on the npmplus LXC (Alpine: apk + OpenRC).
# Pushed and executed by `just forge apply-npmplus`; expects wg0.conf beside it.
set -eu

STAGING="$(cd "$(dirname "$0")" && pwd)"
CHANGED=""

apk info -e wireguard-tools >/dev/null 2>&1 || {
  apk add --no-cache wireguard-tools
  CHANGED="$CHANGED packages:wireguard-tools"
}

if ! cmp -s "$STAGING/wg0.conf" /etc/wireguard/wg0.conf 2>/dev/null; then
  mkdir -p /etc/wireguard
  cp "$STAGING/wg0.conf" /etc/wireguard/wg0.conf
  chmod 600 /etc/wireguard/wg0.conf
  CHANGED="$CHANGED wg0.conf"
fi

# Alpine's wireguard-tools ships an OpenRC wg-quick script; per-interface via symlink
[ -e /etc/init.d/wg-quick.wg0 ] || ln -s wg-quick /etc/init.d/wg-quick.wg0
rc-update -q add wg-quick.wg0 default 2>/dev/null || true

if [ -n "$CHANGED" ]; then
  rc-service wg-quick.wg0 restart 2>/dev/null || rc-service wg-quick.wg0 start
  echo "changed:$CHANGED"
else
  rc-service -q wg-quick.wg0 status >/dev/null 2>&1 || rc-service wg-quick.wg0 start
  echo "no changes"
fi

wg show wg0 latest-handshakes
