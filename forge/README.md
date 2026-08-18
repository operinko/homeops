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

## Execution notes / deviations

Operational facts learned while building this module that aren't obvious from the code:

- **The Forgejo migrate API is synchronous and slow.** `POST /repos/migrate` blocks
  server-side for the full clone/import (issues, PRs, releases, wiki) and does not
  return until it's done. The `homeops` repo (~1700 issues) took roughly 50 minutes;
  a client-side timeout below ~2h will chop the connection mid-migration and can
  leave a half-imported repo. `setup-forgejo.sh`'s migrate call uses a long
  `--max-time`; never shorten it below 7200s.
- **npmplus (LXC 107, not 113 — see `docs/network-map.md`) is Alpine, not Debian.**
  It runs NPM+ in Docker with host networking; nginx binds `:80`/`:81`/`:443`
  directly, and the LXC's own OpenRC sshd listens on **:2222** (not :22), so both
  LAN and VPS SSH traffic to npmplus itself use `-p 2222`. Port 22 on npmplus's IP
  is reserved for the Forgejo git-SSH stream forward.
- **The proxy-path SSH is git-only.** Forgejo rides the forge LXC's system sshd; a
  `Match Address 192.168.0.5` block restricts logins arriving via the npmplus proxy
  path to the `git` user. Root SSH to the forge LXC only works direct to its LAN IP
  (192.168.7.30) or via a VPS→LAN jump, never through the npmplus-forwarded path.
- **Runner registration tokens are single-use.** Generate one fresh per runner
  immediately before the apply that consumes it; never reuse or cache one.
- **Staged community-scripts provisioning lives on meanie, not in git.**
  `/root/forgejo/` on meanie holds the mirror-rewritten `install.func` (points at
  `git.community-scripts.org` instead of `raw.githubusercontent.com`, which is
  flaky/rate-limited from meanie), a patched `build.func`
  (`FUNCTIONS_FILE_PATH="$(cat /root/forgejo/install.func)"`), seeded ASCII-art
  header caches, and the `run-forgejo.sh` / `run-runner.sh <1|2>` /
  `repair-runner-install.sh` wrappers. Unattended runs of these community scripts
  also need `mode=default` (skips the whiptail menu — otherwise it needs a TTY),
  `TERM` set to a real value (otherwise `clear` inside `header_info()` aborts the
  run with "TERM environment variable not set"), and — for the runner script
  specifically — a non-empty `var_runner_labels` exported (the install script only
  guards the forgejo-instance/uuid/token vars for unattended runs, not this one; an
  empty value hits an interactive `read` with no tty and fails). None of this
  staging is reproducible from git alone — if `/root/forgejo/` on meanie is ever
  cleaned, these fixes need to be re-derived before re-provisioning a LXC.
- **Runner jobs get the host's Docker socket.** `container.docker_host` is
  `unix:///var/run/docker.sock` (docker-outside-of-docker), which the buildx-based
  CI workflows need. This means a workflow running on a runner is effectively root
  on that runner's LXC. Accepted for this single-tenant homelab; would not be safe
  for untrusted PRs.
- **Renovate can't resolve its own container image through the Harbor proxy.** The
  `ghcr.io/renovatebot/renovate` self-lookup (via the `registryAliases` remap to
  `harbor.vaderrp.com/ghcr`) returns `no-result` rather than a version list, so
  Renovate silently skips proposing updates for its own pin. Non-blocking (a WARN,
  not a failure) — everything else resolves normally; that one line needs an
  occasional manual bump.
