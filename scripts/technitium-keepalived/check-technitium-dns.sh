#!/usr/bin/env bash
# Health check for keepalived's vrrp_script. Exit 0 while Technitium is
# answering, non-zero when it is not.
#
# Queries a *locally authoritative* name deliberately. Checking something like
# google.com would move the VIP during an internet outage, when both nodes are
# equally unable to resolve and moving it helps nobody.
set -Eeuo pipefail

readonly ZONE="${ZONE:-vaderrp.com}"

# Two independent tests, because either alone has been wrong here before.
#
# dig exits 9 when it gets no reply. An earlier version of this script wrapped
# the call in `|| true`, which discarded that — and because dig writes
# "communications error ... connection refused" to *stdout*, the output was
# non-empty too. Both halves of the test passed against a server that was not
# running, so the VIP never moved. A health check that cannot fail is worse
# than no health check.
if ! out="$(dig +short +time=2 +tries=1 @127.0.0.1 "${ZONE}" SOA 2>/dev/null)"; then
    exit 1
fi

# A real SOA answer begins with the MNAME — a hostname ending in a dot. This
# rejects dig's own diagnostics, which begin with ';'.
grep -qE '^[A-Za-z0-9_.-]+\.[[:space:]]' <<<"${out}"
