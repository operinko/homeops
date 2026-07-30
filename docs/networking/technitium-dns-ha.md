# Technitium DNS HA — move ns1 out of the cluster, then add a VIP

Status: **planned / not implemented**

Two changes, in order:

1. **Move `ns1` from an in-cluster pod to an LXC on `meanie`.** This is the substantive change.
2. **Optionally add a Keepalived VIP (`192.168.7.7`)** so the UDM hands out one DNS address
   instead of two.

Step 1 stands on its own and step 2 gets much simpler once it is done. Do not do them together.

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

## 2. Migration plan

Throughout: `internal-dns` and `cluster-dns` push RFC2136 updates to `192.168.7.9`, which is
untouched by all of this. **external-dns keeps working through the entire migration** — do not
retarget those flags.

### Phase 0 — prep

- [ ] Confirm which node is the Technitium **cluster primary**. The `--rfc2136-host=192.168.7.9`
      flags imply `ns2`; verify in the admin UI. Config changes require the primary online.
- [ ] Confirm the pod's Technitium version (`15.4.0`, `app/helmrelease.yaml:41`) so the LXC
      matches. Do not migrate across a version bump.
- [ ] Decide the TLS story (§3.1).
- [ ] Pick a maintenance slot where you will not also be restarting the cluster — DNS capacity
      is halved during cutover.

### Phase 1 — build the new LXC on `meanie`

- [ ] Unprivileged Debian LXC on `meanie`, on ZFS, **on a temporary IP (e.g. `192.168.7.10`)**
      so it can be built and synced while the pod is still serving `.8`.
- [ ] Install Technitium from **upstream**, not through Harbor — the whole point is that this
      box does not depend on the cluster.
- [ ] Back it up to PBS. This replaces the VolSync/kopia job that goes away in Phase 4, and is
      a straight upgrade over it.

### Phase 2 — replicate config

- [ ] Join the new LXC to the existing Technitium cluster **as a secondary** of `ns2`. Let
      clustering replicate zones, settings, users, allow/block lists and apps. This is exactly
      what clustering is for and is far safer than copying `/etc/dns` out of the PVC.
- [ ] Verify it answers correctly on the temporary IP for both an internal zone and a
      recursive lookup: `dig @192.168.7.10 <internal-name>` and `dig @192.168.7.10 google.com`.

### Phase 3 — cutover

- [ ] Suspend the Flux Kustomization (`flux suspend ks technitium -n flux-system`) and scale
      the HelmRelease to zero. **Suspend, do not delete** — see the warning in Phase 4.
- [ ] Confirm `.8` is dark, then move the LXC from `.10` to `192.168.7.8`.
- [ ] Verify `dig @192.168.7.8` from a Talos node — this is the check that proves §1.2 is
      fixed, since it previously failed from whichever node hosted the pod.
- [ ] Remove the old pod node from the Technitium cluster membership.
- [ ] Soak for a few days before Phase 4. Rollback during this window is just un-suspending
      the Kustomization and moving the LXC back to `.10`.

### Phase 4 — repo cleanup

> **Order matters.** `technitium/ks.yaml` has `prune: true`, so deleting it takes the PVC and
> the VolSync `ReplicationSource` with it. Export the PVC first
> (`just kube browse-pvc network technitium`) and keep a copy until the LXC has a verified PBS
> backup — even though Phase 2 means you should not need it.

- [ ] Delete `kubernetes/apps/network/technitium/` (HelmRelease, OCIRepository, NAD,
      Certificate, HTTPRoutes, secret, ks).
- [ ] Drop `./technitium/ks.yaml` from `kubernetes/apps/network/kustomization.yaml:12`.
- [ ] Delete the stale root `manifest.yaml` — an accidentally-committed rendered dump of the
      *old* Technitium Service (image `14.3.0`, the pre-ipvlan `io.cilium/lb-ipam-ips`
      annotation). It is dead weight and actively misleading.
- [ ] Re-point the Homepage widgets from `http://technitium.network.svc.cluster.local:5380` to
      the LXC (§3.2).
- [ ] Update the `.8` resolver references now that the target is an LXC — behaviourally
      unchanged, but worth confirming they still resolve:
      `observability/gatus/app/storj-configmap.yaml:35`,
      `media/prowlarr/app/httproute.yaml:16`, `media/maintainerr/app/httproute.yaml:16`.
- [ ] Add the new LXC to `docs/network-map.md` under `meanie`, and remove `K_TECHNITIUM` from
      the in-cluster network subgraph.
- [ ] Fix the stale `192.168.7.7` references in `docs/networking/dual-gateway-external-dns.md`
      (lines 23, 31) — either to `.8`/`.9`, or to the VIP once §4 is done.

### Phase 5 — Talos nameservers

- [ ] Reorder `machine.network.nameservers` to `[.9, .8]` in `talos/machineconfig.yaml.j2`
      (or add `.7` once §4 exists). Applying this rolls the nodes, so do it after DNS is stable
      — it is a latency fix, not an outage fix.

## 3. Things that break and need a decision

### 3.1 TLS

cert-manager currently issues `ns1.dns.vaderrp.com` and an initContainer converts it to the
`.pfx` Technitium wants (`app/helmrelease.yaml:31-38`). Outside the cluster that becomes
either acme.sh/certbot in the LXC plus the same `openssl pkcs12 -export -legacy` step, or —
simpler — let **npmplus (LXC 113)** terminate TLS and leave Technitium on plain HTTP
internally.

### 3.2 Web UI routing

The two HTTPRoutes point at a cluster Service. Reaching an LXC through Gateway API needs a
selector-less Service plus a hand-maintained EndpointSlice. npmplus is the less annoying path
and you already run it for other LXC web UIs.

### 3.3 Backups

VolSync/kopia drops off with the ks. PBS covers the LXC and is a better fit — whole-container
backups instead of a PVC snapshot.

## 4. The VIP, afterwards

Once both instances are LXCs on separate hosts, this is textbook Keepalived — plain multicast
VRRP across the bridge, no ipvlan workarounds, nothing in this repo.

Make **`ns2` the MASTER** (priority 150) and the new `ns1` BACKUP (priority 100), with a
`vrrp_script` running `dig` against a locally-authoritative name so a Technitium crash — not
just a dead host — triggers failover.

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
    state             MASTER          # BACKUP on ns1, priority 100
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
address) and the stale doc lines noted in Phase 4. It falls inside the Cilium `static-pool`
block `192.168.7.0/25`, so treat it as reserved: Cilium will not auto-assign it (that pool
needs the `io.cilium/ipam: static` label plus an explicit `lbipam.cilium.io/ips`), but a
future Service could claim it by hand.

### 4.1 Is the VIP still worth it?

Be honest about this after Phase 5. The reason two nameservers behaved badly was not
stub-resolver failover in general — it was that `.8` was a black hole on one node (§1.2). With
both servers as LXCs, a plain `[.9, .8]` list just works, with no VRRP, no VRID and no
split-brain risk.

What the VIP still buys:

- **One entry in UDM DHCP**, for clients you cannot hand two addresses to. This is the
  original ask.
- **Sub-second failover** instead of a resolver timeout.

What it costs: a split-brain failure mode, and a shared VRID to keep track of.

Either way, **keep both real IPs** in `machine.network.nameservers` and the CoreDNS forward
list. There, two entries cost nothing and are strictly more robust than depending on VRRP.

### 4.2 Do not point RFC2136 at the VIP

`internal-dns` and `cluster-dns` must keep `--rfc2136-host=192.168.7.9`. Dynamic updates have
to reach the cluster primary, not "whichever node answers" — through the VIP they would
silently fail whenever it sat on the secondary.

### 4.3 DoT / DoH naming

Plain `:53` needs nothing. If anything is to speak DoT/DoH **to the VIP name**, that name has
to be a SAN on the certs held by *both* nodes.

### 4.4 Technitium clustering is the precondition

Clustering (the `53443` port the HelmRelease already exposes) replicates config only — no VIP,
no anycast. But it is what makes the two nodes genuinely interchangeable, which is what makes
a floating VIP safe at all. [Technitium's own docs](https://blog.technitium.com/2025/11/understanding-clustering-and-how-to.html)
prefer two DNS entries over a VIP precisely because a VIP adds a dependency. Worth weighing
against §4.1.

## 5. Rejected alternatives

| Option | Why not |
|---|---|
| Keepalived VIP + `dnsdist` director pair | Best failover semantics, but **masks client IPs** — Technitium's per-client stats and allow/block rules would see the director on every query. Also two more containers to patch. |
| BGP anycast (both advertise `.7/32` to the UDM) | No split brain and router-driven failover, but needs `ns1` reworked into a LoadBalancer Service and depends on UDM ECMP behaviour. Disproportionate. |
| Keepalived in-cluster, DNS in LXCs | Does not work. Keepalived adds the VIP to the local NIC; it must run on a machine that answers `:53`. In-cluster it would claim `.7` on a pod that is not Technitium. |
| Proxmox HA instead of a second instance | §1.5. |

## References

- [ipvlan CNI plugin](https://www.cni.dev/plugins/current/main/ipvlan/) — master/slave isolation
- [keepalived.conf(5)](https://manpages.debian.org/bookworm/keepalived/keepalived.conf.5.en.html) — `vrrp_script`, `track_script`, `unicast_peer`
- [Technitium: Understanding Clustering](https://blog.technitium.com/2025/11/understanding-clustering-and-how-to.html)
- [Technitium DNS Server v14 Released](https://blog.technitium.com/2025/11/technitium-dns-server-v14-released.html)
- [Running keepalived in an LXC container](https://forum.proxmox.com/threads/running-keepalived-in-lxc-container.114430/)
