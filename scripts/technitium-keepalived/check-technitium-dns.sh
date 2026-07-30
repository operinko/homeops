#!/usr/bin/env bash
# Health check for keepalived's vrrp_script. Exit 0 while Technitium is
# answering, non-zero when it is not.
#
# Queries a *locally authoritative* name deliberately. Checking something like
# google.com would move the VIP during an internet outage, when both nodes are
# equally unable to resolve and moving it helps nobody.
set -Eeuo pipefail

readonly ZONE="${ZONE:-vaderrp.com}"

# dig exits non-zero on timeout, which set -e would turn into an unhelpful
# early exit — take the output and let the emptiness test decide instead.
answer="$(dig +short +time=2 +tries=1 @127.0.0.1 "${ZONE}" SOA 2>/dev/null || true)"

[[ -n "${answer}" ]]
