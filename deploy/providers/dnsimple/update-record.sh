#!/usr/bin/env bash
# Point the naaf endpoint FQDN at a box: upsert an A record (and AAAA if an IPv6
# is given) in the DNSimple zone. Idempotent — updates the record if it exists,
# creates it otherwise. Uses your active `dnsimple` auth context; never handles
# tokens directly.
#
#   dns/update-record.sh <ipv4> [ipv6]
# Env: NAAF_DNS_ZONE (required, e.g. example.com), NAAF_DNS_NAME (required, the
#      record name within the zone, e.g. vpn), NAAF_DNS_TTL (default 300).
# Zone and name have no defaults on purpose — a wrong guess would rewrite a live
# record in whichever zone the default named.
#
# "Never handles tokens directly" still holds, and it is worth being precise
# about why, now that there is a second DNSimple credential in the system. This
# script runs on your workstation against your own `dnsimple` CLI context; the
# deploy path carries no DNSimple credential at all.
#
# The ACME DNS-01 token (`docs/CERTS.md`) is a different credential with a
# different lifetime and a different home: it reaches the box once through
# `deploy.sh`'s secret channel as NAAF_ACME_DNS_TOKEN and lands in
# /etc/naaf/acme.env, 0600 root:root, where only acme.sh reads it. It is never a
# naaf.conf key — that file is `EnvironmentFile=` for the web app.
#
# It should also belong to a SEPARATE DNSimple account holding nothing but the
# delegation zone. DNSimple v2 issues User tokens (every account you belong to)
# or Account tokens (one whole account) and has no per-zone or per-record scope,
# so an Account token for the account that holds THIS zone would let a box
# compromise rewrite the endpoint record this script maintains. The account
# boundary is the containment — not the _acme-challenge CNAME, which only
# redirects the challenge.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
[ -f "$REPO/naaf.conf" ] && { set -a; . "$REPO/naaf.conf"; set +a; }

ZONE="${NAAF_DNS_ZONE:?set NAAF_DNS_ZONE, e.g. example.com}"
NAME="${NAAF_DNS_NAME:?set NAAF_DNS_NAME, e.g. vpn (yields vpn.example.com)}"
TTL="${NAAF_DNS_TTL:-300}"
IPV4="${1:?usage: update-record.sh <ipv4> [ipv6]}"
IPV6="${2:-}"

upsert() { # <type> <content>
  local type="$1" content="$2" id
  id="$(dnsimple zones records list "$ZONE" --all --json 2>/dev/null |
    jq -r --arg n "$NAME" --arg t "$type" '.data[] | select(.name==$n and .type==$t) | .id' | head -1)"
  if [ -n "$id" ]; then
    echo "updating $type $NAME.$ZONE (#$id) -> $content" >&2
    dnsimple zones records update "$ZONE" "$id" --content "$content" --ttl "$TTL" >/dev/null
  else
    echo "creating $type $NAME.$ZONE -> $content" >&2
    dnsimple zones records create "$ZONE" --type "$type" --name "$NAME" --content "$content" --ttl "$TTL" >/dev/null
  fi
}

upsert A "$IPV4"
[ -n "$IPV6" ] && upsert AAAA "$IPV6"
echo "done: $NAME.$ZONE -> A $IPV4${IPV6:+, AAAA $IPV6}" >&2
