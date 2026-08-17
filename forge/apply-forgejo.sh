#!/usr/bin/env bash
# Idempotent config apply for the forgejo LXC.
# Pushed and executed by `just forge apply-forgejo`; expects app.ini beside it.
set -euo pipefail
STAGING="$(cd "$(dirname "$0")" && pwd)"
UNIT=/etc/systemd/system/forgejo.service
CHANGED=()

# --- run user: enforce 'git' so remotes are git@forgejo.vaderrp.com ---------
if ! id git &>/dev/null; then
  if id forgejo &>/dev/null; then
    systemctl stop forgejo
    usermod -l git -d /home/git -m forgejo
    groupmod -n git forgejo 2>/dev/null || true
    sed -i 's/User=forgejo/User=git/; s/Group=forgejo/Group=git/' "$UNIT"
    systemctl daemon-reload
    CHANGED+=("run user forgejo -> git")
  else
    echo "ERROR: neither 'git' nor 'forgejo' user exists" >&2
    exit 1
  fi
fi
grep -q '^User=git$' "$UNIT" || { echo "ERROR: $UNIT does not run as git" >&2; exit 1; }

# --- app.ini -----------------------------------------------------------------
if ! cmp -s "$STAGING/app.ini" /etc/forgejo/app.ini; then
  install -m 640 -o root -g git "$STAGING/app.ini" /etc/forgejo/app.ini
  CHANGED+=("/etc/forgejo/app.ini")
fi

chown -R git:git /var/lib/forgejo

if ((${#CHANGED[@]})); then
  systemctl restart forgejo
  printf 'changed: %s\n' "${CHANGED[@]}"
else
  echo "no changes"
fi
systemctl is-active --quiet forgejo || { echo "forgejo failed to start" >&2; exit 1; }
