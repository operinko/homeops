# Technitium DNS VIP — Keepalived setup

Floats `192.168.7.7` between the two Technitium LXCs so the UDM can hand out one
DNS address instead of two, and so failover takes ~3 seconds rather than a
stub-resolver timeout.

| | |
|---|---|
| VIP | `192.168.7.7` |
| `ns1` | LXC 118 on `meanie`, `192.168.7.8`, Technitium **primary**, VRRP **MASTER** |
| `ns2` | LXC 100 on the NUC, `192.168.7.9`, Technitium secondary, VRRP BACKUP |

VRRP MASTER is on `ns1` so the VIP normally sits with the Technitium primary —
the node that is also the RFC2136 target for external-dns.

Design rationale:
[`docs/networking/technitium-dns-ha.md`](../../docs/networking/technitium-dns-ha.md) §6.

---

## Before you start

Five checks. The first two are the ones that ruin your afternoon if skipped.

### 1. Is VRID 53 already in use on this segment?

Two VRRP pairs sharing a VRID on the same L2 will fight over the same virtual
MAC. Watch for a minute on either node:

```sh
timeout 60 tcpdump -i eth0 -n 'proto 112'
```

Silence means 53 is free. If anything appears, note its VRID from the output and
pick a different number in both config files. The UDM is the likely candidate if
it has any redundancy configured.

### 2. Is `192.168.7.7` actually free?

```sh
ping -c3 192.168.7.7          # should fail
arping -c3 -I eth0 192.168.7.7  # should get no reply
```

It should be free — it survives only in `archive/` as Technitium's old Cilium
LB-IPAM address. Note it *does* fall inside the Cilium `static-pool` block
`192.168.7.0/25`, so it is worth treating as reserved: Cilium will not
auto-assign it, but a Service could still claim it by hand.

### 3. Does the LXC have the capabilities keepalived needs?

VRRP needs raw sockets and the ability to add an address. Unprivileged Proxmox
containers keep `CAP_NET_ADMIN` and `CAP_NET_RAW` by default, but confirm rather
than assume:

```sh
capsh --print | grep -oE 'cap_net_admin|cap_net_raw'
```

Both should appear. If not, add to the container config on the Proxmox host:

```
lxc.cap.keep = net_admin net_raw
```

### 4. Is `dig` installed?

The health check needs it:

```sh
command -v dig || apt install -y bind9-dnsutils
```

### 5. Is Technitium listening on all addresses?

This is the one that silently produces a VIP that answers nothing. In the admin
UI, **Settings → General → DNS Server Local End Points** must be `0.0.0.0:53`
(and `[::]:53`) rather than a list of specific addresses — otherwise the server
will not answer on `.7` when the VIP lands.

Confirm the interface name is `eth0` while you are there:

```sh
ip -brief addr
```

---

## 1. Install keepalived on both nodes

```sh
apt update && apt install -y keepalived
```

Do not enable it yet — the shipped config is empty and starting it now just
produces noise.

## 2. Install the health check

On **both** nodes:

```sh
install -m 0755 -o root -g root check-technitium-dns.sh /usr/local/bin/
/usr/local/bin/check-technitium-dns.sh && echo "check passes"
```

Root ownership and `0755` matter: `enable_script_security` makes keepalived
refuse to run a script that is writable by anyone else.

The check queries `vaderrp.com SOA` against `127.0.0.1` — a locally
authoritative name, chosen so an internet outage does not move the VIP. Both
nodes would be equally unable to resolve upstream, and moving it would help
nobody.

## 3. Install the configs

Pick an auth password of **8 characters or fewer** — VRRPv2 truncates beyond
that, and a silent truncation mismatch is a miserable thing to debug. It is not
a security control, just a guard against a VRID collision with something
unrelated.

```sh
# on ns1
install -m 0600 keepalived-ns1.conf /etc/keepalived/keepalived.conf
# on ns2
install -m 0600 keepalived-ns2.conf /etc/keepalived/keepalived.conf

# then on both, replace CHANGEME with the same value
sed -i 's/CHANGEME/<yourpass>/' /etc/keepalived/keepalived.conf
```

## 4. Bring it up — ns1 first

```sh
systemctl enable --now keepalived
systemctl status keepalived --no-pager
ip -brief addr show eth0
```

`ip addr` should now show **both** `192.168.7.8` and `192.168.7.7` on `eth0`.
The journal should show the instance entering MASTER state:

```sh
journalctl -u keepalived -n 30 --no-pager
```

Then confirm the VIP actually serves DNS, which is the thing that matters:

```sh
dig @192.168.7.7 vaderrp.com SOA +short
```

If the address is up but this returns nothing, revisit pre-flight check 5.

## 5. Bring up ns2

```sh
systemctl enable --now keepalived
ip -brief addr show eth0     # should NOT have .7
journalctl -u keepalived -n 30 --no-pager
```

`ns2` must stay in BACKUP state and must **not** hold the VIP. If both nodes
have `.7`, they cannot see each other's advertisements — check that `auth_pass`
matches exactly, that the unicast addresses are the right way round, and that
nothing is filtering IP protocol 112 between them.

## 6. Test failover

Three separate failure modes. Test all three — they exercise different paths.

**Keepalived stops** (clean handover):

```sh
# ns1
systemctl stop keepalived
# ns2 — .7 should appear within ~3s
ip -brief addr show eth0
dig @192.168.7.7 vaderrp.com SOA +short
# ns1 — restore, VIP should come back
systemctl start keepalived
```

**Technitium dies but the host lives** — this is the one a plain VRRP setup
misses and the `vrrp_script` exists for:

```sh
# ns1
systemctl stop technitium
# within ~10s (interval 5, fall 2) ns2 should take the VIP
# ns1
systemctl start technitium
```

**The whole node disappears:**

```sh
# from the Proxmox host
pct stop 118
```

Watch from a third machine throughout:

```sh
while true; do dig @192.168.7.7 vaderrp.com SOA +short | head -1; sleep 1; done
```

A gap of a second or two during handover is expected. A gap that does not
recover is not.

## 7. Point things at it

- **DNS records.** `dns.vaderrp.com` A → `192.168.7.7`. Also move
  `technitium.vaderrp.com` from `.8` to `.7` if you want the admin UI to follow
  the VIP — the certificate covers both names.
- **UDM DHCP option 6** → `.7` only. This is the original goal: one address for
  clients you cannot conveniently hand two.
- **Leave `machine.network.nameservers` and the CoreDNS forward list on the real
  IPs.** Two entries cost nothing there and are strictly more robust than
  depending on VRRP. Only DHCP clients need the VIP.
- **Leave `--rfc2136-host` at `192.168.7.8`.** Dynamic updates must reach the
  cluster *primary*, not whichever node happens to hold the VIP.

## 8. Monitoring

Add to `kubernetes/apps/observability/gatus/app/gatus-config.yaml` once the VIP
is live — not before, or it alerts on something that does not exist yet:

```yaml
  - name: technitium VIP
    group: Network
    url: "192.168.7.7"
    interval: 1m
    dns:
      query-name: "vaderrp.com"
      query-type: "SOA"
    conditions:
      - "[DNS_RCODE] == NOERROR"
    alerts:
      - type: ntfy
        send-on-resolved: true
        failure-threshold: 3
        success-threshold: 5
```

This catches the case the per-node checks cannot: both nodes healthy, but the
VIP held by nobody.

## Rollback

```sh
systemctl disable --now keepalived     # on both nodes
```

The address disappears with the daemon. Revert UDM DHCP to `.8`/`.9` and the
setup is exactly as it was — nothing here changes Technitium's own
configuration.

---

## Optional: exposing encrypted DNS to the internet

Forwarding `853` and `443` at the UDM to the VIP gives you DoT/DoQ/DoH from
outside the house. It works, and the VIP is the right forward target since it
follows whichever node is alive. But read this section before doing it.

### The problem nobody warns you about

**Recursion ACLs do not protect authoritative zones.** Technitium's "Allow
Recursion Only For Private Networks" governs *recursive* lookups. Your internal
`vaderrp.com` zone is **authoritative**, and authoritative answers are served to
anyone who asks, ACL or not.

So a public DoT endpoint would let anyone resolve `sonarr.vaderrp.com`,
`harbor.vaderrp.com`, `proxmox.vaderrp.com` and the rest straight to their
internal addresses — your entire service inventory and IP layout, queryable by
anyone who can guess a hostname. And the endpoint is discoverable: the
certificate's SANs are in public Certificate Transparency logs.

Fix this **before** opening the ports, via **Zones → vaderrp.com → Options →
Query Access**, set to private networks only. Verify from outside afterwards:

```sh
kdig +tls @<your-wan-ip> sonarr.vaderrp.com     # must REFUSE or return nothing
kdig +tls @<your-wan-ip> google.com             # this is what should work
```

### The other trade

Allowing recursion for public clients makes this an open resolver. A roaming
phone has no fixed address, so there is no ACL that admits you and excludes
everyone else, and Technitium has no per-client authentication for DNS.

It is a milder problem than it sounds — DoT, DoQ and DoH all require a
handshake, so none of them can be used for the spoofed-source reflection
amplification that makes open UDP/53 resolvers dangerous. What remains is
resource consumption and strangers using your resolver.

Mitigate with **Settings → General → QPM Limit**, which rate limits per client
subnet.

### If you would rather not

A VPN back home — Tailscale, or WireGuard on the UDM — gives roaming clients
encrypted DNS *and* internal name resolution with nothing exposed, and sidesteps
both problems above entirely. Worth weighing, given the only thing public
exposure buys over it is not having to run a VPN client.

### If you go ahead

- **Forward only `853/tcp`, `853/udp`, `443/tcp`, `443/udp`.** Never forward
  `53` in either protocol — that *is* exploitable for reflection amplification.
- **Check `443/tcp` is not already forwarded** to something else. Public web
  traffic goes through the Cloudflare tunnel rather than a port forward, so it
  should be clear, but confirm.
- **The public record must be DNS-only, not proxied.** In Cloudflare, an A
  record for `dns.vaderrp.com` → your WAN IP with the grey cloud. Orange-cloud
  proxying does not carry `853` at all, and on `443` it would terminate TLS with
  Cloudflare's certificate and break DoH3.
- **Split-horizon still applies**, and correctly: internal clients get `.7` from
  Technitium, external clients get the WAN IP from Cloudflare. Same name, right
  answer on both sides.
- **Watch your WAN IP** if it is dynamic — the public record needs DDNS or it
  will silently point at somebody else's address.
