#!/usr/bin/env bash
# Certificate store helpers. Sourced after 00-lib.sh, never executed: like that
# file it only defines functions and defaults.
#
# The store is shared infrastructure with exactly ONE owner — 60-certs.sh, the
# only thing that issues or renews — and any number of CONSUMERS, which register
# themselves against a certificate and inherit renewal for free. wstunnel is the
# first consumer, not the last (a hub-side TLS proxy for internal apps under
# *.vpn.example.com is the stated next one). It must never grow an ACME path of
# its own.
#
# A consumer calls cert_slug and cert_dir, ASSERTS the pair is already there, and
# calls cert_register — the shape 65-wstunnel.sh uses and docs/CERTS.md §9
# prescribes. It must NOT call cert_ensure: that one belongs to 60-certs.sh,
# which calls it for every name it is going to renew. A consumer calling it would
# mint a self-signed pair for a name that is not in NAAF_ACME_DOMAINS — a
# certificate nothing ever renews, which is worse than the missing-pair error it
# was trying to avoid. Missing pair means 60 has not run, or the name is not
# registered with it; both are for the operator to fix, not for a consumer to
# paper over.
#
#   $NAAF_CERT_DIR/                 0755 root:root
#     <slug>/                       0755 root:root   slug = first SAN, * → _wildcard
#       cert.pem                    0644 root:root   fullchain
#       key.pem                     0600 root:root
#       sans                        0644 root:root   the SAN list this cert covers
#       consumers.d/                0755 root:root
#         naaf-wstunnel.service     0644 root:root   empty marker
#
# The directory modes are a privilege boundary, not decoration. Write access to
# a consumers.d/ decides whether an unprivileged user can make root restart an
# arbitrary unit, and the store lives inside /etc/naaf, which is 0750 root:naaf
# so the service group can traverse into it — the modes below are the only
# barrier between the naaf uid and a TLS private key. That is why every node is
# re-pinned on every run instead of inheriting whatever umask was in force.

# These must agree with Naaf::Config::DEFAULTS in lib/naaf/config.rb. 00-lib.sh
# already defaults NAAF_CERT_DIR (60-certs.sh runs unconditionally, so it cannot
# be allowed to be unset under `set -u`); the ACME half is defaulted here so the
# functions below are safe to source from any step, including on a box whose
# /etc/naaf/naaf.conf predates this release and carries none of these keys.
: "${NAAF_CERT_DIR:=/etc/naaf/certs}"
: "${NAAF_ACME_ENABLED:=0}"
: "${NAAF_ACME_EMAIL:=}"
: "${NAAF_ACME_SERVER:=letsencrypt}"
: "${NAAF_ACME_DNS_API:=dns_dnsimple}"
: "${NAAF_ACME_CHALLENGE_ALIAS:=}"
: "${NAAF_ACME_DOMAINS:=}"
: "${NAAF_ACME_SH_VERSION:=3.1.4}"
: "${NAAF_ACME_SH_COMMIT:=3661fd86b6304115e42f43910e6dd452ab9866d6}"

# Where 60-certs.sh installs acme.sh and the reload helper. Consumers need the
# second path to build a --reloadcmd; nothing outside 60 uses the first.
ACME_HOME="${ACME_HOME:-/opt/acme.sh}"
CERT_RELOAD_BIN="${CERT_RELOAD_BIN:-/usr/local/sbin/naaf-cert-reload}"
ACME_ENV="${ACME_ENV:-/etc/naaf/acme.env}"

# Rejection is a `return 1`, never a `die`. 60-certs.sh must survive an operator
# typo in NAAF_ACME_DOMAINS — provision.sh turns any non-zero step into a fatal
# error, and 60 runs after the VPN is already up, so a bad domain name must cost
# you a certificate and never the deploy. Callers that genuinely cannot continue
# (65-wstunnel resolving the endpoint slug) get the same failure for free: an
# unhandled non-zero command substitution in an assignment trips `set -e`.
cert_err() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

# cert_slug <domain> — the directory name for the certificate whose first SAN is
# <domain>. A wildcard becomes the literal string _wildcard, so
# *.vpn.example.com is stored as _wildcard.vpn.example.com: nothing in the store
# then has to worry about a path that globs.
#
# This validates SHAPE, not just the character set, and the distinction is the
# whole point. `.` and `..` are built entirely from characters a charset check
# allows, so `cert_dir ..` would resolve to /etc/naaf and write a TLS private key
# there; `a/../..` escapes further; and a leading `-` survives a charset check
# and is then read as an option by the next command that sees the name. Reject
# all of those first, then require the conservative shape
# ^[A-Za-z0-9_]([A-Za-z0-9._-]*[A-Za-z0-9_])?$ — which every real hostname, IPv4
# literal and de-wildcarded name satisfies.
cert_slug() {
  local domain="${1:-}" name slug
  # A single trailing dot is the fully-qualified spelling of the very same name —
  # it is what `dig` prints, and so it is what an operator copy-pastes into
  # NAAF_ENDPOINT_HOST. lib/naaf/bootstrap.rb takes that variable verbatim
  # (`.to_s.strip`, no validation, unlike the settings UI), so `vpn.example.com.`
  # genuinely reaches the settings table and then this function. Rejecting it cost
  # 60-certs.sh its entire store — every name skipped, `exit 0`, nothing
  # generated — and then killed 65-wstunnel.sh on its `|| die`, failing every
  # deploy from then on. Normalise instead of refusing, so 60 and 65 derive the
  # SAME slug from the SAME database value, which is the agreement-by-construction
  # 65-wstunnel.sh relies on. Exactly one dot: `..` is still path traversal and is
  # still refused below.
  name="${domain%.}"
  slug="${name//\*/_wildcard}"
  case "$slug" in
    "" | . | ..) cert_err "cert_slug: refusing the degenerate name '$domain'"; return 1 ;;
    */*) cert_err "cert_slug: '$domain' contains a path separator"; return 1 ;;
    .*) cert_err "cert_slug: '$domain' starts with a dot"; return 1 ;;
    *..*) cert_err "cert_slug: '$domain' contains '..'"; return 1 ;;
    *[!A-Za-z0-9._-]*) cert_err "cert_slug: '$domain' has a character with no place in a path"; return 1 ;;
  esac
  # First and last character alphanumeric or underscore: a trailing dot or dash
  # is not a name anyone meant to type, and a leading dash is an option.
  case "$slug" in
    [A-Za-z0-9_] | [A-Za-z0-9_]*[A-Za-z0-9_]) ;;
    *) cert_err "cert_slug: '$domain' does not begin and end with an alphanumeric"; return 1 ;;
  esac
  printf '%s' "$slug"
}

# cert_dir <slug> — where that certificate lives. A pure string join on purpose:
# slugs are validated where they are minted (cert_slug) and re-validated at the
# one root-executed entry point into the store (naaf-cert-reload), which is the
# only place an unvalidated one could arrive from outside.
cert_dir() { printf '%s/%s' "$NAAF_CERT_DIR" "$1"; }

# cert_ensure <slug> <san…> — create the layout for one certificate and
# guarantee a usable key pair exists. 60-certs.sh's alone: it is the store's only
# owner, and it calls this for every name it is also going to renew. It never
# contacts a CA. A consumer does NOT call it (see the header) — a consumer adds
# its names to NAAF_ACME_DOMAINS and calls cert_register.
cert_ensure() {
  local slug="${1:-}" dir
  shift || true
  [ -n "$slug" ] && [ "$#" -gt 0 ] || { cert_err "cert_ensure: need a slug and at least one SAN"; return 1; }
  dir="$(cert_dir "$slug")"

  # Pin the mode of every node, not just the leaves: a 0777 parent makes a 0600
  # key.pem irrelevant, because anyone who can write the directory can replace
  # the file. `install -d` also re-applies mode and ownership to a directory
  # that already exists, which is what makes this a repair and not just a
  # creation.
  install -d -o root -g root -m 0755 "$NAAF_CERT_DIR"
  install -d -o root -g root -m 0755 "$dir"
  install -d -o root -g root -m 0755 "$dir/consumers.d"

  cert_self_signed "$slug" "$@" || return 1

  # Record what this certificate is meant to cover. cert_self_signed compares
  # against the previous contents to notice a SAN added to an existing entry, so
  # this write has to come after it.
  printf '%s\n' "$@" >"$dir/sans"
  chown root:root "$dir/sans"
  chmod 0644 "$dir/sans"
}

# cert_register <slug> <unit> — record that <unit> uses this certificate, so
# naaf-cert-reload restarts it after a renewal. Idempotent; the marker is empty
# and its name is the whole content.
cert_register() {
  local slug="${1:-}" unit="${2:-}" dir
  case "$unit" in
    "" | */* | *[!A-Za-z0-9@._-]*)
      cert_err "cert_register: '$unit' is not a usable systemd unit name"; return 1 ;;
  esac
  # naaf-cert-reload re-validates this on read and skips anything that is not a
  # unit it will restart. Checking here too turns a consumer's typo into an
  # immediate provisioning failure instead of a certificate that silently
  # renews without restarting anything.
  case "$unit" in
    *.service | *.socket | *.target) ;;
    *) cert_err "cert_register: '$unit' is not a .service, .socket or .target"; return 1 ;;
  esac
  dir="$(cert_dir "$slug")"
  [ -d "$dir/consumers.d" ] || { cert_err "cert_register: no certificate at $dir — run 60-certs.sh first"; return 1; }
  touch "$dir/consumers.d/$unit"
  chown root:root "$dir/consumers.d/$unit"
  chmod 0644 "$dir/consumers.d/$unit"
  log "$unit registered as a consumer of $slug"
}

# cert_self_signed <slug> <san…> — the floor every consumer can rely on. Called
# unconditionally and before any CA is contacted, so a box with ACME off, ACME
# broken, or a CA outage still has a working key pair. Regenerates only when
# there is nothing usable there.
cert_self_signed() {
  local slug="${1:-}" dir crt key cn san_list="" s subj errlog
  shift || true
  [ -n "$slug" ] && [ "$#" -gt 0 ] || { cert_err "cert_self_signed: need a slug and at least one SAN"; return 1; }
  dir="$(cert_dir "$slug")"
  crt="$dir/cert.pem"
  key="$dir/key.pem"
  cn="$1"

  if [ -s "$crt" ] && [ -s "$key" ]; then
    # Never touch a CA-issued certificate. acme.sh owns those files once it has
    # installed into them, and it renews on its own schedule — for Let's Encrypt
    # that is 60 days into a 90-day life, which is exactly the 30-days-left
    # threshold below. Without this test the two would race at that boundary and
    # a real certificate would be replaced by a self-signed one for a month.
    subj="$(openssl x509 -in "$crt" -noout -subject -issuer 2>/dev/null)" || subj=""
    if [ -n "$subj" ] && [ "$(printf '%s' "$subj" | sed -n 's/^subject=//p')" != "$(printf '%s' "$subj" | sed -n 's/^issuer=//p')" ]; then
      return 0
    fi
    # A SAN added to an existing entry keeps the slug and the expiry, so expiry
    # alone would never notice it. The recorded list is what makes that visible.
    if [ -f "$dir/sans" ] && [ "$(cat "$dir/sans")" = "$(printf '%s\n' "$@")" ] &&
      openssl x509 -in "$crt" -noout -checkend 2592000 >/dev/null 2>&1; then
      return 0
    fi
  fi

  for s in "$@"; do
    case "$s" in
      # A bare-IP deploy has no hostname to certify: the endpoint's own address
      # is the name, and an address belongs in an IP: SAN. A DNS: entry holding
      # an address matches nothing, which is the kind of failure you only find
      # with a client that actually verifies.
      *[!0-9.:]*) san_list="${san_list:+$san_list,}DNS:$s" ;;
      *) san_list="${san_list:+$san_list,}IP:$s" ;;
    esac
  done

  log "generating a self-signed certificate for $slug ($san_list)"
  # umask 077 so key.pem.tmp is never briefly world-readable inside a 0755
  # directory; the certificate is opened up again after the rename.
  #
  # openssl's chatter is held back and printed only if it fails. Left alone it
  # writes a bare `-----` to stderr, which in a provisioning log looks exactly
  # like the first line of a leaked PEM.
  errlog="$(mktemp)"
  if ! (
    umask 077
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -days 3650 -subj "/CN=$cn" \
      -addext "subjectAltName=$san_list" \
      -addext "basicConstraints=critical,CA:FALSE" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=serverAuth" \
      -keyout "$key.tmp" -out "$crt.tmp" >/dev/null 2>"$errlog"
  ); then
    rm -f "$key.tmp" "$crt.tmp"
    cat "$errlog" >&2
    rm -f "$errlog"
    cert_err "openssl could not generate a self-signed certificate for $slug"
    return 1
  fi
  rm -f "$errlog"

  # Rename into place so no consumer ever reads a half-written pair, key first:
  # a certificate without its key is the harmless order to be caught in.
  mv "$key.tmp" "$key"
  mv "$crt.tmp" "$crt"
  chown root:root "$key" "$crt"
  chmod 0600 "$key"
  chmod 0644 "$crt"
}

# cert_acme_issue <slug> <san…> — ask the CA for a real certificate and install
# it over the self-signed pair. Only 60-certs.sh calls this, and only after it
# has installed acme.sh and proved the DNS delegation.
cert_acme_issue() {
  local slug="${1:-}" dir rc=0
  shift || true
  [ -n "$slug" ] && [ "$#" -gt 0 ] || { cert_err "cert_acme_issue: need a slug and at least one SAN"; return 1; }
  dir="$(cert_dir "$slug")"

  local args=(--issue --dns "$NAAF_ACME_DNS_API" --server "$NAAF_ACME_SERVER")
  local s
  for s in "$@"; do args+=(-d "$s"); done
  if [ -n "$NAAF_ACME_CHALLENGE_ALIAS" ]; then
    args+=(--challenge-alias "$NAAF_ACME_CHALLENGE_ALIAS")
  fi
  # No --accept-tos: acme.sh 3.1.4 has no such flag (it always sends
  # termsOfServiceAgreed), and passing it prints `Unknown parameter` and issues
  # nothing at all.

  # A CHANGED CA MUST FORCE A RE-ISSUE. acme.sh decides whether to renew purely
  # on the existing certificate's expiry — it does not notice that --server now
  # names a different CA. So the documented "prove it on letsencrypt_test, then
  # flip to letsencrypt" workflow silently does nothing: acme.sh logs `Skipping.
  # Next renewal time is …`, --install-cert re-installs the SAME staging file,
  # and the step reports success. Observed exactly that on a live box, which then
  # kept serving a `(STAGING)` certificate that no client can validate while both
  # this step and deploy/verify.sh reported green.
  #
  # The test is on the CERTIFICATE, not on remembered history. A marker file
  # alone is not enough: the first run after this code lands has no marker, so
  # nothing forces, and the marker then gets written describing a file it did not
  # produce — it would record `letsencrypt` next to a staging certificate and be
  # confidently wrong forever after. Ask the file itself instead.
  #
  # Rule: when the configured CA is a real one, the installed certificate must
  # chain to a publicly trusted root. If it does not, it is either the
  # self-signed fallback or a staging certificate, and either way a re-issue is
  # exactly what is wanted. Self-correcting, and it fixes a box that is already
  # in the wrong state rather than needing one.
  local ca_now="$NAAF_ACME_SERVER" ca_was="" expect_trusted=1
  case "$NAAF_ACME_SERVER" in
    # acme.sh's own naming convention for its staging endpoints, plus any raw
    # directory URL pointing at one. A test CA is never publicly trusted, so
    # requiring a trusted chain there would force a re-issue on every run.
    *_test | *staging*) expect_trusted=0 ;;
  esac
  [ -r "$dir/ca" ] && ca_was="$(cat "$dir/ca" 2>/dev/null)"
  if [ -n "$ca_was" ] && [ "$ca_was" != "$ca_now" ]; then
    log "$slug was issued by '$ca_was' and NAAF_ACME_SERVER is now '$ca_now' — forcing a re-issue"
    args+=(--force)
  elif [ "$expect_trusted" -eq 1 ] && [ -s "$dir/cert.pem" ] &&
    ! openssl verify -untrusted "$dir/cert.pem" "$dir/cert.pem" >/dev/null 2>&1; then
    # acme.sh renews on expiry alone and never notices that --server now names a
    # different CA, so without this the documented "prove it on letsencrypt_test,
    # then flip to letsencrypt" path is a silent no-op: `Skipping. Next renewal
    # time is …`, --install-cert re-installs the same staging file, and the step
    # reports success. Observed on a live box.
    log "$slug does not chain to a trusted root but $ca_now is a production CA — forcing a re-issue"
    args+=(--force)
  fi

  log "acme.sh --issue for $slug ($*)"
  acme_run "${args[@]}" || rc=$?
  case "$rc" in
    0) ;;
    # RENEW_SKIP: the certificate exists and is not due yet. Fall through to
    # --install-cert anyway, which is idempotent and is what re-registers the
    # reload command if the store was rebuilt under an existing acme.sh state.
    2) log "$slug is not due for renewal — acme.sh skipped it" ;;
    *) cert_err "acme.sh --issue failed for $slug (status $rc)"; return 1 ;;
  esac

  # --install-cert copies with `cat >file`, which preserves the mode of an
  # existing file — that is why cert_self_signed's 0600 key.pem must already be
  # there, and why the same holds for every unattended renewal from acme.sh's
  # cron. The chmod below is the belt to that braces; naaf-cert-reload re-pins
  # both modes on every renewal as well.
  rc=0
  acme_run --install-cert -d "$1" \
    --key-file "$dir/key.pem" \
    --fullchain-file "$dir/cert.pem" \
    --reloadcmd "$CERT_RELOAD_BIN $slug" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cert_err "acme.sh --install-cert failed for $slug (status $rc)"
    return 1
  fi
  chown root:root "$dir/key.pem" "$dir/cert.pem"
  chmod 0600 "$dir/key.pem"
  chmod 0644 "$dir/cert.pem"
  # Record the CA that produced the file now on disk, so the next run can tell a
  # staging certificate from a production one without parsing acme.sh's state.
  # After --install-cert, never before: on any failure path above we return early
  # and the marker keeps describing the file that is actually installed.
  printf '%s\n' "$ca_now" >"$dir/ca"
  chmod 0644 "$dir/ca"
  log "installed a CA-issued certificate for $slug (CA: $ca_now)"
}

# Run acme.sh with the DNS credential in scope and nowhere else. The credential
# file is sourced inside this subshell, immediately before the command that
# needs it: an env file nothing sources is a silent no-op whose only symptom is
# an opaque validation failure against a rate-limited CA, and keeping it out of
# the calling shell's environment means it cannot leak into any other child.
# Each DNS plugin reads its OWN variable name (dns_dnsimple wants
# DNSimple_OAUTH_TOKEN, dns_cf wants CF_Token), which is why the file is
# free-form KEY=value written by 60-certs.sh rather than NAAF_ACME_DNS_TOKEN.
acme_run() {
  (
    set -a
    if [ -r "$ACME_ENV" ]; then
      # shellcheck source=/dev/null
      . "$ACME_ENV"
    fi
    set +a
    "$ACME_HOME/acme.sh" --home "$ACME_HOME" "$@"
  )
}
