# ForgeJo Authoritative Forge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Self-hosted ForgeJo on meanie becomes the authoritative forge for all repos (GitHub demoted to push mirror), with two Docker-based Forgejo Actions runner LXCs, public SSH/HTTPS access via the wg-haproxy VPS through npmplus, self-hosted Renovate, and Flux cut over to pull from ForgeJo.

**Architecture:** Three community-scripts-provisioned Debian LXCs on meanie (forgejo native binary + SQLite; 2× forgejo-runner with Docker CE). Day-2 config lives in a new `forge/` repo module (vps-style: SOPS + minijinja + idempotent remote apply scripts). npmplus terminates TLS and stream-forwards SSH; it is the single home-side WireGuard peer for the VPS, whose haproxy passes through TCP :22 and SNI-routed :443. Spec: `docs/superpowers/specs/2026-08-17-forgejo-authoritative-forge-design.md`.

**Tech Stack:** Proxmox/pct, community-scripts, Forgejo, forgejo-runner, Docker CE, WireGuard, haproxy, NPMplus, Technitium DNS, SOPS/age, minijinja, just, Flux (flux-operator FluxInstance), Renovate, Authentik OIDC.

## Global Constraints

- Run all `just`/bash steps in WSL (Windows mise is broken; `just` auto-wraps mise). SSH keys for meanie/VPS live in the WSL home.
- Root SSH to meanie is available; LXCs are reached via `pct exec` from meanie or directly over SSH once keys are installed.
- No secrets in git outside SOPS-encrypted files. Age key: `age.key` at repo root (already configured via `.mise.toml`).
- Commit style: conventional commits like the existing history (`feat(forge): …`, `ci: …`, `docs: …`). Never add `Co-Authored-By` or AI attribution.
- If GPG signing times out ("gpg: signing failed: Timeout"), retry the commit with `--no-gpg-sign` (user-approved).
- Verify every claim with a command before marking a step done (verification-before-completion).
- Fixed values used throughout (updated with Task 0 discovery results, 2026-08-17):
  - Forge LXC: VMID **130**, hostname `forgejo`, IP `192.168.7.30/24`, gw `192.168.7.1`, 2 cores / 2048 MB / 20 GB
  - Runner LXCs: VMID **131** `forgejo-runner1` `192.168.7.31/24`; VMID **132** `forgejo-runner2` `192.168.7.32/24`; each 4 cores / 8192 MB / 60 GB
  - **Bridge for 192.168.7.x is `node`** (OVS VLAN 7 port on meanie; `vmbr0` untagged = 192.168.0.x). Storage pool: **`tank-zfs`**.
  - npmplus LXC: VMID **107** (113 is emqx!), IP `192.168.0.5` (`NPMPLUS_IP`) — on the 0.x LAN, reaches the forge via inter-VLAN routing (verify in Task 5)
  - WireGuard: VPS `172.16.8.2` (existing, currently auto listen port 52385), npmplus peer `172.16.8.20/32`, VPS adds `ListenPort = 51820` (no VPS firewall blockers); VPS public IP `212.147.241.182`
  - PBS: jobs select by resource pool — forge → `critical` pool (daily 04:00), runners → `kube` pool (weekly Fri) (user decision, Task 11)
  - Org: `operinko-labs`; primary repo `homeops`; domain `forgejo.vaderrp.com`; Authentik at `https://auth.vaderrp.com`
  - Forgejo layout: config `/etc/forgejo/app.ini`, data `/var/lib/forgejo`, run user `git` (Task 2 enforces)

---

### Task 0: Preflight discovery on meanie

**Files:**
- None (read-only; results recorded in Task 1's `forge/mod.just`)

**Interfaces:**
- Produces: confirmed `NPMPLUS_IP`, free VMIDs 130–132, free IPs 192.168.7.30–32, bridge name (expected `vmbr0`), storage name (expected `tank` or `local-zfs`), PBS backup-job selection mode.

- [ ] **Step 1: Verify SSH and inventory meanie**

```bash
ssh root@meanie.vaderrp.com 'hostname; pveversion; pct list'
```
(If `meanie.vaderrp.com` doesn't resolve, ask the user for meanie's IP and use it everywhere below.)
Expected: LXC list including 113 (npmplus); confirm 130/131/132 absent.

- [ ] **Step 2: Record npmplus network config and bridge/storage names**

```bash
ssh root@meanie.vaderrp.com 'pct config 113; pvesm status'
```
Record: `NPMPLUS_IP` from `net0` (or from `pct exec 113 -- ip -4 addr show dev eth0` if DHCP), bridge (`vmbr0`), and the storage pool to use for new LXCs.

- [ ] **Step 3: Confirm candidate IPs are free**

```bash
ssh root@meanie.vaderrp.com 'for i in 30 31 32; do ping -c1 -W1 192.168.7.$i >/dev/null 2>&1 && echo "192.168.7.$i TAKEN" || echo "192.168.7.$i free"; done'
```
Expected: all three `free`. If not, pick nearby free IPs and update the Global Constraints values in this plan file (edit + commit).

- [ ] **Step 4: Record PBS backup job configuration**

```bash
ssh root@meanie.vaderrp.com 'cat /etc/pve/jobs.cfg'
```
Record whether the backup job uses `all: 1` (new LXCs auto-included → Task 11 is a verify-only step) or an explicit `vmid` list (Task 11 must append 130,131,132).

- [ ] **Step 5: Verify VPS UDP 51820 will be reachable**

```bash
ssh -p 2222 root@212.147.241.182 'wg show wg0 | head -5; ss -lun | grep 51820 || echo "no listener yet (expected before Task 5)"'
```
Expected: wg0 up; no listener yet. (UpCloud has no default inbound firewall on this box; if `ufw`/UpCloud firewall is active, note it and open UDP 51820 in Task 5.)

---

### Task 1: `forge/` module scaffold

**Files:**
- Modify: `.sops.yaml` (add forge rule)
- Modify: `.justfile:9` (register module)
- Create: `forge/mod.just`
- Create: `forge/secrets.sops.yaml`
- Create: `forge/README.md`

**Interfaces:**
- Produces: `just forge <recipe>` namespace; SOPS-encrypted secret store `forge/secrets.sops.yaml` with keys added incrementally by later tasks; variables `forge_ip`, `npmplus_ip`, `runner1_ip`, `runner2_ip` consumed by all later apply recipes.

- [ ] **Step 1: Add SOPS creation rule**

In `.sops.yaml`, after the `vps/` rule (line 8-9), add:

```yaml
  - path_regex: forge/.*\.sops\.ya?ml
    age: "age18hklnzlqlz0y7tf8gzeh2slv8vxnlyvjcn7e38xsd744s3t9hf0su4lwpx"
```

- [ ] **Step 2: Register the module**

In `.justfile`, after `mod vps "vps"`:

```just
mod forge "forge"
```

- [ ] **Step 3: Create `forge/mod.just`**

```just
set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

forge_dir := justfile_dir() + '/forge'
forge_ip := '192.168.7.30'
npmplus_ip := '192.168.0.5'
runner1_ip := '192.168.7.31'
runner2_ip := '192.168.7.32'

[private]
default:
    just -l forge

[doc('Apply Forgejo config to the forge LXC')]
apply-forgejo:
    ssh root@{{ forge_ip }} 'mkdir -p -m 700 /root/.homeops-staging'
    sops -d {{ forge_dir }}/secrets.sops.yaml | minijinja-cli {{ forge_dir }}/config/app.ini.j2 --format yaml - | ssh root@{{ forge_ip }} 'umask 077; cat > /root/.homeops-staging/app.ini'
    scp -q {{ forge_dir }}/apply-forgejo.sh root@{{ forge_ip }}:/root/.homeops-staging/
    ssh root@{{ forge_ip }} 'bash /root/.homeops-staging/apply-forgejo.sh; rc=$?; rm -rf /root/.homeops-staging; exit $rc'

[doc('Apply runner config: just forge apply-runner 1|2 (set FORGEJO_RUNNER_TOKEN to (re)register)')]
apply-runner n:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$([ "{{ n }}" = "1" ] && echo "{{ runner1_ip }}" || echo "{{ runner2_ip }}")
    ssh root@$ip 'mkdir -p -m 700 /root/.homeops-staging'
    sops -d {{ forge_dir }}/secrets.sops.yaml | minijinja-cli {{ forge_dir }}/config/runner-config.yaml.j2 --format yaml - | ssh root@$ip 'umask 077; cat > /root/.homeops-staging/config.yaml'
    scp -q {{ forge_dir }}/apply-runner.sh root@$ip:/root/.homeops-staging/
    ssh root@$ip "FORGEJO_RUNNER_TOKEN='${FORGEJO_RUNNER_TOKEN:-}' bash /root/.homeops-staging/apply-runner.sh; rc=\$?; rm -rf /root/.homeops-staging; exit \$rc"

[doc('Apply WireGuard + stream config to the npmplus LXC')]
apply-npmplus:
    ssh root@{{ npmplus_ip }} 'mkdir -p -m 700 /root/.homeops-staging'
    sops -d {{ forge_dir }}/secrets.sops.yaml | minijinja-cli {{ forge_dir }}/config/wg0-npmplus.conf.j2 --format yaml - | ssh root@{{ npmplus_ip }} 'umask 077; cat > /root/.homeops-staging/wg0.conf'
    scp -q {{ forge_dir }}/apply-npmplus.sh root@{{ npmplus_ip }}:/root/.homeops-staging/
    ssh root@{{ npmplus_ip }} 'sh /root/.homeops-staging/apply-npmplus.sh; rc=$?; rm -rf /root/.homeops-staging; exit $rc'

[doc('One-time/idempotent Forgejo API-level state (org, mirrors, secrets)')]
setup:
    sops exec-env {{ forge_dir }}/secrets.sops.yaml 'bash {{ forge_dir }}/setup-forgejo.sh'

[doc('SSH into the forge LXC')]
ssh:
    ssh root@{{ forge_ip }}
```

Replace `NPMPLUS_IP_FROM_TASK0` with the actual IP recorded in Task 0.

- [ ] **Step 4: Create the encrypted secret store**

```bash
cat > forge/secrets.sops.yaml <<'EOF'
# Secrets for the forge module. Keys are added by later tasks:
# npmplus_wg_private_key, forgejo_admin_pat, github_mirror_pat,
# oidc_client_id, oidc_client_secret, renovate_pat,
# forgejo_secret_key, forgejo_internal_token,
# harbor_url, harbor_username, harbor_password, harbor_robot_password,
# cloudflare_api_token, cloudflare_account_id
placeholder: delete-me-when-first-real-key-lands
EOF
sops encrypt --in-place forge/secrets.sops.yaml
sops -d forge/secrets.sops.yaml
```
Expected: decrypt round-trip prints the placeholder key.

- [ ] **Step 5: Create `forge/README.md`**

```markdown
# forge/ — ForgeJo + runners on meanie

Design: `docs/superpowers/specs/2026-08-17-forgejo-authoritative-forge-design.md`

| Host | VMID | IP | Role |
|---|---|---|---|
| forgejo | 130 | 192.168.7.30 | Forgejo (native, SQLite), HTTP :3000, SSH :22 |
| forgejo-runner1 | 131 | 192.168.7.31 | forgejo-runner + Docker CE |
| forgejo-runner2 | 132 | 192.168.7.32 | forgejo-runner + Docker CE |
| npmplus | 113 | (existing) | TLS termination, :22 stream forward, WG peer to VPS |

- `just forge apply-forgejo|apply-runner 1|apply-runner 2|apply-npmplus` — idempotent config pushes
- `just forge setup` — Forgejo API-level state (org, OIDC source, mirrors, action secrets)
- Provisioning: community-scripts (`ct/forgejo.sh`, `ct/forgejo-runner.sh`) run on meanie; re-provisioning = script + apply.
- Manual state not covered here: Authentik provider/app (Task 3), NPMplus proxy-host/stream UI entries (Task 5), Cloudflare + Technitium DNS records (Tasks 5–6).
```

- [ ] **Step 6: Verify and commit**

```bash
just forge 2>&1 | head; git add .sops.yaml .justfile forge/ && git commit -m "feat(forge): scaffold forge module"
```
Expected: `just forge` lists the recipes.

---

### Task 2: Provision the forge LXC and bring Forgejo under module control

**Files:**
- Create: `forge/apply-forgejo.sh`
- Create: `forge/config/app.ini.j2`
- Modify: `forge/secrets.sops.yaml` (add `forgejo_secret_key`, `forgejo_internal_token`)

**Interfaces:**
- Produces: Forgejo at `http://192.168.7.30:3000`, SSH `git@192.168.7.30`, run user `git`, config `/etc/forgejo/app.ini` fully owned by `app.ini.j2`. Local admin account `ollie-admin`.

- [ ] **Step 1: Provision via community-scripts (Gitea mirror — GitHub raw is unreliable from meanie)**

GitHub raw is degraded (incident 2026-08-17); the user pre-staged GitHub-free copies of the scripts on meanie at `/root/forgejo/` (`forgejo.sh` + `build.func`, rewritten to pull from git.community-scripts.org):

```bash
ssh root@meanie.vaderrp.com 'export var_hostname=forgejo var_cpu=2 var_ram=2048 var_disk=20 var_unprivileged=1; bash /root/forgejo/forgejo.sh'
```
The wrapper uses whiptail dialogs — drive interactively (choose default settings; env presets carry resources). If the script version doesn't honor a `var_*`, fix afterwards: `pct set 130 -cores 2 -memory 2048`. For Task 7, replicate the same staging for `ct/forgejo-runner.sh` (mirror-download + sed the GitHub URLs, reuse `/root/forgejo/build.func`).

- [ ] **Step 2: Pin VMID/IP and install SSH access**

If the script chose a different VMID, note it and use it below. Set static network and install the WSL public key:

```bash
ssh root@meanie.vaderrp.com 'pct set 130 -net0 name=eth0,bridge=node,ip=192.168.7.30/24,gw=192.168.7.1 && pct reboot 130'
ssh root@meanie.vaderrp.com "pct exec 130 -- bash -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo \"$(cat ~/.ssh/id_ed25519.pub)\" >> /root/.ssh/authorized_keys'"
ssh root@192.168.7.30 'systemctl status forgejo --no-pager | head -5'
```
Expected: forgejo service active.

- [ ] **Step 3: Capture generated secrets into SOPS**

Forgejo generated `SECRET_KEY`/`INTERNAL_TOKEN` at install; they must survive our templated app.ini:

```bash
ssh root@192.168.7.30 "grep -E '^(SECRET_KEY|INTERNAL_TOKEN)' /etc/forgejo/app.ini"
sops set forge/secrets.sops.yaml '["forgejo_secret_key"]' '"<value from output>"'
sops set forge/secrets.sops.yaml '["forgejo_internal_token"]' '"<value from output>"'
sops unset forge/secrets.sops.yaml '["placeholder"]'
```
Also record the actual install layout if it differs from `/etc/forgejo/app.ini` + `/var/lib/forgejo` (check the unit: `ssh root@192.168.7.30 'systemctl cat forgejo'`) and adapt `apply-forgejo.sh` paths accordingly before proceeding.

- [ ] **Step 4: Write `forge/config/app.ini.j2`**

```ini
APP_NAME = Forgejo
RUN_USER = git
WORK_PATH = /var/lib/forgejo

[server]
PROTOCOL = http
HTTP_ADDR = 0.0.0.0
HTTP_PORT = 3000
DOMAIN = forgejo.vaderrp.com
ROOT_URL = https://forgejo.vaderrp.com/
SSH_DOMAIN = forgejo.vaderrp.com
SSH_PORT = 22
START_SSH_SERVER = false
LANDING_PAGE = login

[database]
DB_TYPE = sqlite3
PATH = /var/lib/forgejo/data/forgejo.db

[repository]
DEFAULT_PRIVATE = private
ENABLE_PUSH_CREATE_USER = true
ENABLE_PUSH_CREATE_ORG = true

[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = true
ALLOW_ONLY_EXTERNAL_REGISTRATION = true
SHOW_REGISTRATION_BUTTON = false

[oauth2_client]
ENABLE_AUTO_REGISTRATION = true
ACCOUNT_LINKING = auto
USERNAME = nickname

[actions]
ENABLED = true
DEFAULT_ACTIONS_URL = github

[mirror]
ENABLED = true

[security]
SECRET_KEY = {{ forgejo_secret_key }}
INTERNAL_TOKEN = {{ forgejo_internal_token }}
INSTALL_LOCK = true

[log]
MODE = console
LEVEL = info
```

- [ ] **Step 5: Write `forge/apply-forgejo.sh`**

```bash
#!/usr/bin/env bash
# Idempotent config apply for the forgejo LXC.
# Pushed and executed by `just forge apply-forgejo`; expects app.ini beside it.
set -euo pipefail
STAGING="$(cd "$(dirname "$0")" && pwd)"
CHANGED=()

# --- run user: enforce 'git' so remotes are git@forgejo.vaderrp.com ---------
if ! id git &>/dev/null; then
  if id forgejo &>/dev/null; then
    systemctl stop forgejo
    usermod -l git -d /home/git -m forgejo
    groupmod -n git forgejo 2>/dev/null || true
    sed -i 's/User=forgejo/User=git/; s/Group=forgejo/Group=git/' /etc/systemd/system/forgejo.service
    systemctl daemon-reload
    CHANGED+=("run user forgejo -> git")
  else
    echo "ERROR: neither 'git' nor 'forgejo' user exists" >&2; exit 1
  fi
fi

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
```

- [ ] **Step 6: Apply and verify**

```bash
just forge apply-forgejo
curl -s http://192.168.7.30:3000/api/v1/version
```
Expected: `changed: …` then `{"version":"…"}`. Second run of `just forge apply-forgejo` prints `no changes`.

- [ ] **Step 7: Create local break-glass admin + PAT**

```bash
ssh root@192.168.7.30 "su - git -s /bin/bash -c 'forgejo --config /etc/forgejo/app.ini admin user create --username ollie-admin --random-password --email olli.erinko@gmail.com --admin'"
ssh root@192.168.7.30 "su - git -s /bin/bash -c 'forgejo --config /etc/forgejo/app.ini admin user generate-access-token --username ollie-admin --token-name homeops-setup --scopes all --raw'"
sops set forge/secrets.sops.yaml '["forgejo_admin_pat"]' '"<token from output>"'
```
Report the random admin password to the user for their password manager. Verify: `curl -s -H "Authorization: token <PAT>" http://192.168.7.30:3000/api/v1/user | jq .login` → `"ollie-admin"`.

- [ ] **Step 8: Commit**

```bash
git add forge/ && git commit -m "feat(forge): forgejo lxc config apply"
```

---

### Task 3: Authentik OIDC login

**Files:**
- Modify: `forge/secrets.sops.yaml` (add `oidc_client_id`, `oidc_client_secret`)

**Interfaces:**
- Consumes: running Forgejo (Task 2), `forgejo_admin_pat`
- Produces: Forgejo auth source `authentik`; web login redirects to `auth.vaderrp.com`.

- [ ] **Step 1: Create the Authentik provider + application**

In Authentik (`https://auth.vaderrp.com`, admin interface) — this is UI work; ask the user to do it or use claude-in-chrome if available:
- Create **OAuth2/OpenID Provider**: name `forgejo`, authorization flow = default-provider-authorization-implicit-consent, redirect URI `https://forgejo.vaderrp.com/user/oauth2/authentik/callback`, signing key = authentik default.
- Create **Application**: name `Forgejo`, slug `forgejo`, provider `forgejo`.
- Record client ID + secret:

```bash
sops set forge/secrets.sops.yaml '["oidc_client_id"]' '"<client id>"'
sops set forge/secrets.sops.yaml '["oidc_client_secret"]' '"<client secret>"'
```

- [ ] **Step 2: Register the auth source in Forgejo**

```bash
ssh root@192.168.7.30 "su - git -s /bin/bash -c 'forgejo --config /etc/forgejo/app.ini admin auth add-oauth --name authentik --provider openidConnect --key <client id> --secret <client secret> --auto-discover-url https://auth.vaderrp.com/application/o/forgejo/.well-known/openid-configuration'"
```

- [ ] **Step 3: Verify**

```bash
curl -s http://192.168.7.30:3000/user/login | grep -o 'authentik'
```
Expected: `authentik` present (login page shows the OIDC option). Full login test happens in Task 6 once DNS/TLS exist.

- [ ] **Step 4: Commit**

```bash
git add forge/secrets.sops.yaml && git commit -m "feat(forge): authentik oidc client secrets"
```

---

### Task 4: Org, repo migration, push mirrors, action secrets

**Files:**
- Create: `forge/setup-forgejo.sh`
- Modify: `forge/secrets.sops.yaml` (add `github_mirror_pat`, `harbor_*`, `cloudflare_*`)

**Interfaces:**
- Consumes: `forgejo_admin_pat` (env `FORGEJO_ADMIN_PAT` via `sops exec-env`), `github_mirror_pat` (env `GITHUB_MIRROR_PAT`)
- Produces: org `operinko-labs` on Forgejo; every GitHub repo migrated with issues/PRs/releases; push mirror (sync-on-commit) per repo; org-level Actions secrets `HARBOR_URL`, `HARBOR_USERNAME`, `HARBOR_PASSWORD`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`.

- [ ] **Step 1: Collect secrets from the user**

Ask the user for (and store with `sops set forge/secrets.sops.yaml '["<key>"]' '"<value>"'`):
- `github_mirror_pat` — the **existing** broad GitHub PAT from the Vaultwarden "GHCR credentials" entry (the same one behind the `gpro-github-pat` ExternalSecret; user-confirmed it has wide enough permissions for migration + mirror pushes). Do not mint a new PAT. It can also be read from the cluster: `just kube view-secret gpro gpro-github-pat`.
- `harbor_url`, `harbor_username`, `harbor_password`, `harbor_robot_password` — current GitHub Actions secret values
- `cloudflare_api_token`, `cloudflare_account_id` — current GitHub Actions secret values

- [ ] **Step 2: Write `forge/setup-forgejo.sh`**

```bash
#!/usr/bin/env bash
# Idempotent Forgejo API-level state. Run via: just forge setup
# Env (from sops exec-env): forgejo_admin_pat, github_mirror_pat,
# harbor_url, harbor_username, harbor_password, harbor_robot_password,
# cloudflare_api_token, cloudflare_account_id
set -euo pipefail
API="http://192.168.7.30:3000/api/v1"
AUTH="Authorization: token ${forgejo_admin_pat}"
ORG="operinko-labs"
GH_USER="operinko-labs"   # GitHub org to migrate from

fj() { curl -sf -H "$AUTH" -H 'Content-Type: application/json' "$@"; }

# --- org ---------------------------------------------------------------------
if ! fj "$API/orgs/$ORG" >/dev/null 2>&1; then
  fj -X POST "$API/orgs" -d "{\"username\":\"$ORG\",\"visibility\":\"private\"}" >/dev/null
  echo "created org $ORG"
fi

# --- migrate + mirror every GitHub repo -------------------------------------
repos=$(curl -sf -H "Authorization: token ${github_mirror_pat}" \
  "https://api.github.com/orgs/$GH_USER/repos?per_page=100" | jq -r '.[].name')
for repo in $repos; do
  if ! fj "$API/repos/$ORG/$repo" >/dev/null 2>&1; then
    echo "migrating $repo..."
    fj -X POST "$API/repos/migrate" -d @- >/dev/null <<JSON
{"clone_addr":"https://github.com/$GH_USER/$repo.git","auth_token":"${github_mirror_pat}",
 "repo_owner":"$ORG","repo_name":"$repo","private":true,"service":"github",
 "issues":true,"pull_requests":true,"releases":true,"labels":true,"milestones":true,"wiki":true}
JSON
  fi
  if ! fj "$API/repos/$ORG/$repo/push_mirrors" | jq -e 'length > 0' >/dev/null; then
    echo "adding push mirror for $repo..."
    fj -X POST "$API/repos/$ORG/$repo/push_mirrors" -d @- >/dev/null <<JSON
{"remote_address":"https://github.com/$GH_USER/$repo.git",
 "remote_username":"$GH_USER","remote_password":"${github_mirror_pat}",
 "interval":"8h0m0s","sync_on_commit":true}
JSON
  fi
done

# --- org-level Actions secrets ----------------------------------------------
declare -A secrets=(
  [HARBOR_URL]="${harbor_url}" [HARBOR_USERNAME]="${harbor_username}"
  [HARBOR_PASSWORD]="${harbor_password}"
  [CLOUDFLARE_API_TOKEN]="${cloudflare_api_token}"
  [CLOUDFLARE_ACCOUNT_ID]="${cloudflare_account_id}"
)
for name in "${!secrets[@]}"; do
  fj -X PUT "$API/orgs/$ORG/actions/secrets/$name" -d "{\"data\":\"${secrets[$name]}\"}" >/dev/null
done
echo "actions secrets set"
echo "done"
```
(If the GitHub repos live under a user account instead of the `operinko-labs` org, change the `repos=` line to `https://api.github.com/user/repos?affiliation=owner&per_page=100` — confirm with the user which it is.)

- [ ] **Step 3: Run and verify**

```bash
just forge setup
curl -s -H "Authorization: token $(sops -d --extract '["forgejo_admin_pat"]' forge/secrets.sops.yaml)" "http://192.168.7.30:3000/api/v1/orgs/operinko-labs/repos?limit=50" | jq -r '.[].name'
```
Expected: all repos listed. Then verify one mirror: push a trivial commit to a test repo on Forgejo (or use `POST /repos/{owner}/{repo}/push_mirrors-sync`) and confirm it appears on GitHub within a minute. Re-run `just forge setup` → converges with no new output ("done" only).

- [ ] **Step 4: Commit**

```bash
git add forge/ && git commit -m "feat(forge): org, migration, push mirrors, actions secrets"
```

---

### Task 5: npmplus WireGuard peer, streams, VPS haproxy

**Files:**
- Create: `forge/config/wg0-npmplus.conf.j2`
- Create: `forge/apply-npmplus.sh`
- Modify: `vps/config/wg0.conf.j2` (ListenPort + npmplus peer)
- Modify: `vps/config/haproxy.cfg` (`:22` frontend + SNI rule)
- Modify: `forge/secrets.sops.yaml` (add `npmplus_wg_private_key`)

**Interfaces:**
- Consumes: `NPMPLUS_IP` (Task 0)
- Produces: WG tunnel VPS(172.16.8.2) ⇄ npmplus(172.16.8.20); VPS `:22`→npmplus:22→forge:22; VPS `:443` SNI `forgejo.vaderrp.com`→npmplus:443; internal DNS record.

- [ ] **Step 1: Generate the npmplus WG keypair**

```bash
wg genkey | tee /tmp/npmplus.key | wg pubkey > /tmp/npmplus.pub
sops set forge/secrets.sops.yaml '["npmplus_wg_private_key"]' "\"$(cat /tmp/npmplus.key)\""
cat /tmp/npmplus.pub   # used in Step 2
rm /tmp/npmplus.key
```

- [ ] **Step 2: Add ListenPort + peer to the VPS WG template**

`vps/config/wg0.conf.j2` — add `ListenPort` to `[Interface]` and a new peer block at the end:

```ini
[Interface]
PrivateKey = {{ vps_wg_private_key }}
Address = 172.16.8.2/32
ListenPort = 51820
MTU = 1420
...(existing lines unchanged)

[Peer]
# npmplus LXC (forgejo web + ssh landing point)
PublicKey = <contents of /tmp/npmplus.pub>
AllowedIPs = 172.16.8.20/32
```

- [ ] **Step 3: Add haproxy frontends**

`vps/config/haproxy.cfg` — inside `frontend ft_https`, after the webmail rule (line 31):

```
    # Route forgejo.vaderrp.com to npmplus (TLS terminated there)
    use_backend bk_forgejo_web if { req_ssl_sni -i forgejo.vaderrp.com }
```

After `backend bk_traefik` (line 39):

```
backend bk_forgejo_web
    server npmplus 172.16.8.20:443

# Forgejo git SSH (port 22; VPS admin sshd is on 2222)
frontend ft_forgejo_ssh
    bind :::22
    default_backend bk_forgejo_ssh

backend bk_forgejo_ssh
    server npmplus 172.16.8.20:22
```
(npmplus's own sshd is on 2222; the NPM+ stream owns :22 → forge:22.)

- [ ] **Step 4: Write `forge/config/wg0-npmplus.conf.j2`**

```ini
[Interface]
PrivateKey = {{ npmplus_wg_private_key }}
Address = 172.16.8.20/32
MTU = 1420

[Peer]
# wg-haproxy VPS
PublicKey = zFEcLX+tpfWVbgelxPQz0ljctGTskPTKmxZ7rh308Bg=
AllowedIPs = 172.16.8.2/32
Endpoint = 212.147.241.182:51820
PersistentKeepalive = 25
```
(The VPS public key above is copied from `vps/config/wg0.conf.j2`'s home-side counterpart — verify it is the VPS's own pubkey with `ssh -p 2222 root@212.147.241.182 'wg show wg0 public-key'` and use that output.)

- [ ] **Step 5: Write `forge/apply-npmplus.sh`**

npmplus is **Alpine** (Task 0 discovery: OpenRC, apk, no bash) — POSIX sh:

```sh
#!/bin/sh
# Idempotent WireGuard setup on the npmplus LXC (Alpine: apk + OpenRC).
set -eu
STAGING="$(cd "$(dirname "$0")" && pwd)"
CHANGED=""

apk info -e wireguard-tools >/dev/null 2>&1 || { apk add --no-cache wireguard-tools; CHANGED="$CHANGED packages:wireguard-tools"; }

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
```
If `wg0` creation fails with an operation-not-permitted error (unprivileged LXC), load the module on the host first: `ssh root@meanie.vaderrp.com 'modprobe wireguard'` — then retry the apply.

- [ ] **Step 6: Install SSH key on npmplus and apply everything**

```bash
ssh root@meanie.vaderrp.com "pct exec 107 -- sh -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo \"$(cat ~/.ssh/id_ed25519.pub)\" >> /root/.ssh/authorized_keys'"
ssh root@192.168.0.5 'ping -c1 -W2 192.168.7.30 >/dev/null && echo "inter-VLAN routing OK" || echo "BLOCKED: npmplus cannot reach 192.168.7.30 — check UDM inter-VLAN firewall before continuing"'
just forge apply-npmplus
just vps apply
ssh -p 2222 root@212.147.241.182 'wg show wg0 latest-handshakes && haproxy -c -f /etc/haproxy/haproxy.cfg'
```
Expected: a recent handshake timestamp for the npmplus peer; haproxy config valid. If no handshake, check UpCloud firewall for UDP 51820 (open it in the UpCloud console) — this was flagged in Task 0.

- [ ] **Step 7: NPMplus proxy host + streams**

Already done by the user (2026-08-17): proxy host `forgejo.vaderrp.com` → `http://192.168.7.30:3000` (Certbot cert, online); npmplus sshd moved to **2222**; single NPM+ stream `22` TCP → `192.168.7.30:22` (online). Remaining:
- Update `forge/mod.just` apply-npmplus recipe to use `ssh -p 2222` / `scp -P 2222`.
- If NPMplus runs in Docker, confirm stream port 22 is published (`docker ps` port list); if native, it binds directly.

- [ ] **Step 8: Internal DNS record**

Add A record in Technitium (ns1, `192.168.7.8`, admin UI — or API if the user provides a token): zone `vaderrp.com`, name `forgejo`, value `NPMPLUS_IP`. Verify from WSL:

```bash
nslookup forgejo.vaderrp.com 192.168.7.8
```
Expected: `NPMPLUS_IP`.

- [ ] **Step 9: LAN end-to-end verify**

```bash
curl -s https://forgejo.vaderrp.com/api/v1/version
ssh -T git@forgejo.vaderrp.com 2>&1 | head -2
```
Expected: version JSON with valid TLS; SSH banner reaches Forgejo (permission-denied without a key is fine — the banner proves the stream path).

- [ ] **Step 10: Commit**

```bash
git add forge/ vps/ && git commit -m "feat(forge): npmplus wg peer, vps haproxy frontends for forgejo"
```

---

### Task 6: External DNS and outside-in verification

**Files:**
- None (DNS is in Cloudflare; record the change in `forge/README.md` if anything deviates)

**Interfaces:**
- Consumes: Task 5 complete
- Produces: `forgejo.vaderrp.com` public A record → `212.147.241.182` (unproxied); working external clone.

- [ ] **Step 1: Create the Cloudflare record**

Cloudflare dashboard (or API with `cloudflare_api_token` if it has DNS-edit scope): zone `vaderrp.com`, A record `forgejo` → `212.147.241.182`, **proxy OFF (grey cloud)**.

```bash
nslookup forgejo.vaderrp.com 1.1.1.1
```
Expected: `212.147.241.182`.

- [ ] **Step 2: Verify from outside**

From a network that is not the LAN (e.g. phone hotspot, or ask the user; alternatively verify via the VPS itself which egresses publicly):

```bash
ssh -p 2222 root@212.147.241.182 'curl -s --resolve forgejo.vaderrp.com:443:127.0.0.1 https://forgejo.vaderrp.com/api/v1/version; ssh -o StrictHostKeyChecking=no -p 22 -T git@127.0.0.1 2>&1 | head -2'
```
Expected: version JSON (TLS chain valid) and a Forgejo/OpenSSH banner through haproxy. Then have the user run a real external test when convenient: `git clone git@forgejo.vaderrp.com:operinko-labs/homeops.git`.

- [ ] **Step 3: Web login via Authentik**

User (or claude-in-chrome): open `https://forgejo.vaderrp.com`, click the `authentik` login, confirm SSO completes and a user is auto-provisioned. Add the user's SSH key to their Forgejo account, then:

```bash
git -C /tmp clone git@forgejo.vaderrp.com:operinko-labs/homeops.git homeops-clonetest && rm -rf /tmp/homeops-clonetest
```
Expected: clone succeeds over SSH on the LAN.

---

### Task 7: Runner LXCs with Docker CE

**Files:**
- Create: `forge/apply-runner.sh`
- Create: `forge/config/runner-config.yaml.j2`

**Interfaces:**
- Consumes: Forgejo reachable at `https://forgejo.vaderrp.com` (Tasks 5–6)
- Produces: runners `runner1`/`runner2` online with labels `ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-latest` and `linux-amd64:docker://node:22-bookworm`, Docker CE engine, qemu binfmt for arm64 builds.

- [ ] **Step 1: Provision both LXCs**

```bash
ssh -t root@meanie.vaderrp.com 'export var_hostname=forgejo-runner1 var_cpu=4 var_ram=8192 var_disk=60 var_unprivileged=0 var_forgejo_instance=https://forgejo.vaderrp.com var_forgejo_runner_uuid=skip var_forgejo_runner_token=skip; bash -c "$(curl -fsSL https://github.com/community-scripts/ProxmoxVE/raw/main/ct/forgejo-runner.sh)"'
```
Notes: privileged (`var_unprivileged=0`) with nesting for Docker; `uuid/token=skip` satisfies the script's prompts — our apply script re-registers properly. Repeat for `forgejo-runner2` (VMID 132). Then pin networking + SSH keys for both:

```bash
ssh root@meanie.vaderrp.com 'pct set 131 -net0 name=eth0,bridge=node,ip=192.168.7.31/24,gw=192.168.7.1 -features nesting=1 && pct reboot 131'
ssh root@meanie.vaderrp.com 'pct set 132 -net0 name=eth0,bridge=node,ip=192.168.7.32/24,gw=192.168.7.1 -features nesting=1 && pct reboot 132'
ssh root@meanie.vaderrp.com "pct exec 131 -- bash -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo \"$(cat ~/.ssh/id_ed25519.pub)\" >> /root/.ssh/authorized_keys'"
ssh root@meanie.vaderrp.com "pct exec 132 -- bash -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo \"$(cat ~/.ssh/id_ed25519.pub)\" >> /root/.ssh/authorized_keys'"
```

- [ ] **Step 2: Write `forge/config/runner-config.yaml.j2`**

```yaml
# forgejo-runner config — identical for both runners (name comes from hostname at registration)
log:
  level: info
runner:
  file: /etc/forgejo-runner/.runner
  capacity: 2
  timeout: 3h
  labels:
    - "ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-latest"
    - "linux-amd64:docker://node:22-bookworm"
cache:
  enabled: true
container:
  network: bridge
  docker_host: unix:///var/run/docker.sock
  force_pull: false
```

- [ ] **Step 3: Write `forge/apply-runner.sh`**

```bash
#!/usr/bin/env bash
# Idempotent runner apply: swap podman -> docker-ce, install config, register.
# Registration token is fetched lazily; pass FORGEJO_RUNNER_TOKEN env if re-registering.
set -euo pipefail
STAGING="$(cd "$(dirname "$0")" && pwd)"
CHANGED=()
export DEBIAN_FRONTEND=noninteractive

# --- docker-ce instead of podman --------------------------------------------
if dpkg -s podman &>/dev/null; then
  systemctl disable --now podman.socket podman 2>/dev/null || true
  apt-get remove -y -qq podman podman-docker
  CHANGED+=("removed podman")
fi
if ! dpkg -s docker-ce &>/dev/null; then
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
```

- [ ] **Step 4: Register and apply both runners**

```bash
TOKEN=$(ssh root@192.168.7.30 "su - git -s /bin/bash -c 'forgejo --config /etc/forgejo/app.ini actions generate-runner-token'")
FORGEJO_RUNNER_TOKEN=$TOKEN just forge apply-runner 1
TOKEN=$(ssh root@192.168.7.30 "su - git -s /bin/bash -c 'forgejo --config /etc/forgejo/app.ini actions generate-runner-token'")
FORGEJO_RUNNER_TOKEN=$TOKEN just forge apply-runner 2
```
(`mod.just` already forwards `FORGEJO_RUNNER_TOKEN` — Task 1 Step 3.)

- [ ] **Step 5: Verify runners online**

```bash
curl -s -H "Authorization: token $(sops -d --extract '["forgejo_admin_pat"]' forge/secrets.sops.yaml)" https://forgejo.vaderrp.com/api/v1/admin/runners | jq -r '.[] | "\(.name) online=\(.status)"'
```
Expected: both runners listed as idle/online. Also verify docker works: `ssh root@192.168.7.31 'docker run --rm hello-world | head -2'`.

- [ ] **Step 6: Commit**

```bash
git add forge/ && git commit -m "feat(forge): runner lxc apply with docker-ce"
```

---

### Task 8: Port CI workflows to Forgejo Actions

**Files:**
- Create: `.forgejo/workflows/lint.yaml`
- Create: `.forgejo/workflows/schemas.yaml`
- Create: `.forgejo/workflows/tag.yaml`
- Create: `.forgejo/workflows/build-log-aggregator.yaml`
- Create: `.forgejo/workflows/build-tempest-mcp.yaml`

**Interfaces:**
- Consumes: runners with `ubuntu-latest` label (Task 7); org Actions secrets (Task 4)
- Produces: green CI on Forgejo for lint + builds; `.github/workflows/` left untouched (dies when GitHub Actions is disabled in Task 10).

- [ ] **Step 1: Port `lint.yaml`**

Copy `.github/workflows/lint.yaml` to `.forgejo/workflows/lint.yaml` with exactly two changes: the `paths:` trigger entry `.github/workflows/lint.yaml` becomes `.forgejo/workflows/lint.yaml`, and the shellcheck job installs the tool first (act image has no shellcheck):

```yaml
      - name: Run ShellCheck
        run: |
          sudo apt-get update -qq && sudo apt-get install -y -qq shellcheck
          shopt -s globstar
          shellcheck scripts/**/*.sh
```
All `actions/checkout` etc. references stay pinned as-is (they resolve from GitHub).

- [ ] **Step 2: Port `schemas.yaml`**

Copy to `.forgejo/workflows/schemas.yaml`; change `runs-on: org-runner` → `runs-on: ubuntu-latest` and the `paths:` trigger to `.forgejo/workflows/schemas.yaml`. Everything else unchanged (wrangler + Cloudflare secrets come from org Actions secrets).

- [ ] **Step 3: Rewrite `tag.yaml` without github-script**

`actions/github-script` targets the GitHub API; replace with plain git. Create `.forgejo/workflows/tag.yaml`:

```yaml
---
name: Tag

on:
  workflow_dispatch:
  schedule:
    - cron: "0 0 1 * *"

jobs:
  main:
    name: Tag
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          fetch-depth: 0

      - name: Create CalVer tag
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          prev=$(git tag --sort=-v:refname | head -1)
          prev=${prev:-0.0.0}
          IFS=. read -r pmaj pmin ppatch <<< "$prev"
          next_mm="$(date +%Y).$(date +%-m)"
          if [ "$pmaj.$pmin" = "$next_mm" ]; then patch=$((ppatch + 1)); else patch=0; fi
          tag="$next_mm.$patch"
          echo "tagging $tag (prev $prev)"
          git config user.name "forgejo-actions"
          git config user.email "actions@forgejo.vaderrp.com"
          git tag -a "$tag" -m "$tag"
          git push "https://oauth2:${GH_TOKEN}@forgejo.vaderrp.com/${{ github.repository }}.git" "refs/tags/$tag"
```

- [ ] **Step 4: Port the build workflows**

Copy `.github/workflows/build-log-aggregator.yaml` to `.forgejo/workflows/build-log-aggregator.yaml` with these changes and no others:
- `paths:` trigger `.github/workflows/build-log-aggregator.yaml` → `.forgejo/workflows/build-log-aggregator.yaml`
- Delete the `permissions:` block on the job (GitHub-specific `id-token`/`attestations`)
- Delete the final `Generate artifact attestation` step (GitHub-only attestations API)
- In `Build and push Docker image`, delete the two cache lines (`cache-from: type=gha`, `cache-to: type=gha,mode=max`) — Forgejo's cache server and buildx gha-cache compatibility is unproven; re-add later if desired.

Repeat identically for `build-tempest-mcp.yaml`.

- [ ] **Step 5: Push and verify green**

```bash
git add .forgejo/ && git commit -m "ci: port workflows to forgejo actions"
git remote add forgejo git@forgejo.vaderrp.com:operinko-labs/homeops.git 2>/dev/null || true
git push forgejo main
```
Then watch the runs in the Forgejo UI Actions tab (or `curl -s -H "Authorization: token <admin PAT>" "https://forgejo.vaderrp.com/api/v1/repos/operinko-labs/homeops/actions/tasks" | jq` — field names vary by Forgejo version, the UI is authoritative). Trigger a build by dispatching `Build Log Aggregator` with `force_push=false` from the Forgejo UI (Actions tab) and confirm the buildx multi-arch build completes. Fix any failures before proceeding — lint and one build must be green (spec phase-3 criteria).

Note: this push also proves the push mirror — confirm the commit appears on GitHub.

---

### Task 9: Self-hosted Renovate

**Files:**
- Create: `.forgejo/workflows/renovate.yaml`
- Modify: `.renovaterc.json5` (preset sources `github>` → `local>`)
- Modify: `forge/secrets.sops.yaml` / Forgejo secrets (add `renovate_pat`, `RENOVATE_TOKEN`, `GH_COM_TOKEN`, `HARBOR_ROBOT_PASSWORD` org secrets)

**Interfaces:**
- Consumes: runners (Task 7)
- Produces: scheduled Renovate runs opening PRs on Forgejo across the org.

- [ ] **Step 1: Create the renovate user + PAT, store secrets**

```bash
ssh root@192.168.7.30 "su - git -s /bin/bash -c 'forgejo --config /etc/forgejo/app.ini admin user create --username renovate --random-password --email renovate@vaderrp.com'"
ssh root@192.168.7.30 "su - git -s /bin/bash -c 'forgejo --config /etc/forgejo/app.ini admin user generate-access-token --username renovate --token-name renovate --scopes all --raw'"
sops set forge/secrets.sops.yaml '["renovate_pat"]' '"<token>"'
```
Add the `renovate` user to the `operinko-labs` org with write access (Owners team or a `renovate` team with write): via UI or `curl -X PUT .../api/v1/orgs/operinko-labs/members` equivalent — verify with `curl -s -H "Authorization: token <renovate_pat>" https://forgejo.vaderrp.com/api/v1/orgs | jq -r '.[].username'` → `operinko-labs`.

Then set org Actions secrets: `RENOVATE_TOKEN` = renovate PAT, `GH_COM_TOKEN` = the same existing GitHub PAT already stored as `github_mirror_pat` (user-confirmed broad enough; used here for changelogs/datasources), `HARBOR_ROBOT_PASSWORD` = from `forge/secrets.sops.yaml`. Extend the `declare -A secrets` block in `forge/setup-forgejo.sh` with these three (values from env: `renovate_pat`, `github_mirror_pat`, `harbor_robot_password`) and re-run `just forge setup`.

- [ ] **Step 2: Point preset references at the local platform**

In `.renovaterc.json5` lines 8–14, change every `github>operinko-labs/homeops//...` to `local>operinko-labs/homeops//...` (5 lines). The `.renovate/*.json5` preset files themselves need the same treatment — check: `grep -rn "github>operinko-labs" .renovate/` and change those too.

- [ ] **Step 3: Create `.forgejo/workflows/renovate.yaml`**

```yaml
---
name: Renovate

on:
  workflow_dispatch:
  schedule:
    - cron: "0 */2 * * *"

jobs:
  renovate:
    name: Renovate
    runs-on: ubuntu-latest
    container:
      # renovate: datasource=docker depName=ghcr.io/renovatebot/renovate
      image: ghcr.io/renovatebot/renovate:41.109.2
    steps:
      - name: Run Renovate
        env:
          RENOVATE_PLATFORM: forgejo
          RENOVATE_ENDPOINT: https://forgejo.vaderrp.com/api/v1
          RENOVATE_TOKEN: ${{ secrets.RENOVATE_TOKEN }}
          GITHUB_COM_TOKEN: ${{ secrets.GH_COM_TOKEN }}
          RENOVATE_AUTODISCOVER: "true"
          RENOVATE_GIT_AUTHOR: "Renovate Bot <renovate@vaderrp.com>"
          RENOVATE_SECRETS: '{"HARBOR_ROBOT_PASSWORD":"${{ secrets.HARBOR_ROBOT_PASSWORD }}"}'
          LOG_LEVEL: info
        run: renovate
```
(If the pinned Renovate version rejects `platform: forgejo`, use `RENOVATE_PLATFORM: gitea` — same API surface.)

- [ ] **Step 4: Run and verify**

```bash
git add .forgejo/workflows/renovate.yaml .renovaterc.json5 .renovate/ && git commit -m "ci: self-hosted renovate on forgejo" && git push forgejo main
```
Dispatch the workflow from the Forgejo UI. Expected: the run completes; the Dependency Dashboard issue appears on `operinko-labs/homeops`; at least one Renovate PR opens (there are always pending updates). Spec phase-4 criterion met.

---

### Task 10: Flux cutover

**Files:**
- Modify: `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml:24-30` (sync block)
- Create: `bootstrap/forgejo-deploy-key.sops.yaml` (replaces `bootstrap/github-deploy-key.sops.yaml`)
- Delete: `bootstrap/github-deploy-key.sops.yaml`

**Interfaces:**
- Consumes: Forgejo repo `operinko-labs/homeops` (Task 4), `forgejo_admin_pat`
- Produces: Flux pulling `ssh://git@192.168.7.30/operinko-labs/homeops.git` with a read-only deploy key.

Note: the gpro ResourceSet (`kubernetes/apps/gpro/gpro/app/`) keeps reading `github.com/operinko-labs/gpro` via `gpro-github-pat` — the push mirror keeps that current, so it needs no change in this task.

- [ ] **Step 1: Create a read-only deploy key on the Forgejo repo**

```bash
ssh-keygen -t ed25519 -N '' -C flux-forgejo -f /tmp/flux-forgejo
curl -sf -X POST -H "Authorization: token $(sops -d --extract '["forgejo_admin_pat"]' forge/secrets.sops.yaml)" -H 'Content-Type: application/json' \
  https://forgejo.vaderrp.com/api/v1/repos/operinko-labs/homeops/keys \
  -d "{\"title\":\"flux\",\"key\":\"$(cat /tmp/flux-forgejo.pub)\",\"read_only\":true}"
```

- [ ] **Step 2: Build the new flux-system secret**

```bash
ssh-keyscan -p 22 192.168.7.30 2>/dev/null > /tmp/forge_known_hosts
cat > bootstrap/forgejo-deploy-key.sops.yaml <<EOF
# yaml-language-server: \$schema=https://kubernetesjsonschema.dev/v1.18.1-standalone-strict/secret-v1.json
apiVersion: v1
kind: Secret
metadata:
  name: flux-system
  namespace: flux-system
stringData:
  identity: |
$(sed 's/^/    /' /tmp/flux-forgejo)
  known_hosts: |
$(sed 's/^/    /' /tmp/forge_known_hosts)
EOF
sops encrypt --in-place bootstrap/forgejo-deploy-key.sops.yaml
rm /tmp/flux-forgejo /tmp/flux-forgejo.pub
git rm bootstrap/github-deploy-key.sops.yaml
grep -rn "github-deploy-key" bootstrap/ .taskfiles/ scripts/ 2>/dev/null
```
Update every reference the grep finds to `forgejo-deploy-key` (bootstrap apply scripts/taskfiles reference the file by name).

- [ ] **Step 3: Apply the secret, verify the key can fetch, update the FluxInstance sync**

```bash
sops -d bootstrap/forgejo-deploy-key.sops.yaml | kubectl apply -f -
GIT_SSH_COMMAND="ssh -i <(sops -d bootstrap/forgejo-deploy-key.sops.yaml | yq '.stringData.identity') -o StrictHostKeyChecking=accept-new" git ls-remote ssh://git@192.168.7.30/operinko-labs/homeops.git HEAD
```
Expected: `ls-remote` prints the HEAD ref (deploy key works).

In `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml`, replace the `sync:` block:

```yaml
      sync:
        kind: GitRepository
        name: flux-system
        url: ssh://git@192.168.7.30/operinko-labs/homeops.git
        ref: refs/heads/main
        path: kubernetes/flux/cluster
        interval: 1h
        pullSecret: flux-system
```

- [ ] **Step 4: Commit, push to BOTH remotes, reconcile**

```bash
git add -A && git commit -m "feat(flux): cut over git source to forgejo"
git push origin main && git push forgejo main
flux reconcile hr flux-instance -n flux-system --with-source
flux get sources git -A
```
Expected: `flux-system` GitRepository shows the forgejo URL and `Ready=True` with a fresh revision. If it fails, the GitHub copy is identical — no divergence while debugging.

- [ ] **Step 5: Prove authority with a Forgejo-only commit**

```bash
git commit --allow-empty -m "chore: forgejo cutover probe" && git push forgejo main
flux reconcile source git flux-system -n flux-system
flux get ks -A | head -20
```
Expected: new revision picked up from Forgejo (the mirror also syncs it to GitHub — that's the mirror working, not Flux reading GitHub). All Kustomizations `Ready=True`.

- [ ] **Step 6: Disable GitHub Actions on mirrors, retire hosted Renovate**

```bash
for repo in $(gh repo list operinko-labs --json name -q '.[].name'); do
  gh api -X PUT "repos/operinko-labs/$repo/actions/permissions" -F enabled=false
done
```
Ask the user to uninstall the Mend Renovate GitHub App from the org (Settings → GitHub Apps) — that's UI-only.

- [ ] **Step 7: Commit any remaining changes and update remotes**

Make `forgejo` the default push target locally:

```bash
git remote set-url origin git@forgejo.vaderrp.com:operinko-labs/homeops.git
git remote -v
```
(GitHub stays reachable via the mirror; keep a `github` remote if desired: `git remote add github https://github.com/operinko-labs/homeops.git`.)

---

### Task 11: Backups, docs, final sweep

**Files:**
- Modify: `docs/network-map.md` (meanie subgraph + hardware table)
- Modify: `forge/README.md` (record any deviations discovered during execution)

**Interfaces:**
- Consumes: everything prior
- Produces: PBS coverage for LXCs 130–132; updated network map; verified spec success criteria.

- [ ] **Step 1: PBS backup coverage**

If Task 0 found `all: 1` in the backup job: verify only. Otherwise append the VMIDs on meanie: edit `/etc/pve/jobs.cfg` vmid list to include `130,131,132` (via `ssh root@meanie.vaderrp.com`). Then verify a backup exists after the next scheduled run, or trigger one:

```bash
ssh root@meanie.vaderrp.com 'vzdump 130 --storage <pbs-storage-from-jobs.cfg> --mode snapshot --notes-template "{{guestname}}"'
```
Expected: `Backup job finished successfully`.

- [ ] **Step 2: Update `docs/network-map.md`**

In the meanie subgraph (lines 31–47), add:

```
            M_LXC_130["LXC 130<br/>forgejo · Forgejo<br/>192.168.7.30"]
            M_LXC_131["LXC 131<br/>forgejo-runner1"]
            M_LXC_132["LXC 132<br/>forgejo-runner2"]
```
(Adjust VMIDs/IPs to the values actually used.)

- [ ] **Step 3: Run the spec success-criteria checklist**

Verify each item from the spec's Success criteria section with a command or a recorded earlier verification; list the evidence in the final report:
1. Repos on Forgejo + mirrors (Task 4 Step 3)
2. SSH remotes LAN + internet (Task 6)
3. Web + Authentik OIDC (Task 6 Step 3)
4. CI green (Task 8 Step 5)
5. Renovate PRs (Task 9 Step 4)
6. Flux from Forgejo (Task 10 Step 5)
7. `just forge apply-*` idempotent — re-run all three applies, expect `no changes`
8. PBS coverage (Step 1 above)

- [ ] **Step 4: Final commit**

```bash
git add docs/ forge/ && git commit -m "docs: forgejo migration network map + module notes" && git push forgejo main
```
