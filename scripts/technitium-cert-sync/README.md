# Technitium TLS bundle sync

NPMplus is the only ACME client. It issues one certificate covering
`technitium.vaderrp.com`, `*.dns.vaderrp.com` and `dns.vaderrp.com` via DNS-01
through Cloudflare, and each Technitium LXC pulls the result on a timer,
converts it to PKCS#12, and drops it where Technitium expects it.

Design rationale, including why the nodes pull rather than NPMplus pushing:
[`docs/networking/technitium-dns-ha.md`](../../docs/networking/technitium-dns-ha.md) §4.1.

## Why pull

A push would mean NPMplus holding an SSH credential able to write
`/etc/dns/ssl.pfx` on every DNS server — root-equivalent over the whole DNS
tier, held by the most network-exposed component in the chain. Pulling reverses
that: each node holds a read-only credential for one directory, and a
compromised NPMplus cannot write anything to a DNS server.

## Prerequisites

- NPMplus runs as a container with `/opt/npmplus:/data`, so the certificate it
  writes to `/data/tls/certbot/live/npm-15/` is visible on the **LXC
  filesystem** at `/opt/npmplus/tls/certbot/live/npm-15/`. Nothing inside the
  container is touched, so image updates cannot break this.
- A proxy host must stay attached to the certificate in NPMplus — it only
  renews certificates that have one, even if nothing routes through it.

## Install on NPMplus

`privkey.pem` is root-owned `0600`, so the key goes in root's
`authorized_keys`. `rrsync -ro` confines it to read-only access under one
directory, which is what makes that acceptable.

```sh
# Debian ships rrsync in the rsync package. Confirm the path before using it.
command -v rrsync || ls /usr/share/doc/rsync/scripts/
```

Scope the forced command to the **parent** of `live/`, not to `live/npm-15`:
those entries are symlinks into a sibling `archive/` directory, and a
restriction rooted at `live/npm-15` puts their targets outside the permitted
subtree.

```
# /root/.ssh/authorized_keys on the NPMplus LXC
command="rrsync -ro /opt/npmplus/tls/certbot",restrict ssh-ed25519 AAAA... technitium-cert-sync
```

Generate one key per node so either can be revoked independently.

## Install on each Technitium node

```sh
install -m 0755 technitium-cert-sync.sh /usr/local/bin/
install -m 0644 technitium-cert-sync.service technitium-cert-sync.timer /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now technitium-cert-sync.timer

# First run, watching the output
systemctl start technitium-cert-sync.service
journalctl -u technitium-cert-sync.service -n 20
```

Then in the Technitium admin UI, Settings → Optional Protocols:

- **TLS Certificate File Path**: `/etc/dns/ssl.pfx`
- **TLS Certificate Password**: leave empty

Clustering replicates both of those settings, so the path and password must be
identical on every node. The bundle contents are identical too, since one
certificate is distributed.

## Configuration

The script reads four optional environment variables, all with defaults that
match this deployment. Override via a systemd drop-in if needed:

| Variable | Default | Meaning |
|---|---|---|
| `SRC_HOST` | `root@npmplus` | Host serving the bundle |
| `SRC_PATH` | `live/npm-15` | Path **relative to the rrsync root** |
| `OUT` | `/etc/dns/ssl.pfx` | Where Technitium reads the bundle |
| `WORK` | `/var/lib/technitium-cert` | Scratch and last-synced copy |

`SRC_PATH` tracks the NPMplus certificate ID. If the certificate is recreated
in NPMplus it becomes `npm-16`, `npm-17` and so on, and this needs updating.

## Verifying

```sh
systemctl list-timers technitium-cert-sync.timer
openssl pkcs12 -in /etc/dns/ssl.pfx -passin pass: -nokeys | openssl x509 -noout -subject -dates -ext subjectAltName
```

Then check encrypted DNS actually serves it:

```sh
kdig -d +tls @ns1.dns.vaderrp.com google.com      # DoT, port 853
kdig -d +https @ns1.dns.vaderrp.com google.com    # DoH, port 443
```

`kdig` is in the `knot-dnsutils` package.

## Failure modes

- **A broken pull is invisible from the outside.** NPMplus issues Let's Encrypt
  *shortlived* certificates — 160 hours, renewed around day 4–5 — so a node
  stops serving a valid certificate within about a week of the sync breaking,
  not the 90 days a classic certificate would give. The Gatus checks on `:853`
  in `kubernetes/apps/observability/gatus/` exist for exactly this and are the
  reason a `48h` threshold is used rather than `240h`.
- **The script never clobbers a good bundle.** If the fetch fails or returns an
  empty file it exits non-zero without touching `/etc/dns/ssl.pfx`, leaving the
  previous certificate in place until the next run. Failures surface in
  `journalctl -u technitium-cert-sync`.
- **The `-legacy` OpenSSL flags** mirror the old in-cluster initContainer and
  are known to produce a bundle Technitium accepts. Modern PKCS#12 defaults may
  work on current .NET but have not been verified here.
