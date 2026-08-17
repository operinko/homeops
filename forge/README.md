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
