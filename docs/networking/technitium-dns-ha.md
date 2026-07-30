# Technitium DNS HA — move ns1 out of the cluster, make the primary sort first, add a VIP

Status: **DNS migration complete; repo cleanup outstanding**

Three changes:

1. **Move `ns1` from an in-cluster pod to an LXC on `meanie`** — the substantive change. **Done.**
2. **Make the cluster primary the node named `ns1`**, so the admin UI opens editable (§2).
   **Done.**
3. **Add a Keepalived VIP (`192.168.7.7`)** so the UDM hands out one DNS address. Optional,
   not built.

### Current state

| Node | Host | IP | Name | Cluster role |
|---|---|---|---|---|
| new | `meanie` LXC | `192.168.7.8` | `ns1.dns.vaderrp.com` | **primary** (RFC2136 target) |
| existing | NUC, LXC 100 | `192.168.7.9` | `ns2.dns.vaderrp.com` | secondary |
| old | in-cluster pod | — | — | suspended, removed from cluster |

DNS now runs entirely outside Kubernetes on two LXCs on separate physical hosts, so the cold-start
circularity in §1.1 and the ipvlan latency bug in §1.2 are both resolved. What remains is Phase 6
— tearing the in-cluster app out of the repo — plus the decisions in §4 and the optional VIP.

Two alternative approaches to the naming were considered and not taken; they are recorded in §7
in case the question ever reopens.

## 1. Why move ns1 out of the cluster

### 1.1 DNS currently depends on the cluster it is needed to boot

Every registry mirror in `talos/machineconfig.yaml.j2:184-223` points **only** at
`harbor.vaderrp.com`, with `overridePath: true` and no upstream fallback. So a cold cluster
start must resolve `harbor.vaderrp.com` before it can pull any image — while half the DNS
capacity (`ns1`) is a pod inside the cluster being started. Today only `ns2` breaks that loop.

Moving `ns1` out makes DNS wholly independent of Kubernetes, which is the correct layering
regardless of anything else in this document.

### 1.2 ipvlan master isolation

`ns1`'s `net1` is an ipvlan L2 slave of the Talos node's default-route interface, and
[ipvlan slaves cannot reach their master](https://www.cni.dev/plugins/current/main/ipvlan/).

> The Talos node hosting the `ns1` pod cannot reach `192.168.7.8` from its host netns — today,
> already.

`machine.network.nameservers` lists `.8` first, so on that one node every host-level lookup
pays a full timeout before falling back to `.9`. This is a live latency bug, not a
hypothetical.

### 1.3 Churn and complexity

`ns1` uses `strategy: Recreate` with a `local-path` PVC, so every Renovate image bump, chart
bump or node drain takes a nameserver down. In an LXC, none of that touches DNS.

Moving to an LXC also deletes the entire set of workarounds a VIP would otherwise need
in-cluster: no unicast-VRRP workaround for ipvlan's unreliable multicast, no `NET_ADMIN`
sidecar, no PSA exception, no ConfigMap-mounted `keepalived.conf`. It reduces to
`apt install keepalived` on two ordinary hosts.

### 1.4 Where

**`meanie`** (HP DL360, Proxmox). It is a real Proxmox host so LXC is native, and it is a
different physical machine from the NUC, which is what buys the redundancy.

Not TrueNAS: it is not Proxmox (containers there mean Incus "Instances"), it is the storage
backbone so it reboots for updates, and it already carries talos3/6/7.

### 1.5 Not Proxmox HA

Tempting, but wrong for this workload:

- **It would co-locate the failure domains.** HA can only relocate between the NUC and
  `meanie`. `ns2` is on the NUC — so if `meanie` dies, HA moves `ns1` onto the NUC and both
  nameservers end up on one machine, exactly when you need them apart. Preventing that with an
  affinity rule leaves HA with nowhere to go.
- **Wrong failure mode.** HA reacts to *node* death. It does nothing when Technitium
  crash-loops inside a healthy container. A Keepalived `vrrp_script` running `dig` catches
  precisely that case.
- **Too slow.** Watchdog fencing plus a cold container start is a minute or two. VRRP is
  ~3 seconds.

(`pvesr` replication *is* available — both hosts run ZFS — so storage is not the blocker. The
first two reasons are.)

The general rule: Proxmox HA is for stateful singletons that cannot be run twice. DNS is the
opposite — trivially replicated, and Technitium clustering already syncs the config. Run two
independent LXCs pinned to different hosts, no HA, no replication, and back both up to PBS.

## 2. Why the primary must be named `ns1`

Not cosmetic. The Technitium admin UI picks the active node in the server dropdown
**alphabetically**, so `ns1` is selected by default. If `ns1` is a secondary, the Zones tab
opens read-only — and once you are inside a zone the dropdown cannot be changed without
backing out first. Every zone edit becomes "remember to switch nodes, or waste a click and
lose your place."

So the node that is *primary* has to be the node that sorts *first*. `ns1` was already the
`meanie` LXC at `.8`, so the fix was to make that node the primary — done by promotion in
Phase 4.

### 2.1 What promotion actually does

The "Promote To Primary" confirmation is explicit, and it is not a graceful demotion:

> The promote To Primary node process will resync complete configuration from the Primary node
> and then proceed to **delete it from the Cluster** followed by upgrading the selected
> Secondary node to become the Primary node in the Cluster. The former Primary node when
> deleted will cause it to **delete all its own Cluster configuration leaving the Cluster**
> without causing any other data loss.

So promoting `ns1` will:

1. Resync the complete configuration **from** the NUC (current primary) **to** `ns1`.
2. Delete the NUC from the cluster, informing it.
3. Upgrade `ns1` to primary.
4. Leave the NUC as a **standalone** server — it wipes its own cluster configuration but keeps
   its zone data and keeps answering DNS on `.9`.

By that reading the NUC then has to be **rejoined as a secondary**. In practice the cluster came
out of promotion with both nodes present — see the note in Phase 4.

Two operational points:

- **Do not tick "Force Delete Current Primary Node."** That skips the resync and does not inform
  the old primary. It exists for a primary that is unreachable or already decommissioned, which
  is not the case here — the NUC is healthy and holds the authoritative configuration.
- **The window between promotion and rejoin is where records can be lost.** During it the NUC
  is standalone but still reachable at `.9`, so anything still writing there — notably
  external-dns via RFC2136 — lands changes on a node whose data is replaced when it rejoins.
  Park external-dns across the switch to remove the question.

## 3. Migration plan

### Phases 0–2 — build and join *(done)*

- [x] **Cluster primary confirmed: the NUC.** The Promote To Primary dialog offers to promote
      `ns1.dns.vaderrp.com`, and promotion is only offered for secondaries.
- [x] Debian 13 LXC built on `meanie`, on ZFS. Installed Technitium from upstream rather than
      through Harbor, so the box does not depend on the cluster it serves.
- [x] Joined the cluster as **`ns1.dns.vaderrp.com`**, secondary, holding `192.168.7.8`.
      Because the pod had already been removed from the cluster, the name `ns1` and the address
      `.8` were both free — no temporary `ns3` staging name was needed after all.
- [x] Verified live: ~3.7k queries/hour across 28 clients, ~40% authoritative and ~9% blocked,
      which confirms zones *and* allow/block lists replicated rather than merely connecting.

Notes worth keeping for the next time a node is built:

- The node name is the **DNS Server Domain Name**, and must be a subdomain of the immutable
  cluster domain (`dns.vaderrp.com`). See §5.
- Read the resulting name back in the UI —
  [issue #1508](https://github.com/TechnitiumSoftware/DnsServer/issues/1508) reports names being
  *concatenated* rather than replaced in some subdomain/cluster-domain combinations.
- Back the LXC up to PBS. This replaces the VolSync/kopia job removed in Phase 6 and is a
  better fit — whole-container backups instead of a PVC snapshot.

### Phase 3 — decommission the pod *(done)*

- [x] Suspended the Flux Kustomization and scaled the HelmRelease to zero. **Suspended, not
      deleted** — see the Phase 6 warning.
- [x] Removed the old `ns1` node from the Technitium cluster.

Rollback during the soak period is un-suspending the Kustomization — though note that the name
`ns1` is now taken by `meanie`, so the pod would need a different one.

### Phase 4 — promote `ns1` *(done)*

- [x] Promoted `ns1`, with "Force Delete Current Primary Node" left unticked (§2.1).
- [x] Merged [#1634](https://github.com/operinko-labs/homeops/pull/1634) — `--rfc2136-host`
      `.9` → `.8`, plus the CoreDNS forward cleanup.

Resulting cluster state, from Administration → Cluster:

| Node Name | IP | Type | State |
|---|---|---|---|
| `ns1.dns.vaderrp.com` | `192.168.7.8` | **Primary** | Connected |
| `ns2.dns.vaderrp.com` | `192.168.7.9` | Secondary | Self |

**The cluster came out of promotion with both nodes present.** The dialog text (§2.1) says the
former primary is deleted from the cluster and wipes its own cluster configuration, which
implies a manual rejoin — that is not what the end state shows. Either the rejoin happened
automatically or it was performed immediately after promoting; §2.1 is written from the dialog's
wording rather than from observed behaviour, so treat the "requires a rejoin" claim as unverified
rather than disproven.

Remaining verification:

- [ ] Confirm a dynamic update actually lands now that `.8` is writable — touch an HTTPRoute and
      check the record appears on `ns1` and replicates to `ns2`. This is the real test that
      merging #1634 was correct.
- [ ] If external-dns was parked across the switch, un-park it:
      `flux resume hr internal-dns cluster-dns -n network`
- [ ] Confirm the Zones tab opens **editable** by default — the point of the whole exercise.
- [ ] Spot-check a zone's SOA MNAME. Clustering manages NS/SOA across zones, so this should need
      no hand-editing.

#### Ordering hazard, for the record

`#1634` repointed RFC2136 at `.8` while `ns1` was still a secondary. Technitium refuses dynamic
updates on a secondary, so record publication was stalled between that reconcile and the
promotion. It is self-healing — external-dns re-reconciles once the target is writable — but the
correct order is **promote first, then merge**, or park external-dns across both.

### Phase 5 — Talos nameservers

- [ ] `machine.network.nameservers` is `[192.168.7.8, 192.168.7.9]` and both are now live LXCs
      on separate hosts, so the §1.2 latency bug is already resolved by the migration itself —
      `.8` is no longer an ipvlan address unreachable from its own node. No change is required.
      Revisit only if the VIP is built (§6.3).

### Phase 6 — repo cleanup

> **Order matters.** `technitium/ks.yaml` has `prune: true`, so deleting it takes the PVC and
> the VolSync `ReplicationSource` with it. Export the PVC first
> (`just kube browse-pvc network technitium`) and keep a copy until the LXC has a verified PBS
> backup — even though Phase 2 means you should not need it.

- [x] ~~Change `--rfc2136-host` and clean up the CoreDNS forward list.~~ Prepared in
      [#1634](https://github.com/operinko-labs/homeops/pull/1634); merge during Phase 4.
- [ ] Delete `kubernetes/apps/network/technitium/` (HelmRelease, OCIRepository, NAD,
      Certificate, HTTPRoutes, secret, ks).
- [ ] Drop `./technitium/ks.yaml` from `kubernetes/apps/network/kustomization.yaml:12`.
- [ ] Delete the stale root `manifest.yaml` — an accidentally-committed rendered dump of the
      *old* Technitium Service (image `14.3.0`, the pre-ipvlan `io.cilium/lb-ipam-ips`
      annotation). It is dead weight and actively misleading.
- [ ] Re-point the Homepage widgets from `http://technitium.network.svc.cluster.local:5380` to
      the LXCs (§4.3).
- [ ] Re-point the `.8` resolver references, which now mean a different box than when they were
      written: `observability/gatus/app/storj-configmap.yaml:35`,
      `media/prowlarr/app/httproute.yaml:16`, `media/maintainerr/app/httproute.yaml:16`.
      Prefer `.7` if the VIP exists.
- [ ] Add both LXCs to `docs/network-map.md` and remove `K_TECHNITIUM` from the in-cluster
      network subgraph.
- [ ] Fix the stale `192.168.7.7` references in `docs/networking/dual-gateway-external-dns.md`
      (lines 23, 31) — now correct by accident; make them deliberate.

## 4. Things that break and need a decision

### 4.1 TLS — Technitium terminates, not a proxy

**Decided: an ACME client on each LXC, Technitium terminating its own TLS.** Fronting it with
npmplus was tempting but does not survive contact with encrypted DNS.

A TLS-terminating proxy only works for the protocols nginx can actually speak:

| Protocol | Proxyable via npmplus? |
|---|---|
| Web UI (HTTPS) | yes |
| DoH (`:443` HTTPS) | yes — Technitium supports plain **DNS-over-HTTP** behind a TLS-terminating proxy, gated by the Reverse Proxy Network ACL |
| DoH3 (HTTP/3) | in principle, if the proxy does HTTP/3 |
| DoT (`:853` TCP+TLS) | only via an nginx `stream` block doing TLS termination — not something the NPM UI exposes |
| **DoQ (`:853` UDP, QUIC)** | **no.** nginx cannot terminate QUIC and re-emit DNS |

So the moment DoT/DoQ are wanted, Technitium needs its own certificate — and once it has one,
it serves the web UI over HTTPS itself and the proxy stops earning its keep. That collapses
§4.3 as well.

Practical notes:

- **Format is still PKCS#12.** Technitium takes a `.pfx` path plus a password; PEM must be
  converted. Reuse the exact `openssl pkcs12 -export -legacy -keypbe PBE-SHA1-3DES -certpbe
  PBE-SHA1-3DES -macalg sha1` invocation from the old initContainer
  (`app/helmrelease.yaml:31-38`) — it is known to produce a bundle Technitium accepts.
- **Renewal needs no restart or API call.** Technitium reloads the certificate automatically
  when the `.pfx` file's modified timestamp changes. A deploy/renewal hook that rewrites the
  file is the whole integration.
- **Validation must go through Cloudflare**, not the internal zone. Let's Encrypt checks the
  *public* authoritative DNS for `vaderrp.com`, so use the acme client's Cloudflare DNS-01
  plugin — mirroring what the cert-manager ClusterIssuer was already doing.
- **SAN set.** Clients validate the name they connect to, so every name any client might use
  has to be present:

  | SAN | Covers |
  |---|---|
  | `technitium.vaderrp.com` | the VIP (§6) and the web UI |
  | `*.dns.vaderrp.com` | `ns1`, `ns2`, and every future `ns#` without reissuing |
  | `dns.vaderrp.com` | the bare name — a wildcard does **not** match it |

  Prefer the wildcard over enumerating `ns1`/`ns2` — adding a third node then never requires
  touching the other two.

  > **The wildcard forces DNS-01.** Let's Encrypt will not issue a wildcard via HTTP-01, ever.
  > npmplus proxy-host configs carry a `/.well-known/acme-challenge/` location by default, so
  > confirm the certificate is actually configured for the **Cloudflare DNS challenge** rather
  > than HTTP. If it is on HTTP-01, `*.dns.vaderrp.com` will silently fail to issue and only the
  > two literal names will come back.

  HTTP-01 would be a poor fit here anyway: it needs Let's Encrypt to reach these names on `:80`
  from the public internet, which is the same objection as §"Why not Technitium's built-in
  renewal".

- **`technitium.vaderrp.com` is currently taken.** It is an HTTPRoute hostname in the app being
  deleted (`app/httproute.yaml`), published by `internal-dns` and pointing at the
  `gateway-internal` VIP `192.168.7.4`. Deleting the app in Phase 6 withdraws that record;
  the name then needs a static A record to the keepalived VIP `192.168.7.7`. Until the VIP
  exists, point it at `.8`.
- **Same path and password on both nodes.** Clustering syncs settings, including the certificate
  path and password, so both nodes must find a valid bundle at the same path. With one cert
  distributed to both, the contents match too. Keep the old pod's empty password
  (`-passout pass:`) so the synced setting is trivially valid everywhere.

#### Why not Technitium's built-in renewal

The Optional Protocols panel notes that enabling DNS-over-HTTP "also allows automatic TLS
certificate renewal with HTTP challenge (webroot) ... when DNS-over-HTTP port is set to 80".
That is an **HTTP-01** challenge, which requires Let's Encrypt to reach `http://<name>/` from
the public internet. These are LAN-only names on `192.168.7.0/24`, so using it would mean
publishing A records to the WAN address and forwarding `:80` to a DNS server — a poor trade for
avoiding a small shell script. DNS-01 via Cloudflare keeps the nodes unexposed.

#### Not cert-manager

The obvious thought — cert-manager already issues this exact name — is the wrong one. It runs
*in the cluster*, and re-coupling DNS TLS to the cluster reintroduces the dependency §1.1 exists
to remove. Any issuer used here has to live outside Kubernetes.

#### One issuer, distributed — npmplus as the cert source

**Decided: npmplus (LXC 113) is the single ACME client**, issuing one certificate with the three
SANs above, which the Technitium nodes consume.

The alternative — certbot on every node — needs no distribution step, but puts a Cloudflare API
token with `Zone:DNS:Edit` on `vaderrp.com` onto each DNS server. Two or three copies of a
credential that can rewrite the public zone is worse than one, and it gets worse with each node
added. Consolidating is the right call. npmplus is a reasonable home because it already runs an
ACME client and it is not in the cluster.

**Have the nodes pull; do not have npmplus push.** A push means npmplus holds an SSH credential
that can write `/etc/dns/ssl.pfx` on every DNS server — effectively root-equivalent on the whole
DNS tier, held by the most network-exposed component in the chain. Inverting it costs nothing
and reverses the blast radius: each node holds a **read-only** credential to fetch one file, and
a compromised npmplus can no longer write anything to a DNS server.

Confirmed: **npmplus does not surface renewal hooks.** That turns out not to matter — the pull
model never needed one, and nothing inside the container has to be touched.

npmplus runs as a Docker container in an LXC with `- "/opt/npmplus:/data"`, so the certificate
the container writes to `/data/tls/certbot/live/npm-15/` is visible on the **LXC filesystem** at
`/opt/npmplus/tls/certbot/live/npm-15/`. The sync is wired entirely in the LXC, against a
bind-mounted directory, which means a container image update cannot break it. certbot inside
npmplus re-checks renewal every few hours on its own schedule (`CRT`, default 3h); the nodes just
notice when the file changes.

Two path details matter:

- The `live/` entries are **symlinks** into `../../archive/npm-15/`. Plain `rsync -a` preserves
  symlinks, so the nodes would receive two dangling links to a directory that does not exist
  locally. Use `-L`.
- Because of those symlinks, scope the read-only forced command to
  **`/opt/npmplus/tls/certbot`**, not to `live/npm-15` — the targets live in a sibling directory,
  and a restriction rooted at `live/npm-15` puts them outside it.

On npmplus, in the sync key's `authorized_keys`:

```
command="rrsync -ro /opt/npmplus/tls/certbot",restrict ssh-ed25519 AAAA...
```

`privkey.pem` is root-owned `0600`, so this has to be root's `authorized_keys` — but `rrsync -ro`
confines that key to read-only access under one directory, which is the point.

Then on each node, a systemd timer that fetches, checks, and converts locally:

```sh
#!/bin/sh
set -eu
SRC=root@npmplus:live/npm-15                # path is relative to the rrsync root
OUT=/etc/dns/ssl.pfx
WORK=/var/lib/technitium-cert

# -L is required: the live/ entries are symlinks into ../../archive/
rsync -aL --delete "$SRC/" "$WORK/new/"

# Only touch the bundle when the source actually changed — Technitium reloads on
# mtime, so rewriting an identical file causes a pointless reload every timer tick.
if cmp -s "$WORK/new/fullchain.pem" "$WORK/current/fullchain.pem" 2>/dev/null; then
  exit 0
fi

openssl pkcs12 -export -legacy \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -inkey "$WORK/new/privkey.pem" \
  -in    "$WORK/new/fullchain.pem" \
  -out   "$OUT.tmp" -passout pass:

chmod 0600 "$OUT.tmp"
mv "$OUT.tmp" "$OUT"        # atomic; also bumps mtime, which triggers the reload
rm -rf "$WORK/current" && mv "$WORK/new" "$WORK/current"
```

Three things that are not optional:

- **Atomic write.** Technitium watches the bundle's modified timestamp, so writing in place
  risks it reading a half-written file. Build under `.tmp` and rename.
- **Change detection.** Unlike a certbot deploy hook — which only fires on real renewal — a
  timer runs regardless. Without the `cmp`, every tick rewrites the bundle and triggers a
  needless certificate reload.
- **Expiry monitoring.** This is the one that actually matters. A per-node certbot failure is
  local and visible; a distribution failure is *silent for up to 90 days*. Add a Gatus check on
  the certificate expiry of `:853` on **each node** — Gatus is already running, and this is
  exactly the failure it should catch.

**npmplus and `ns1` are both on `meanie`.** Losing that host takes out the cert source and one
DNS node together. Not urgent — there is a 90-day window and `ns2` keeps serving — but it is a
coupling worth knowing about, and an argument for the Gatus check watching `ns2` specifically.

#### The proxy host, and which name resolves where

A proxy host exists on npmplus for all three names, forwarding to `192.168.7.7:53443` —
Technitium's web-service HTTPS port. That is workable but forces a choice, because **a name has
one A record and cannot both terminate at npmplus and terminate at Technitium**:

- `technitium.vaderrp.com` → **npmplus**: the admin UI gets HTTP/3, CrowdSec AppSec and whatever
  auth npmplus applies. But `:853` DoT/DoQ under that name will not work, since npmplus does not
  listen there. DoT/DoQ then have to use `dns.vaderrp.com` or the per-node names.
- `technitium.vaderrp.com` → **the VIP**: Technitium serves the UI itself on `53443` with the
  distributed certificate, and the same name works for DoT/DoQ. The proxy host becomes dead
  config and should be removed.

The second is what §4.1 assumed. The first is a legitimate reason to keep npmplus in the picture
*for the admin UI only* — WAF and SSO in front of a DNS control panel is not a silly thing to
want. Either way the one certificate covers all three names; only the A records differ.

Two smaller notes on that config:

- The upstream is `192.168.7.7`, which **does not exist yet** — the VIP is unbuilt. Point it at
  `.8` until it does.
- `proxy_pass https://...` without `proxy_ssl_verify on` means npmplus does not validate
  Technitium's certificate. Harmless on a trusted segment, but it does mean the upstream leg is
  encrypted-but-unauthenticated.

Open `853/tcp` (DoT), `853/udp` (DoQ), `443/tcp` (DoH) and `443/udp` (DoH3) on both LXCs.

### 4.2 Reverse Proxy Network ACL — needs narrowing

Current value:

```
192.168.0.0/16
10.0.0.0/8
172.16.0.0/12
```

That is all of RFC1918 — i.e. every host on the LAN is trusted as a reverse proxy. Two options
are gated by this ACL, and one of them is meaningfully weakened by it.

**`Enable EDNS Client Subnet (ECS) Source Address` — this is the problem.** The option tells
Technitium to take the client's address from the ECS option in the query rather than from the
packet's actual source, and the ACL is what decides whose claim to believe. With the whole LAN
in the ACL, **any host on the network can present an arbitrary ECS address and have Technitium
believe it.** That makes per-client allow/block rules bypassable by any client that wants to
bypass them, and per-client stats reflect whatever clients assert rather than who they are.

That matters more here than it would elsewhere: preserving real client IPs was the explicit
reason for rejecting the `dnsdist` director pair in §7. An ACL this wide gives away the same
property, quietly.

**`Enable DNS-over-HTTP`** is less severe — it accepts plain-HTTP DNS from the LAN, which is
not much beyond what port 53 already offers the LAN. But with Technitium now terminating DoH
and DoH/3 itself, it has no remaining consumer.

Recommended:

- Turn **ECS Source Address off** unless something genuinely fronts the server. Nothing does
  today — the pod that sat behind the cluster gateways is gone.
- Turn **DNS-over-HTTP off** for the same reason. Note this also removes the built-in HTTP-01
  renewal path, which is not being used anyway.
- If either is ever needed again, set the ACL to the **exact address** of the proxy, never a
  range. The ACL is an identity assertion, not a firewall rule.

### 4.3 Web UI routing — resolved by 4.1

Superseded. With Technitium holding its own certificate it serves the admin UI over HTTPS
directly, so there is no proxy to configure and no selector-less Service plus hand-maintained
EndpointSlice to reach an LXC through Gateway API. Drop the two HTTPRoutes in Phase 6 and reach
the UI at `technitium.vaderrp.com` — the same name the VIP will carry, which is why it is in the
SAN set.

### 4.4 Backups

VolSync/kopia drops off with the ks. PBS covers the LXC and is a better fit — whole-container
backups instead of a PVC snapshot.

## 5. Renaming a Technitium node — mechanics

A node's name **is** its "DNS Server Domain Name" (Settings → General). Per the
[clustering docs](https://blog.technitium.com/2025/11/understanding-clustering-and-how-to.html)
it is changeable after joining a cluster and "automatically updates in the cluster primary
zone".

Constraints:

- **The name must remain a subdomain of the Cluster Domain**, and the Cluster Domain cannot be
  changed after initialization without deleting and reinitializing the cluster. Moving between
  `ns1.dns.vaderrp.com`, `ns2.dns.vaderrp.com` and `ns3.dns.vaderrp.com` is all within
  `dns.vaderrp.com`, so nothing here is blocked.
- **Two nodes cannot hold the same name.** The `meanie` LXC could only take `ns1` because the
  pod had already been removed from the cluster. Had the pod still been a member, a temporary
  third name (`ns3.dns.vaderrp.com`) would have been needed to join and sync before the
  handover.
- **On cluster init, node names are rewritten** as subdomains of the cluster domain — `ns1` or
  `ns1.mydomain.tld` becomes `ns1.mycluster.tld`. Combined with issue #1508's concatenation
  bug, always read back the resulting name rather than assuming.

Renaming does **not** change cluster role, which is the key asymmetry: a rename moves the
*name*, promotion moves the *role*. Here the name was already where it needed to be, so
promotion is the remaining step.

## 6. Keepalived config

MASTER/BACKUP below are *VRRP* roles, independent of Technitium's primary/secondary. Put VRRP
MASTER on `meanie` — the box that ends up the Technitium primary — so the VIP normally sits
with the writable node.

```
vrrp_script chk_technitium {
    # locally-authoritative, so the check does not depend on upstream internet
    script "/usr/bin/dig +short +timeout=2 +tries=1 @127.0.0.1 vaderrp.com SOA"
    interval 5
    timeout  3
    rise     2
    fall     2
    weight   -60
}

vrrp_instance DNS_VIP {
    state             MASTER          # BACKUP on meanie, priority 100
    interface         eth0
    virtual_router_id 53              # must be unused on this L2 segment
    priority          150
    advert_int        1
    authentication    { auth_type PASS  auth_pass <secret> }
    virtual_ipaddress { 192.168.7.7/24 dev eth0 }
    track_script      { chk_technitium }
}
```

`192.168.7.7` is free — it survives only in `archive/` (Technitium's old Cilium LB-IPAM
address) and the stale doc lines noted in Phase 6. It falls inside the Cilium `static-pool`
block `192.168.7.0/25`, so treat it as reserved: Cilium will not auto-assign it (that pool
needs the `io.cilium/ipam: static` label plus an explicit `lbipam.cilium.io/ips`), but a
future Service could claim it by hand.

### 6.1 Do not point RFC2136 at the VIP

`internal-dns` and `cluster-dns` must target the primary's real address — `.8` at the end of
either route. Dynamic updates have to reach the cluster primary, not "whichever node answers";
through the VIP they would silently fail whenever it sat on the secondary.

### 6.2 DoT / DoH naming

Plain `:53` needs nothing. If anything is to speak DoT/DoH **to the VIP name**, that name has
to be a SAN on the certs held by *both* nodes.

### 6.3 What should and should not use the VIP

The VIP exists for clients that can only hold **one** resolver address, or that fail over
badly between two. Anything that already does health-checked multi-upstream failover is better
off pointed at the real addresses.

**Should be VIP-only:**

- **UDM DHCP option 6.** The original goal. You cannot conveniently hand every DHCP client a
  sensible two-address list, and stub resolvers vary wildly in how they fail over.

**Should keep real IPs:**

- **CoreDNS** (`kube-system/coredns/app/helmrelease.yaml:69`). The `forward` plugin already
  does per-upstream health tracking and retries another upstream within the same query, and
  `policy round_robin` spreads load across both instances. Collapsing to `. 192.168.7.7`
  would trade all of that for nothing: cluster DNS would funnel through whichever single box
  holds the VIP, and would newly depend on VRRP being healthy — a dependency the cluster does
  not have today. Keep `. 192.168.7.8 192.168.7.9`.
- **`machine.network.nameservers`.** Two entries cost nothing and are strictly more robust
  than depending on VRRP. `.7` is reasonable as the *first* entry with a real IP behind it,
  but a VIP-only list means a VRRP fault takes DNS from every node at once.

Mixing the VIP into a `round_robin` list (`. .7 .8 .9`) is the worst of both — the box holding
the VIP receives roughly twice the share of queries.

**Decided:** CoreDNS stays on `. 192.168.7.8 192.168.7.9`. Do not migrate it to the VIP later
"for consistency" — the asymmetry is deliberate, and the reasoning above is why.

## 7. Rejected alternatives

| Option | Why not |
|---|---|
| Keepalived VIP + `dnsdist` director pair | Best failover semantics, but **masks client IPs** — Technitium's per-client stats and allow/block rules would see the director on every query. Also two more containers to patch. |
| BGP anycast (both advertise `.7/32` to the UDM) | No split brain and router-driven failover, but needs `ns1` reworked into a LoadBalancer Service and depends on UDM ECMP behaviour. Disproportionate. |
| Keepalived in-cluster, DNS in LXCs | Does not work. Keepalived adds the VIP to the local NIC; it must run on a machine that answers `:53`. In-cluster it would claim `.7` on a pod that is not Technitium. |
| Proxmox HA instead of a second instance | §1.5. |
| **Rename the NUC to `ns1` and swap addresses** | The alternative to promoting: rename the existing primary rather than promote a new one, moving it `.9` → `.8` so the conventional `ns1` ↔ `.8` pairing holds. Leaves cluster membership untouched, but both boxes change address, which needs the VIP first to cover the window where neither answers. Not taken — `ns1` was built directly at `.8` instead. |
| **Rename both, move nothing** | NUC `ns2` → `ns1` staying at `.9`; `meanie` → `ns2` at `.8`. Cheapest of all: no address moves, no membership change, and `--rfc2136-host` would have stayed at `.9`. Cost is only that the numbering reads inverted (`ns1` at `.9`), which is cosmetic — nothing in the repo references node *names*. Not taken, but the one to revisit if the naming question ever reopens. |
| Treating the VIP as a prerequisite | It never was. No address moves out from under a client on the chosen route, so the VIP stays what it started as — a convenience for UDM DHCP and faster failover, buildable at any time. |

## References

- [ipvlan CNI plugin](https://www.cni.dev/plugins/current/main/ipvlan/) — master/slave isolation
- [keepalived.conf(5)](https://manpages.debian.org/bookworm/keepalived/keepalived.conf.5.en.html) — `vrrp_script`, `track_script`
- [Technitium: Understanding Clustering](https://blog.technitium.com/2025/11/understanding-clustering-and-how-to.html) — node naming, cluster domain, promotion
- [Technitium DNS Server v14 Released](https://blog.technitium.com/2025/11/technitium-dns-server-v14-released.html)
- [DnsServer issue #1508](https://github.com/TechnitiumSoftware/DnsServer/issues/1508) — node-name concatenation on cluster init
- [Running keepalived in an LXC container](https://forum.proxmox.com/threads/running-keepalived-in-lxc-container.114430/)
