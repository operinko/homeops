#!/usr/bin/env bash
# Pull the TLS bundle NPMplus holds and hand it to Technitium as PKCS#12.
#
# Runs on each Technitium LXC from a systemd timer. NPMplus is the only ACME
# client; the nodes never talk to Let's Encrypt or hold a Cloudflare token.
# The pull direction is deliberate — NPMplus holds no credential that can write
# to a DNS server, only the nodes hold a read-only one pointing back at it.
#
# Technitium reloads its bundle when the file's modification time changes, so
# the swap must be atomic and must only happen when the source actually changed.
set -Eeuo pipefail

# Host serving the bundle. The forced command in its authorized_keys pins the
# rsync root to /opt/npmplus/tls/certbot, so SRC_PATH is relative to that.
readonly SRC_HOST="${SRC_HOST:-root@npmplus}"
readonly SRC_PATH="${SRC_PATH:-live/npm-15}"

# Where Technitium expects the bundle. Must match Settings -> Optional Protocols
# -> TLS Certificate File Path, and must be identical on every node: clustering
# replicates that setting, so a node-specific path would break the other node.
readonly OUT="${OUT:-/etc/dns/ssl.pfx}"
readonly WORK="${WORK:-/var/lib/technitium-cert}"

log() { printf '%s %s\n' "$(date -Is)" "$*" >&2; }

main() {
    mkdir -p "${WORK}/new" "$(dirname "${OUT}")"

    # -L is required: live/ holds symlinks into ../../archive/, and preserving
    # them would land two dangling links on a host where that path is absent.
    if ! rsync -aL --delete -e 'ssh -o BatchMode=yes' \
        "${SRC_HOST}:${SRC_PATH}/" "${WORK}/new/"; then
        log "ERROR: could not fetch bundle from ${SRC_HOST}; leaving ${OUT} untouched"
        exit 1
    fi

    for f in fullchain.pem privkey.pem; do
        if [[ ! -s "${WORK}/new/${f}" ]]; then
            log "ERROR: ${f} missing or empty in fetched bundle; leaving ${OUT} untouched"
            exit 1
        fi
    done

    # A timer fires on schedule, not on renewal. Without this check every tick
    # would rewrite the bundle and trigger a pointless certificate reload.
    if [[ -f "${OUT}" ]] \
        && cmp -s "${WORK}/new/fullchain.pem" "${WORK}/current/fullchain.pem" 2>/dev/null \
        && cmp -s "${WORK}/new/privkey.pem" "${WORK}/current/privkey.pem" 2>/dev/null; then
        exit 0
    fi

    # Technitium takes PKCS#12 only. The legacy algorithms mirror what the old
    # in-cluster initContainer used and are known to produce a bundle it
    # accepts; modern defaults may work but have not been verified here.
    openssl pkcs12 -export -legacy \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -inkey "${WORK}/new/privkey.pem" \
        -in "${WORK}/new/fullchain.pem" \
        -out "${OUT}.tmp" -passout pass:

    chmod 0600 "${OUT}.tmp"

    # Rename rather than write in place: Technitium watches mtime, and an
    # in-place write risks it reading a partially written bundle. The rename is
    # atomic and refreshes the timestamp in one step, triggering the reload.
    mv "${OUT}.tmp" "${OUT}"

    rm -rf "${WORK}/current"
    mv "${WORK}/new" "${WORK}/current"

    local expiry
    expiry="$(openssl x509 -in "${WORK}/current/fullchain.pem" -noout -enddate)"
    log "installed new bundle at ${OUT} (${expiry})"
}

main "$@"
