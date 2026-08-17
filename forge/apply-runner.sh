#!/usr/bin/env bash
# Idempotent runner apply: swap podman -> docker-ce, install config, register.
# Registration token is fetched lazily; pass FORGEJO_RUNNER_TOKEN env if re-registering.
set -euo pipefail
STAGING="$(cd "$(dirname "$0")" && pwd)"
CHANGED=()
export DEBIAN_FRONTEND=noninteractive

# `dpkg -s` also succeeds for purged-but-not-purged packages (Status
# "deinstall ok config-files"), which would make the podman branch below fire on
# every run. Only a "installed" status counts.
pkg_installed() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx installed; }

# --- docker-ce instead of podman --------------------------------------------
if pkg_installed podman || pkg_installed podman-docker; then
  systemctl disable --now podman.socket podman 2>/dev/null || true
  apt-get purge -y -qq podman podman-docker
  apt-get autoremove --purge -y -qq
  CHANGED+=("removed podman")
fi
if ! pkg_installed docker-ce; then
  apt-get update -qq && apt-get install -y -qq ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin qemu-user-static
  systemctl enable --now docker
  CHANGED+=("installed docker-ce + qemu-user-static")
fi

# --- runner config -----------------------------------------------------------
mkdir -p /etc/forgejo-runner
if ! cmp -s "$STAGING/config.yaml" /etc/forgejo-runner/config.yaml 2>/dev/null; then
  install -m 600 "$STAGING/config.yaml" /etc/forgejo-runner/config.yaml
  CHANGED+=("/etc/forgejo-runner/config.yaml")
fi

# --- registration (once; .runner survives config changes) --------------------
if [[ ! -s /etc/forgejo-runner/.runner ]]; then
  : "${FORGEJO_RUNNER_TOKEN:?set FORGEJO_RUNNER_TOKEN to register}"
  (cd /etc/forgejo-runner && forgejo-runner register --no-interactive \
    --instance https://forgejo.vaderrp.com \
    --token "$FORGEJO_RUNNER_TOKEN" \
    --name "$(hostname)" \
    --labels "ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-latest,linux-amd64:docker://node:22-bookworm")
  CHANGED+=("registered runner")
fi

# --- systemd unit (replace community-scripts podman-flavored unit) ----------
cat > /etc/systemd/system/forgejo-runner.service.new <<'EOF'
[Unit]
Description=Forgejo Runner
After=docker.service network-online.target
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/forgejo-runner
ExecStart=/usr/local/bin/forgejo-runner daemon --config /etc/forgejo-runner/config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
if ! cmp -s /etc/systemd/system/forgejo-runner.service.new /etc/systemd/system/forgejo-runner.service; then
  mv /etc/systemd/system/forgejo-runner.service.new /etc/systemd/system/forgejo-runner.service
  systemctl daemon-reload
  CHANGED+=("forgejo-runner.service")
else
  rm /etc/systemd/system/forgejo-runner.service.new
fi

if ((${#CHANGED[@]})); then
  systemctl enable --now forgejo-runner
  systemctl restart forgejo-runner
  printf 'changed: %s\n' "${CHANGED[@]}"
else
  echo "no changes"
fi
systemctl is-active --quiet forgejo-runner || { echo "runner failed to start" >&2; exit 1; }
