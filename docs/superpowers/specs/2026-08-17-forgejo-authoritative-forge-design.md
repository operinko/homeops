# ForgeJo as Authoritative Forge — Design

**Date:** 2026-08-17
**Status:** Approved

## Context

All repos (homeops and other personal projects) currently live on GitHub:
Flux pulls `homeops` from GitHub, CI runs on GitHub Actions (lint, schemas,
two container builds pushing to Harbor, tag automation), and hosted Renovate
(Mend GitHub app) opens dependency PRs.

Goal: self-host ForgeJo on meanie as the **authoritative** forge for all
existing and future repos, with GitHub demoted to a push mirror. Everything
on ForgeJo is private; web login is delegated to Authentik via OIDC; git
remotes are `git@forgejo.vaderrp.com:<org>/<repo>` and work from anywhere.

Decisions made during brainstorming:

- **Scope:** all repos move; new repos are created on ForgeJo first.
- **Flux switches to ForgeJo** as its GitRepository source (not the GitHub
  mirror). Accepted consequence: a meanie outage stalls GitOps — but meanie
  already hosts talos1/4/5, so this is within the accepted blast radius.
- **ForgeJo runs as a native binary in a Debian LXC** (community-scripts
  provisioning), not Docker-in-LXC or a VM.
- **SQLite** database: single-user forge, everything in one data directory,
  PBS snapshot of the LXC is a complete consistent backup.
- **Runners:** two LXCs via the community-scripts `forgejo-runner` script
  (forgejo-runner binary + Podman with docker-compatible socket, jobs run in
  containers, systemd service).
- **Renovate self-hosted** against ForgeJo, run as a scheduled Forgejo
  Actions workflow.
- **Git SSH from anywhere via the wg-haproxy VPS** (TCP :22 passthrough over
  WireGuard). Chosen over git-over-HTTPS-via-cloudflared because SSH keeps
  end-to-end encryption (Cloudflare's tunnel terminates TLS at their edge and
  would see private repo plaintext) and avoids long-lived token sprawl.
- **TLS terminates on the existing npmplus LXC** (like vaultwarden et al.),
  not a new proxy inside the forge LXC. External web traffic reaches npmplus
  through its own WireGuard peer on the VPS.
- **Management approach:** hybrid — one-time LXC provisioning via
  community-scripts, day-2 config declaratively managed by a new `forge/`
  module modeled on `vps/`.

### Rejected alternatives

- **Flux keeps pulling the GitHub mirror:** zero cluster changes and forge
  outages never stall GitOps, but rejected in favor of true single-source
  authority.
- **Git over HTTPS through cloudflared:** no new public TCP surface, but
  Cloudflare sees repo plaintext, git endpoints need an Authentik bypass
  carve-out, and auth degrades to long-lived PATs on every client.
- **Caddy inside the forge LXC for TLS:** self-contained, but duplicates the
  cert/proxy role npmplus already fills; npmplus reuse chosen instead.
- **Full IaC (OpenTofu proxmox provider) for LXC definitions:** most
  reproducible, but introduces a new toolchain + state for three containers
  on a hypervisor layer that has never been IaC-managed.

## Design

### 1. Topology

Three new Debian LXCs on meanie (community-scripts provisioned, static LAN
IPs, added to the existing PBS backup job):

| LXC | Contents |
|---|---|
| `forgejo` | Forgejo binary (systemd), SQLite, built-in SSH on :22, HTTP on :3000 |
| `forgejo-runner1` | forgejo-runner + Podman, systemd service |
| `forgejo-runner2` | identical twin |

Runner labels: the community-scripts default
`linux-amd64:docker://node:22-bookworm` plus
`ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-latest` for
GitHub-style workflow compatibility. Images pull through the Harbor mirror
where applicable.

### 2. Repo layout (`forge/` module)

```
forge/
├── mod.just                  # just forge apply-forgejo / apply-runner1 / apply-runner2 / setup
├── secrets.sops.yaml         # WG private keys, runner tokens, GitHub mirror PAT,
│                             #   OIDC client secret, admin + renovate PATs
├── apply-forgejo.sh          # idempotent apply for the forge LXC
├── apply-runner.sh           # idempotent apply for either runner LXC
├── setup-forgejo.sh          # one-time/idempotent API-level state (see §6)
└── config/
    ├── app.ini.j2            # Forgejo config (secrets injected at render)
    ├── runner-config.yaml.j2 # forgejo-runner config (token/labels injected)
    └── wg0-npmplus.conf.j2   # npmplus LXC WireGuard client config
```

Registered in the root `.justfile` as `mod forge "forge"`. Apply flow copies
the `vps/` pattern: render j2 + SOPS with minijinja, push over SSH to the
LXC, run the apply script remotely, diff-install files, restart only
services whose config changed.

### 3. DNS, TLS, and access paths

`forgejo.vaderrp.com` resolves differently inside and out, but URLs and
remotes are identical everywhere:

- **External DNS:** A record → VPS public IP (212.147.241.182). Unproxied
  (grey-cloud) in Cloudflare — traffic must not go through Cloudflare's
  proxy.
- **Internal DNS:** one Technitium A record, `forgejo.vaderrp.com` →
  npmplus LXC IP. npmplus terminates :443 as usual and proxies to forge
  `:3000`, and uses its native **Streams** feature to pipe `:22` (TCP) →
  forge LXC `:22`. Both ports thus work behind the one internal record;
  the forge LXC's own IP remains a direct-SSH fallback (and is what Flux
  uses, §7).
- **VPS haproxy:** npmplus is the single home-side landing point:
  - New TCP frontend `:22` → npmplus WG IP (`172.16.8.20:22`), which
    streams on to forge `:22`. Passthrough end-to-end; Forgejo's SSH
    serves git only, no shell.
  - Existing `:443` SNI-split frontend gains one rule:
    `forgejo.vaderrp.com` → npmplus WG IP (`172.16.8.20:443`), TLS
    passthrough (npmplus terminates).
- **WireGuard:** one new peer on the VPS `wg0` (public key in
  `vps/config/wg0.conf.j2`; private key in `forge/secrets.sops.yaml`):
  npmplus = `172.16.8.20`, outbound client with keepalive, so no inbound
  ports at home. The forge LXC itself needs no WireGuard.
- **TLS:** npmplus terminates with its existing ACME cert handling and
  proxies to forge `:3000`. End-to-end: client → (TCP passthrough on VPS) →
  npmplus (TLS) → forge over LAN. Cloudflare never sees content.

### 4. Authentication

- Authentik configured as an **OIDC authentication source** in Forgejo;
  Forgejo login redirects to Authentik. Local admin account retained as
  break-glass. Self-registration disabled; all repos + orgs private.
- No forward-auth proxy in front of Forgejo (would break git/API/SSH).
  Internet-exposed surfaces: Forgejo SSH (key auth only) and the web/login
  pages (delegating to Authentik).
- fail2ban on the VPS covers TCP-level abuse; Forgejo-level auth failures
  are logged in the forge LXC (future hardening: ship them to fail2ban or
  crowdsec — out of scope here).

### 5. Mirroring and repo migration

- Each repo migrates GitHub → Forgejo with Forgejo's built-in migrator
  (imports issues, PRs, releases, wiki using a GitHub token).
- Each Forgejo repo gets a **push mirror** to its GitHub counterpart
  (mirror PAT stored in SOPS; "sync on commit" enabled so GitHub lags by
  seconds). GitHub repo visibility stays as-is (homeops is currently
  public; its mirror remains public).
- **GitHub Actions is disabled on every mirrored GitHub repo** so workflows
  don't double-run on mirror pushes.
- New repos: created on Forgejo; `setup-forgejo.sh` (or a documented step)
  creates the GitHub twin + push mirror.

### 6. Forge-level state (`setup-forgejo.sh`)

Idempotent script driving the Forgejo CLI/API with the SOPS-stored admin
PAT: create org(s), configure the Authentik OIDC source, register push
mirrors, create the `renovate` user + PAT, create the Flux deploy key on
homeops, and print/verify runner registration tokens. Anything the API
can't manage is documented in `forge/README.md`.

### 7. CI, Renovate, Flux cutover

- **CI:** `.github/workflows/{lint,schemas,tag,build-log-aggregator,build-tempest-mcp}.yaml`
  port to `.forgejo/workflows/` (Forgejo Actions is GH-Actions-compatible;
  actions resolve via code.forgejo.org/GitHub). Builds keep pushing to
  Harbor. GitHub-specific automation (labeler, label-sync) is dropped in
  phase one.
- **Renovate:** scheduled Forgejo Actions workflow (cron) in homeops running
  the official Renovate container with `platform=forgejo`, the `renovate`
  user's PAT, autodiscover across the org, plus a read-only github.com token
  for changelogs. Existing `.renovaterc.json5` presets carry over. The Mend
  GitHub app is uninstalled after cutover.
- **Flux:** the `flux-system` GitRepository URL changes to
  `ssh://git@<forge-LXC-LAN-IP>/<org>/homeops.git` with a new Forgejo deploy
  key (read-only). The LAN IP (not the hostname) is used so in-cluster
  resolution never depends on split-DNS behavior of `vaderrp.com` inside the
  cluster (k8s_gateway) nor on the VPS path. `bootstrap/` is updated the
  same way (`github-deploy-key.sops.yaml` → `forgejo-deploy-key.sops.yaml`
  + helmfile references) so a from-scratch bootstrap pulls from Forgejo.
  Webhook-triggered reconciliation (Flux Receiver) is a possible follow-up;
  interval polling is fine initially.

### 8. Failure modes

- **Forge LXC down:** Flux stalls at last-applied state (cluster keeps
  running); pushes fail. Recovery: PBS restore of one LXC.
- **Meanie down:** forge + talos1/4/5 down — pre-existing accepted blast
  radius. All repos remain readable on GitHub mirrors.
- **VPS down:** external SSH/web unavailable; LAN access and Flux
  (LAN-direct) unaffected.
- **npmplus down:** web UI and all `forgejo.vaderrp.com` SSH (external and
  internal) unreachable, since npmplus is the landing point for both.
  Direct forge-LXC-IP SSH on the LAN still works, and Flux (pinned to the
  forge LAN IP) is unaffected.
- **One runner down:** the other picks up queued jobs.

### 9. Phasing

1. **Forge up:** LXC + `forge/` module apply + OIDC + org + repo migration +
   push mirrors. ✓ Login via Authentik; a push to Forgejo appears on GitHub
   within a minute.
2. **Remote access:** npmplus WG peer + streams + VPS haproxy frontends +
   external DNS.
   ✓ `git clone git@forgejo.vaderrp.com:<org>/homeops.git` works from
   outside the LAN; web UI loads externally with a valid cert.
3. **Runners + CI:** two runner LXCs + workflow ports. ✓ lint and one
   container build green on Forgejo Actions.
4. **Renovate:** scheduled workflow. ✓ a real dependency-update PR opens on
   Forgejo.
5. **Flux cutover:** GitRepository + deploy key + bootstrap updates, GitHub
   Actions disabled on mirrors, Mend app uninstalled. ✓ `flux get ks -A`
   clean after a test commit pushed only to Forgejo.

## Success criteria

1. All repos live on Forgejo (private, org-owned), each push-mirrored to
   GitHub with sync-on-commit.
2. `git@forgejo.vaderrp.com` remotes work identically from LAN and internet.
3. Web UI reachable internally and externally, TLS via npmplus, login via
   Authentik OIDC only (plus break-glass admin).
4. CI (lint, schemas, both image builds, tag) green on Forgejo Actions
   across two runners.
5. Renovate opens PRs on Forgejo on schedule.
6. Flux reconciles from Forgejo over LAN; from-scratch bootstrap documented
   against Forgejo.
7. `just forge apply-*` converges idempotently; no secrets outside SOPS.
8. All three LXCs in the PBS backup job.

## Non-goals

- IaC-managed LXC provisioning (community-scripts + PBS restore is the
  reproducibility story).
- Forge HA or read replicas.
- cloudflared/public-proxy exposure of the forge.
- Porting GitHub labeler/label-sync automation.
- fail2ban/crowdsec integration for Forgejo auth logs (noted as future
  hardening).
