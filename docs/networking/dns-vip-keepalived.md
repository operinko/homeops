# Single DNS VIP for ns1 + ns2 (Keepalived / VRRP) — design research

Status: **research / not implemented**

Goal: hand out **one** DNS address (`192.168.7.7`) from the UDM instead of two, and have it
follow whichever Technitium instance is alive — so clients stop depending on stub-resolver
failover between two nameservers.

## 1. Current state

| Instance | Where | IP | Notes |
|---|---|---|---|
| `ns1` | Technitium pod, `network` ns | `192.168.7.8` | Multus **ipvlan L2** NAD, static IPAM, `strategy: Recreate`, `local-path` PVC |
| `ns2` | LXC 100 on the NUC (Proxmox) | `192.168.7.9` | Plain container, stable |

Both IPs are hardcoded in several places:

| Consumer | File | Value |
|---|---|---|
| Talos node resolvers | `talos/machineconfig.yaml.j2:49-51` | `.8` then `.9` |
| CoreDNS forward | `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml:69` | `. 192.168.7.9 192.168.7.8 10.42.1.179`, `round_robin`, `force_tcp` |
| external-dns RFC2136 | `kubernetes/apps/network/{internal,cluster}-dns/app/helmrelease.yaml:23` | `--rfc2136-host=192.168.7.9` |
| Gatus / HTTPRoute probes | `observability/gatus/app/storj-configmap.yaml`, `media/{prowlarr,maintainerr}/app/httproute.yaml` | `tcp://192.168.7.8:53` |
| UDM DHCP option 6 | (outside this repo) | both |

`192.168.7.7` is free. It only survives in `archive/` (it was Technitium's old Cilium
LB-IPAM address) and in one stale line of `dual-gateway-external-dns.md`. Note it *does*
fall inside the Cilium `static-pool` block `192.168.7.0/25`, so it should be treated as
reserved — Cilium won't auto-assign it (that pool requires the `io.cilium/ipam: static`
label plus an explicit `lbipam.cilium.io/ips`), but a future Service could claim it by hand.

## 2. Verdict

Keepalived **will** work, and it is the right tool — but the naive shape (VRRP directly
between the two Technitium instances, VIP floating onto whichever is up) has one hard
constraint that changes what the VIP can be used for.

**Recommended:** VRRP between `ns1` and `ns2` with **ns2 as MASTER**, VIP `192.168.7.7`,
unicast peers, and a DNS-level health check driving priority. Use the VIP for DHCP clients
and app-level resolvers. **Do not** collapse `machine.network.nameservers` on the Talos
nodes to the VIP alone — see §3.1.

## 3. Constraints found

### 3.1 ipvlan master isolation — the important one

ipvlan (like macvlan) **does not allow a slave interface to talk to its own master**. `ns1`'s
`net1` is an ipvlan slave of the Talos node's default-route interface, so:

> The Talos node currently hosting the `ns1` pod cannot reach `192.168.7.8` from its host
> network namespace — today, already, independent of any VIP work.

Two consequences:

1. **Existing latent bug.** Talos `hostDNS` is enabled and forwards to `[.8, .9]` in order.
   On whichever node runs `ns1`, every host-level lookup pays a full timeout against `.8`
   before falling back to `.9`. Swapping the order to `[.9, .8]` in
   `talos/machineconfig.yaml.j2` is a cheap independent win.
2. **It caps what the VIP can replace.** If the VIP lands on the `ns1` pod, the node hosting
   that pod loses DNS entirely. So the Talos nameserver list must keep at least one real,
   always-off-node IP. Making `ns2` the VRRP MASTER means the VIP normally lives in the LXC
   (reachable from every node), but "normally" is not "always" — keep `.9` explicitly listed.

The VIP is still fully usable for the actual ask: **UDM DHCP clients, workstations, other
LXCs, and in-cluster resolvers**, none of which sit on the ipvlan master.

### 3.2 VRRP multicast over ipvlan → use unicast

VRRP advertises to multicast `224.0.0.18`. ipvlan L2 multicast is handled through a deferred
work queue and is unreliable in this shape. Use keepalived's unicast mode
(`unicast_src_ip` + `unicast_peer`), which sidesteps multicast entirely and is the standard
answer where multicast isn't dependable.

Also: **`use_vmac` is not usable here.** It creates a macvlan sub-interface for the VRRP
virtual MAC; ipvlan slaves share the master's MAC and cannot carry a second one. Run
keepalived in its default mode (VIP added to the existing interface + gratuitous ARP).

### 3.3 Pod Security Admission — not a blocker

The `network` namespace is labelled `pod-security.kubernetes.io/enforce: privileged`
(`kubernetes/apps/network/namespace.yaml:7`), so a keepalived sidecar with `NET_ADMIN` /
`NET_RAW` / `NET_BROADCAST` is permitted. It does need a per-container override of the
pod-level `runAsNonRoot: true` / `runAsUser: 1000` set in `defaultPodOptions`.

### 3.4 Pod churn

`ns1` uses `strategy: Recreate` with a `local-path` PVC, so every Renovate image bump,
chart bump or node drain takes the pod down. With `ns2` as MASTER the VIP simply never lives
on the pod except during a real `ns2` outage, which removes churn as a concern. (The reverse
assignment would move the VIP on every image bump — avoid it.)

### 3.5 Split brain

Unicast VRRP across a partition means both sides claim `.7`. Duplicate-IP on the LAN is
noisy but, for stateless UDP DNS, mostly self-healing. Mitigate with
`vrrp_check_unicast_src` and by keeping both peers on the same L2 segment.

### 3.6 RFC2136 must stay pinned to `.9`

`internal-dns` and `cluster-dns` push dynamic updates to `--rfc2136-host=192.168.7.9`.
Dynamic updates must reach the **cluster primary**, not "whichever node answers". Pointing
these at the VIP would silently break record publication whenever the VIP sat on the
secondary. Leave both flags at `.9`.

### 3.7 Technitium clustering does not solve this

Technitium v14+ clustering (the `53443` port already exposed in the HelmRelease) replicates
users, settings, allow/block lists, apps and zones from primary to secondary. It provides no
VIP, no anycast, and no shared address — and the Technitium docs explicitly prefer two DNS
entries over a VIP ("it does not depend on any other mechanism for redundancy"). Clustering
is complementary: it is what makes the two nodes genuinely interchangeable, which is the
precondition for a VIP being safe at all.

### 3.8 TLS naming for DoT / DoH

The cert today is `ns1.dns.vaderrp.com` only (`app/certificate.yaml`). If anything is to
speak DoT/DoH **to the VIP name**, that name needs to be a SAN on the certs held by *both*
nodes. Plain UDP/TCP :53 needs nothing.

### 3.9 `virtual_router_id` collision

Pick a VRID unused on the segment. The UDM and any other keepalived pair are the things to
check. `53` is a readable choice if free.

## 4. Options considered

### Option A — VRRP between ns1 and ns2 *(recommended)*

VIP `.7` floats between the pod and the LXC. Keepalived sidecar in the Technitium pod
(pod netns, so it can add the VIP to `net1`), keepalived package in LXC 100.

- **+** No new infrastructure.
- **+** **Client IPs are preserved** — Technitium sees the real querying host, so per-client
  stats, allow/block rules and DHCP-derived client names keep working. This is the single
  biggest reason to prefer A over B.
- **+** No extra network hop.
- **−** Cannot simplify the Talos nameserver list (§3.1).
- **−** Requires a privileged-ish sidecar in the DNS pod.

### Option B — keepalived VIP + `dnsdist` on a director pair

Two small LXCs on *different* physical hosts hold `.7` via VRRP and run `dnsdist` in front of
`.8` and `.9` with DNS-aware health checks.

- **+** VIP is independent of both DNS servers; genuinely fixes §3.1, so Talos nameservers
  *could* collapse to the VIP.
- **+** Best failure semantics — real query-level health checking and per-query failover
  rather than whole-node failover.
- **−** **Masks client IPs.** Technitium would see the director on every query unless ECS is
  enabled end-to-end, and "Top Clients" becomes useless. For a setup that leans on per-client
  DNS policy, this is a serious regression.
- **−** Two more containers to build, patch and keep on separate hosts.
- Note: plain LVS/IPVS is a poor fit here — DR mode needs the VIP on loopback with ARP
  suppression on both real servers (awkward inside the pod), and NAT mode needs the director
  to be the real servers' default gateway (not possible). A DNS-aware proxy is the right
  layer.

### Option C — BGP anycast

Both instances advertise `.7/32` to the UDM; failover is route withdrawal, so no VRRP, no ARP
games and no split brain. Cilium already peers with the UDM (ASN 65001 → 65000).

- **−** Requires `ns1` to become a LoadBalancer Service rather than an ipvlan pod, which is a
  much larger change to how `ns1` is addressed.
- **−** Requires a BGP daemon (bird/frr) in the ns2 LXC.
- **−** Depends on UDM ECMP/multipath behaviour, which is not something to discover the hard way.

Interesting, but disproportionate to the problem.

## 5. Sketch for Option A

VRID, addresses and the auth password are illustrative; the password belongs in
`app/secret.sops.yaml`.

**ns2 — LXC 100, `/etc/keepalived/keepalived.conf`**

```
vrrp_script chk_technitium {
    # Query a locally-authoritative name so the check does not depend on upstream internet
    script "/usr/bin/dig +short +timeout=2 +tries=1 @127.0.0.1 vaderrp.com SOA"
    interval 5
    timeout  3
    rise     2
    fall     2
    weight   -60
}

vrrp_instance DNS_VIP {
    state           MASTER
    interface       eth0
    virtual_router_id 53
    priority        150
    advert_int      1

    unicast_src_ip  192.168.7.9
    unicast_peer    { 192.168.7.8 }
    vrrp_check_unicast_src

    authentication { auth_type PASS  auth_pass <sops> }

    virtual_ipaddress { 192.168.7.7/24 dev eth0 }
    track_script      { chk_technitium }
}
```

**ns1 — sidecar in the Technitium pod**

Same block with `state BACKUP`, `priority 100`, `interface net1`,
`unicast_src_ip 192.168.7.8`, `unicast_peer { 192.168.7.9 }`, and the VIP on `net1`.

Container additions needed in `app/helmrelease.yaml`:

```yaml
containers:
  keepalived:
    securityContext:
      runAsUser: 0            # overrides the pod-level runAsNonRoot
      runAsNonRoot: false
      capabilities:
        add: ["NET_ADMIN", "NET_RAW", "NET_BROADCAST"]
        drop: ["ALL"]
```

plus an `emptyDir` at `/run` (keepalived pidfiles) and a ConfigMap mount for
`keepalived.conf`.

LXC note: an unprivileged Proxmox container needs `lxc.cap.keep = net_admin` to retain
`CAP_NET_ADMIN` for VIP manipulation.

## 6. Rollout order, if pursued

1. Reorder Talos nameservers to `[.9, .8]` — independent win, fixes §3.1(1).
2. Confirm Technitium clustering is actually healthy between ns1/ns2 (VIP is only safe if the
   two are genuinely interchangeable).
3. Reserve `.7`; clean the stale `.7` reference in `dual-gateway-external-dns.md`.
4. Stand up keepalived on ns2 only, verify it claims `.7` and answers DNS on it.
5. Add the ns1 sidecar; verify failover both directions with `dig @192.168.7.7` under
   `kubectl delete pod` and under an ns2 stop.
6. Point UDM DHCP option 6 at `.7` **only after** step 5 passes.
7. Leave `machine.network.nameservers`, both `--rfc2136-host` flags, and the CoreDNS forward
   list on real IPs. Optionally add `.7` as a *third* CoreDNS forward target.

## 7. Open questions

- Is `ns2` the Technitium **cluster primary**? The `--rfc2136-host=192.168.7.9` flags imply
  yes; worth confirming, since MASTER and primary landing on the same box is the tidy outcome.
- Does anything on the LAN already use VRRP (UDM redundancy, another keepalived)? Determines
  the VRID.
- Should the VIP name (`dns.vaderrp.com`?) be added as a SAN on both certs, or is the VIP
  plain-`:53` only?

## References

- [ipvlan CNI plugin](https://www.cni.dev/plugins/current/main/ipvlan/) — master/slave isolation
- [keepalived.conf(5)](https://manpages.debian.org/bookworm/keepalived/keepalived.conf.5.en.html) — `unicast_peer`, `vrrp_script`, `use_vmac`
- [Keepalived and unicast over multiple interfaces](https://vincent.bernat.ch/en/blog/2020-keepalived-unicast-vxlan) — unicast VRRP rationale
- [Technitium: Understanding Clustering](https://blog.technitium.com/2025/11/understanding-clustering-and-how-to.html)
- [Technitium DNS Server v14 Released](https://blog.technitium.com/2025/11/technitium-dns-server-v14-released.html)
- [Running keepalived in an LXC container](https://forum.proxmox.com/threads/running-keepalived-in-lxc-container.114430/)
