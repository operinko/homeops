# Technitium DNS HA — move ns1 out of the cluster, make the primary sort first, add a VIP

Status: **planned / not implemented**

Two changes that matter, plus one that is nice to have:

1. **Move `ns1` from an in-cluster pod to an LXC on `meanie`** — the substantive change.
2. **Make the cluster primary the node named `ns1`**, so the admin UI opens editable (§2).
3. **Add a Keepalived VIP (`192.168.7.7`)** so the UDM hands out one DNS address.

Step 2 has three possible routes. **Route C is recommended** — it is the only one that touches
neither cluster membership nor the NUC's address.

| | **C — rename both, move nothing** | B — rename and swap addresses | A — promote |
|---|---|---|---|
| What happens | NUC `ns2` → `ns1`, stays at `.9`. `meanie` `ns3` → `ns2`, takes the freed `.8`. | NUC `ns2` → `ns1` and moves `.9` → `.8`; `meanie` `ns3` → `ns2` and takes `.9`. | `meanie` becomes `ns1` at `.8` and is **promoted**, which **ejects the NUC from the cluster** (§2.1). |
| IP moves | `meanie` only, onto a free address | both boxes swap | `meanie` only |
| Cluster membership | unchanged | unchanged | NUC ejected, must rejoin as secondary |
| Client-visible gap | none — `.9` serves throughout | both addresses move | none |
| `--rfc2136-host` | **unchanged at `.9`** | `.9` → `.8` | `.9` → `.8` |
| VIP | optional, whenever | **required first**, to hide the shuffle | optional, whenever |

Route C's only cost is that the numbering reads "backwards" — `ns1` at `.9`, `ns2` at `.8`.
That is cosmetic. Nothing in the repo references node *names*; it references addresses, and
under Route C every existing address reference stays valid, including both `--rfc2136-host`
flags. The apparent `ns1` ↔ `.8` pairing today is coincidence, not a convention.

Target end state — Route C (recommended):

| Node | Host | IP | Name | Cluster role |
|---|---|---|---|---|
| existing | NUC, LXC 100 | `192.168.7.9` | `ns1.dns.vaderrp.com` | **primary** (RFC2136 target, unchanged) |
| new | `meanie`, new LXC | `192.168.7.8` | `ns2.dns.vaderrp.com` | secondary |
| — | floats between the two | `192.168.7.7` | — | VRRP VIP, if built |

Target end state — Route B:

| Node | Host | IP | Name | Cluster role |
|---|---|---|---|---|
| existing | NUC, LXC 100 | `192.168.7.8` | `ns1.dns.vaderrp.com` | **primary** |
| new | `meanie`, new LXC | `192.168.7.9` | `ns2.dns.vaderrp.com` | secondary |
| — | floats between the two | `192.168.7.7` | — | VRRP VIP |

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

So the node that is *primary* has to be the node that sorts *first*. Renaming is the lever;
the only question is which node gets renamed and whether addresses move with it.

- **Route C — rename both, move nothing** *(recommended)*. The NUC keeps `.9` and becomes
  `ns1`; `meanie` becomes `ns2` and takes the `.8` freed by the pod. The primary never moves,
  so there is no address shuffle, no VIP dependency, no cluster membership change, and
  `--rfc2136-host` stays at `.9`. The numbering ends up "inverted" — see the intro for why
  that costs nothing real.
- **Route B — rename and swap addresses.** Same renames, but the NUC also moves `.9` → `.8` so
  the conventional `ns1` ↔ `.8` pairing is preserved. Both boxes change address, which is the
  only step in this plan that creates a window where neither answers — hence the VIP first.
- **Route A — promote.** Ruled out on cost, not on feasibility. See §2.1.

### 2.1 Why promotion is not the cheap option

The "Promote To Primary" confirmation spells out what it actually does:

> The promote To Primary node process will resync complete configuration from the Primary node
> and then proceed to **delete it from the Cluster** followed by upgrading the selected
> Secondary node to become the Primary node in the Cluster. The former Primary node when
> deleted will cause it to **delete all its own Cluster configuration leaving the Cluster**
> without causing any other data loss.

So promotion is **not** a graceful demotion. It resyncs config off the old primary, then ejects
it — and the ejected node wipes its own cluster configuration. Promoting `meanie` would leave a
one-node cluster and require rejoining the NUC as a secondary afterwards, during which the NUC
is a standalone server that is no longer syncing.

That is strictly more disruptive than a rename, which is documented as safe, updates the
cluster primary zone automatically, and does not change cluster role or membership at all.
Promotion remains the right tool for what the dialog describes it as — recovering from a
primary that is unreachable or decommissioned. It is the wrong tool for a planned handover.

(The dialog also settles a Phase 0 unknown: it offers to promote `ns1.dns.vaderrp.com`, so the
pod is a *secondary* and the NUC is confirmed as the cluster primary.)

## 3. Migration plan

Phases 0–2 and 4 are common. Phase 3 (the VIP) is required only on Route B. Phase 5 splits.

Ordering note throughout: `internal-dns` and `cluster-dns` push RFC2136 updates to whichever IP
the **primary** holds. On Route C that is `192.168.7.9` throughout and the flags never change.
On Route B they move to `192.168.7.8` in lockstep with the NUC's address (§6.1).

### Phase 0 — prep

- [x] ~~Confirm which node is the Technitium **cluster primary**.~~ **Confirmed: the NUC.** The
      Promote To Primary dialog offers to promote `ns1.dns.vaderrp.com`, which is only offered
      for secondaries — so the pod is the secondary and the NUC is the primary.
- [ ] Note the **cluster domain**. Inferred as `dns.vaderrp.com` from the cert CN
      `ns1.dns.vaderrp.com`; confirm in Administration → Cluster. It cannot be changed later
      without tearing the cluster down, and every node name must be a subdomain of it.
- [ ] Confirm the pod's Technitium version (`15.4.0`, `app/helmrelease.yaml:41`) so the LXC
      matches. Do not migrate across a version bump.
- [ ] Decide the TLS story (§4.1).

### Phase 1 — build the new LXC on `meanie`

- [ ] Unprivileged Debian LXC on `meanie`, on ZFS, **on a temporary IP (`192.168.7.10`)** so it
      can be built and synced while the pod is still serving `.8`.
- [ ] Install Technitium from **upstream**, not through Harbor — the whole point is that this
      box does not depend on the cluster.
- [ ] Back it up to PBS. This replaces the VolSync/kopia job that goes away in Phase 6, and is
      a straight upgrade over it.

### Phase 2 — join the cluster under a temporary name

- [ ] Join as a **secondary** under the temporary name **`ns3.dns.vaderrp.com`**. The name
      `ns2` is still held by the NUC and `ns1` by the pod, and two nodes cannot share a name —
      hence the third name. Let clustering replicate zones, settings, users, allow/block lists
      and apps. This is far safer than copying `/etc/dns` out of the PVC, which carries node
      identity and DNSSEC keys.
- [ ] **Verify the resulting node name in the UI.** [Issue #1508](https://github.com/TechnitiumSoftware/DnsServer/issues/1508)
      reports names being *concatenated* rather than replaced in some subdomain/cluster-domain
      combinations (`ns01.lan.foo.bar` → `ns01.lan.foo.bar.local.foo.bar`).
- [ ] Confirm it answers on the temporary IP for both an internal zone and a recursive lookup:
      `dig @192.168.7.10 <internal-name>` and `dig @192.168.7.10 google.com`.
- [x] ~~Test "Promote To Primary" on `ns3`.~~ **Answered by reading the confirmation dialog —
      no test needed.** Promotion ejects the old primary from the cluster rather than demoting
      it (§2.1), so Route A is off the table. Do **not** click Promote on a node whose peer you
      want to keep in the cluster.

### Phase 3 — stand up the VIP

> **Route B only.** On Route C no address ever moves out from under a client, so the VIP buys
> nothing the migration needs — it reverts to being the original convenience goal (one entry in
> UDM DHCP, sub-second failover instead of a resolver timeout) and can be built at any point,
> including never. On Route B it must come first: `.8` and `.9` both change hands in Phase 5B,
> and the VIP is what hides that.

Both remaining instances are now LXCs, so this is textbook Keepalived — plain multicast VRRP
across the bridge, nothing in this repo. Config in §6.

- [ ] `apt install keepalived` on the NUC and on `meanie`. NUC is MASTER (priority 150),
      `meanie` BACKUP (priority 100).
- [ ] Verify `dig @192.168.7.7` works, then verify failover both directions — stop Technitium
      on the master (the `vrrp_script` should drop priority) and stop the master host outright.
- [ ] Point **UDM DHCP option 6 at `.7` only**. DHCP clients are now insulated from every
      address change below.

Multicast VRRP does not hardcode peer addresses, so the Phase 5B IP changes need no keepalived
config edits.

### Phase 4 — decommission the pod

- [ ] Reorder `machine.network.nameservers` in `talos/machineconfig.yaml.j2` and roll the
      nodes, **before** taking `.8` down — a dead entry at the head of the list reintroduces
      the §1.2 timeout on every node, not just one.
      - Route C: `[192.168.7.9, 192.168.7.8]`. `.9` never moves, so this is also the permanent
        ordering and fixes the §1.2 latency bug for good.
      - Route B: `[192.168.7.7, 192.168.7.9]`, since `.9` itself moves in Phase 5B.
- [ ] Fix the CoreDNS forward list
      (`kubernetes/apps/kube-system/coredns/app/helmrelease.yaml:69`), currently
      `. 192.168.7.9 192.168.7.8 10.42.1.179`:
      - **Drop `10.42.1.179` permanently.** It is a hardcoded *pod-network* address — almost
        certainly the Technitium pod's cluster IP. It cannot survive the pod being
        decommissioned, and it was already fragile: pod IPs change on every reschedule.
      - **Drop `.8` for the duration** of the gap and re-add once the new box holds it — the
        `round_robin` policy would otherwise aim a share of queries at a dead address.
      - End state: `. 192.168.7.8 192.168.7.9`. See §6.3 before adding the VIP here.
- [ ] Suspend the Flux Kustomization (`flux suspend ks technitium -n flux-system`) and scale
      the HelmRelease to zero. **Suspend, do not delete** — see the Phase 6 warning.
- [ ] Remove the `ns1` node from the Technitium cluster. The name `ns1` and the address `.8`
      are now both free.
- [ ] Soak for a few days. Rollback is un-suspending the Kustomization.

### Phase 5A — promote (Route A)

The NUC is never touched, so `.9` serves continuously and there is no client-visible gap. Keep
the window short anyway: `.8` is dark from Phase 4 until the first step here completes.

- [ ] **`meanie`:** rename `ns3` → `ns1.dns.vaderrp.com`, then move `.10` → `.8`.
- [ ] Verify the name in the UI (issue #1508 again).
- [ ] Promote `meanie` to cluster primary; confirm the NUC settles as a secondary and that
      there is exactly one primary.
- [ ] Re-add `.8` to the CoreDNS forward list.
- [ ] Confirm the Zones tab opens editable by default — the point of the exercise.

### Phase 5B — rotate names and IPs (Route B)

One maintenance window, fully covered by the VIP. Park VRRP mastership on `meanie` first so
the NUC's changes are invisible.

- [ ] Temporarily stop keepalived on the NUC so `meanie` holds `.7`.
- [ ] **NUC:** rename `ns2` → `ns1.dns.vaderrp.com`, then move `.9` → `.8`.
- [ ] **`meanie`:** rename `ns3` → `ns2.dns.vaderrp.com`, then move `.10` → `.9`.
- [ ] Verify both names in the UI after each rename (issue #1508 again).
- [ ] Restart keepalived on the NUC; confirm it reclaims MASTER and that `.7`, `.8` and `.9`
      all answer.
- [ ] Re-add `.8` to the CoreDNS forward list.
- [ ] Confirm the Zones tab opens editable by default — the point of the exercise.

Renaming updates the cluster primary zone automatically, and clustering manages NS/SOA records
across zones, so zone records should not need hand-editing. Verify a zone's SOA MNAME anyway —
this applies to both routes.

### Phase 6 — repo cleanup

> **Order matters.** `technitium/ks.yaml` has `prune: true`, so deleting it takes the PVC and
> the VolSync `ReplicationSource` with it. Export the PVC first
> (`just kube browse-pvc network technitium`) and keep a copy until the LXC has a verified PBS
> backup — even though Phase 2 means you should not need it.

- [ ] **Change `--rfc2136-host` from `192.168.7.9` to `192.168.7.8`** in
      `kubernetes/apps/network/internal-dns/app/helmrelease.yaml:23` and
      `kubernetes/apps/network/cluster-dns/app/helmrelease.yaml:23`. The primary ends up at
      `.8` on both routes. Land this close to the Phase 5 change — external-dns retries, and
      records are not time-critical, but the gap is a real window of failed updates.
- [ ] Delete `kubernetes/apps/network/technitium/` (HelmRelease, OCIRepository, NAD,
      Certificate, HTTPRoutes, secret, ks).
- [ ] Drop `./technitium/ks.yaml` from `kubernetes/apps/network/kustomization.yaml:12`.
- [ ] Delete the stale root `manifest.yaml` — an accidentally-committed rendered dump of the
      *old* Technitium Service (image `14.3.0`, the pre-ipvlan `io.cilium/lb-ipam-ips`
      annotation). It is dead weight and actively misleading.
- [ ] Re-point the Homepage widgets from `http://technitium.network.svc.cluster.local:5380` to
      the LXCs (§4.2).
- [ ] Re-point the `.8` resolver references, which now mean a different box than when they were
      written: `observability/gatus/app/storj-configmap.yaml:35`,
      `media/prowlarr/app/httproute.yaml:16`, `media/maintainerr/app/httproute.yaml:16`.
      Prefer `.7` if the VIP exists.
- [ ] Add both LXCs to `docs/network-map.md` and remove `K_TECHNITIUM` from the in-cluster
      network subgraph.
- [ ] Fix the stale `192.168.7.7` references in `docs/networking/dual-gateway-external-dns.md`
      (lines 23, 31) — now correct by accident; make them deliberate.

## 4. Things that break and need a decision

### 4.1 TLS

cert-manager currently issues `ns1.dns.vaderrp.com` and an initContainer converts it to the
`.pfx` Technitium wants (`app/helmrelease.yaml:31-38`). Outside the cluster that becomes
either acme.sh/certbot in the LXC plus the same `openssl pkcs12 -export -legacy` step, or —
simpler — let **npmplus (LXC 113)** terminate TLS and leave Technitium on plain HTTP
internally.

Note that **certs follow names**. On Route A only `meanie` needs a cert for a name it did not
previously hold; on Route B both boxes swap. Either way, reissue after Phase 5 rather than
trying to move key material around.

### 4.2 Web UI routing

The two HTTPRoutes point at a cluster Service. Reaching an LXC through Gateway API needs a
selector-less Service plus a hand-maintained EndpointSlice. npmplus is the less annoying path
and you already run it for other LXC web UIs.

### 4.3 Backups

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
- **Two nodes cannot hold the same name**, which is why Phase 2 uses the temporary `ns3` and
  why neither Phase 5A nor 5B can start until the pod has left the cluster in Phase 4. This
  holds on both routes — even Route A, which does not rename the NUC, still has to rename
  `ns3` → `ns1`, and cannot do so while the pod holds that name.
- **On cluster init, node names are rewritten** as subdomains of the cluster domain — `ns1` or
  `ns1.mydomain.tld` becomes `ns1.mycluster.tld`. Combined with issue #1508's concatenation
  bug, always read back the resulting name rather than assuming.

Renaming does **not** change cluster role. Renaming the NUC from `ns2` to `ns1` leaves it the
primary; it does not promote or demote anything. This is exactly why the two routes exist:
Route B moves the *name* to the primary, Route A moves the *role* to the name.

## 6. Keepalived config

MASTER/BACKUP below are *VRRP* roles, independent of Technitium's primary/secondary. Put VRRP
MASTER on whichever box ends up the Technitium primary — the NUC on Route B, `meanie` on
Route A — so the VIP normally sits with the writable node.

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
| Route B's rotation before the VIP exists | Leaves a window where neither `.8` nor `.9` answers. On Route B the VIP is what makes the rotation free — on Route A there is no rotation to cover. |
| Rename only, keep IPs | Gives `ns1` = `.9` and `ns2` = `.8`. Every existing `.8` reference in the repo would silently start meaning `ns2`. |
| Treating the VIP as a prerequisite | It is not, on Route A. Only Route B moves addresses out from under clients; Route A leaves `.9` untouched throughout, so the VIP stays what it started as — a convenience for UDM DHCP and faster failover, buildable at any time. |

## References

- [ipvlan CNI plugin](https://www.cni.dev/plugins/current/main/ipvlan/) — master/slave isolation
- [keepalived.conf(5)](https://manpages.debian.org/bookworm/keepalived/keepalived.conf.5.en.html) — `vrrp_script`, `track_script`
- [Technitium: Understanding Clustering](https://blog.technitium.com/2025/11/understanding-clustering-and-how-to.html) — node naming, cluster domain, promotion
- [Technitium DNS Server v14 Released](https://blog.technitium.com/2025/11/technitium-dns-server-v14-released.html)
- [DnsServer issue #1508](https://github.com/TechnitiumSoftware/DnsServer/issues/1508) — node-name concatenation on cluster init
- [Running keepalived in an LXC container](https://forum.proxmox.com/threads/running-keepalived-in-lxc-container.114430/)
