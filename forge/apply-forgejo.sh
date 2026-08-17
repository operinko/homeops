#!/usr/bin/env bash
# Idempotent config apply for the forgejo LXC.
# Pushed and executed by `just forge apply-forgejo`; expects app.ini and
# sshd-forgejo.conf beside it.
set -euo pipefail
STAGING="$(cd "$(dirname "$0")" && pwd)"
UNIT=/etc/systemd/system/forgejo.service
SSHD_DROPIN=/etc/ssh/sshd_config.d/60-forgejo.conf
CHANGED=()
RESTART_FORGEJO=0

# --- run user: enforce 'git' so remotes are git@forgejo.vaderrp.com ---------
if ! id git &>/dev/null; then
  if id forgejo &>/dev/null; then
    systemctl stop forgejo
    usermod -l git -d /home/git -m forgejo
    groupmod -n git forgejo 2>/dev/null || true
    sed -i 's/User=forgejo/User=git/; s/Group=forgejo/Group=git/' "$UNIT"
    systemctl daemon-reload
    CHANGED+=("run user forgejo -> git")
    RESTART_FORGEJO=1
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
  RESTART_FORGEJO=1
fi

chown -R git:git /var/lib/forgejo

# --- sshd: connections via the npmplus proxy (192.168.0.5) are git-only ------
if ! grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config; then
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  CHANGED+=("/etc/ssh/sshd_config Include")
fi
if ! cmp -s "$STAGING/sshd-forgejo.conf" "$SSHD_DROPIN"; then
  if [[ -e "$SSHD_DROPIN" ]]; then cp -a "$SSHD_DROPIN" "$SSHD_DROPIN.bak"; fi
  install -D -m 644 -o root -g root "$STAGING/sshd-forgejo.conf" "$SSHD_DROPIN"
  if ! /usr/sbin/sshd -t; then
    if [[ -e "$SSHD_DROPIN.bak" ]]; then mv "$SSHD_DROPIN.bak" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
    echo "ERROR: sshd -t rejected $SSHD_DROPIN; reverted, service untouched" >&2
    exit 1
  fi
  rm -f "$SSHD_DROPIN.bak"
  # restart, not reload: ssh.service is socket-activated here, and SIGHUP makes
  # the listener re-exec without its systemd-passed FDs and die. KillMode=process
  # keeps established sessions alive across the restart.
  systemctl restart ssh
  CHANGED+=("$SSHD_DROPIN")
fi

if ((RESTART_FORGEJO)); then
  systemctl restart forgejo
fi

if ((${#CHANGED[@]})); then
  printf 'changed: %s\n' "${CHANGED[@]}"
else
  echo "no changes"
fi
systemctl is-active --quiet forgejo || { echo "forgejo failed to start" >&2; exit 1; }
