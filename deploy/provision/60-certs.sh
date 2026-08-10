#!/usr/bin/env bash
# The certificate store. Every box gets its OWN TLS certificate: self-signed by
# default, Let's Encrypt over DNS-01 when NAAF_ACME_ENABLED=1. The store is
# general-purpose — wstunnel is its first consumer, not its owner — so this step
# runs unconditionally and only its ACME half is gated. See docs/CERTS.md.
#
# Why a certificate at all when wstunnel ships one: the embedded certificate is
# compiled into the binary and byte-identical on every deployment in the world,
# which makes it a perfect fingerprint for anyone cataloguing TLS endpoints.
#
# THIS STEP MUST NEVER EXIT NON-ZERO. provision.sh turns any failed step into a
# fatal die, and this one runs after 50-bringup: a CA outage, an expired token,
# a typo in NAAF_ACME_DOMAINS or a missing DNS record would otherwise fail the
# whole deploy — including 65-wstunnel — over a certificate that has a perfectly
# good self-signed fallback sitting next to it. So there is no `die` below, only
# `warn` and `exit 0`, and the EXIT trap enforces that for anything added later.
#
# Why it runs AFTER 50-bringup: the name a certificate has to match is
# endpoint_host || endpoint_v4 read from the settings table, and endpoint_v4 is
# detected by bin/bootstrap.rb at step 50. The naaf.conf copies ship blank by
# design, so running earlier meant no name at all on a default bare-IP deploy.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
# shellcheck source=lib-certs.sh
source "$DIR/lib-certs.sh"
require_root

warn() { printf '[%s] WARN: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# ONE trap, doing both jobs. A second `trap … EXIT` would silently replace the
# first, and $CLONE_TMP is assigned only on the branch that installs acme.sh —
# hence the empty initialiser, so cleanup can never dereference an unset name
# under `set -u`.
CLONE_TMP=""
finish() {
  local rc=$?
  if [ -n "$CLONE_TMP" ]; then rm -rf "$CLONE_TMP"; fi
  if [ "$rc" -ne 0 ]; then
    warn "this step aborted with status $rc — certificates may be incomplete."
    warn "reporting success anyway: a certificate problem must never fail the"
    warn "deploy. deploy/verify.sh section 9 is what checks the store."
  fi
  exit 0
}
trap finish EXIT

log "certificate store at $NAAF_CERT_DIR"
install -d -o root -g root -m 0755 "$NAAF_CERT_DIR"

# Installed unconditionally, and before anything could need it: it is the
# extension point consumers rely on, deploy/verify.sh checks for it whether or
# not ACME is on, and a certificate dropped in by hand still wants a way to tell
# its consumers. Kept as .sh in the repo only so bin/ci's `deploy/*.sh` glob
# lints it; installed as a command, without the suffix.
log "installing $CERT_RELOAD_BIN"
install -o root -g root -m 0755 "$REPO_ROOT/deploy/naaf-cert-reload.sh" "$CERT_RELOAD_BIN"

# ── 1. which certificates ────────────────────────────────────────────────────
# One entry per certificate: "<san>[,<san>…]". SLUGS and NAMES stay index-parallel.
SLUGS=()
NAMES=()

add_cert() { # <comma-separated SAN list>
  local entry="$1" slug joined="" f i have existing
  local -a fields=() clean=() merged=()
  IFS=, read -r -a fields <<<"$entry"
  for f in "${fields[@]}"; do
    # Drop the fully-qualified trailing dot here as well as in cert_slug. This is
    # the SAN that reaches openssl and the CA, and a certificate SAN carries the
    # wire name: `DNS:vpn.example.com.` matches nothing and public CAs reject it.
    f="${f%.}"
    if [ -n "$f" ]; then clean+=("$f"); fi
  done
  if [ "${#clean[@]}" -eq 0 ]; then
    warn "ignoring an empty entry in NAAF_ACME_DOMAINS"
    return 0
  fi
  # A bad name costs its certificate and nothing else. cert_slug prints its own
  # reason; `if !` is what keeps its non-zero status away from `set -e`.
  if ! slug="$(cert_slug "${clean[0]}")"; then
    warn "skipping the certificate for '${clean[0]}' — unusable as a directory name"
    return 0
  fi
  # A slug collision is a MERGE, not a duplicate to drop, and that distinction is
  # the whole documented worked example. The endpoint is added first as its bare
  # name, so the operator's own
  #   NAAF_ACME_DOMAINS='vpn.example.com,*.vpn.example.com …'
  # entry — the exact spelling naaf.conf.example and docs/CERTS.md §5/§9 print —
  # computes the same slug. Dropping it silently threw the wildcard away and left
  # a certificate covering only the bare name, with a `log` line that read like a
  # benign no-op. Keep the recorded first SAN in place so the slug (and therefore
  # the store directory, and 65-wstunnel's independently derived copy of it) stays
  # stable, and append whatever is new. cert_self_signed compares against
  # $dir/sans and regenerates when a SAN appears, so the merge lands for free.
  for i in "${!SLUGS[@]}"; do
    if [ "${SLUGS[$i]}" = "$slug" ]; then
      IFS=, read -r -a merged <<<"${NAMES[$i]}"
      for f in "${clean[@]}"; do
        have=0
        for existing in "${merged[@]}"; do
          if [ "$existing" = "$f" ]; then have=1; break; fi
        done
        if [ "$have" -eq 0 ]; then merged+=("$f"); fi
      done
      printf -v joined '%s,' "${merged[@]}"
      NAMES[i]="${joined%,}"
      log "$slug also covers the SANs from '$entry' — now ${NAMES[$i]}"
      return 0
    fi
  done
  printf -v joined '%s,' "${clean[@]}"
  SLUGS+=("$slug")
  NAMES+=("${joined%,}")
}

# The endpoint's own certificate, from the settings table rather than naaf.conf:
# the database is authoritative and its NAAF_ENDPOINT_HOST copy ships blank, so
# this is the only place the answer actually exists. 65-wstunnel.sh makes the
# same read to derive the slug it serves — keep the two queries in step, because
# that agreement is the only thing making its certificate path resolve.
endpoint=""
if command -v sqlite3 >/dev/null 2>&1 && [ -r "$NAAF_DB" ]; then
  endpoint="$(sqlite3 "$NAAF_DB" \
    "select coalesce(nullif(endpoint_host,''), endpoint_v4) from settings limit 1" 2>/dev/null)" ||
    endpoint=""
fi
if [ -n "$endpoint" ]; then
  add_cert "$endpoint"
else
  # Skip it rather than invent a name: an empty slug resolves to the store root
  # and would put a TLS private key straight into $NAAF_CERT_DIR/key.pem.
  warn "no endpoint_host or endpoint_v4 in the settings table — no endpoint certificate"
fi

# A `*` is literal in a shell assignment, but this is the USE site, where an
# unquoted expansion globs against the filesystem. `set -f` covers the whole
# split — not just the `for` word — because a wildcard SAN is still expanded
# unquoted inside add_cert; `set +f` goes back on immediately after. That is
# what keeps *.vpn.example.com a name rather than a directory listing.
# Entries are space-separated, SANs comma-separated within an entry.
set -f
# shellcheck disable=SC2086 # deliberate word splitting; globbing is off
for entry in ${NAAF_ACME_DOMAINS}; do
  add_cert "$entry"
done
set +f

if [ "${#SLUGS[@]}" -eq 0 ]; then
  log "no certificate names could be derived — nothing to do"
  exit 0
fi

# ── 2. a usable key pair for every certificate, first and unconditionally ────
# Before any CA is contacted, so a consumer always has something to load even
# with ACME off, the token revoked, or Let's Encrypt down.
for i in "${!SLUGS[@]}"; do
  IFS=, read -r -a sans <<<"${NAMES[$i]}"
  if ! cert_ensure "${SLUGS[$i]}" "${sans[@]}"; then
    warn "could not prepare a key pair for ${SLUGS[$i]}"
  fi
done

# ── 3. ACME is opt-in; self-signed is a complete configuration ───────────────
if [ "$NAAF_ACME_ENABLED" != "1" ]; then
  log "NAAF_ACME_ENABLED is not 1 — self-signed certificates only"
  exit 0
fi

# ── 4. acme.sh, pinned to a commit ──────────────────────────────────────────
# Not `curl … | sh`: AGENTS.md forbids that for Ruby and the reason generalises.
# Not the release tarball either — acme.sh publishes no assets and no checksums,
# and GitHub's auto-generated tarballs are not byte-stable, so a pinned sha256
# would be a time bomb. A git commit is content-addressed, and checking it
# rather than trusting the tag is what makes moving the tag not enough.
install_acme_sh() {
  local got
  local -a args=(--install --home "$ACME_HOME")
  if [ -x "$ACME_HOME/acme.sh" ]; then
    log "acme.sh already installed at $ACME_HOME"
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    warn "git is not installed — cannot install acme.sh"
    return 1
  fi
  CLONE_TMP="$(mktemp -d)"
  log "cloning acme.sh $NAAF_ACME_SH_VERSION"
  # -c advice.detachedHead=false: cloning a tag is detached by definition, and
  # the twelve-line lecture git prints about it is noise in a provisioning log.
  if ! git -c advice.detachedHead=false clone --quiet --depth 1 \
    --branch "$NAAF_ACME_SH_VERSION" \
    https://github.com/acmesh-official/acme.sh "$CLONE_TMP/acme.sh"; then
    warn "could not clone acme.sh $NAAF_ACME_SH_VERSION"
    return 1
  fi
  got="$(git -C "$CLONE_TMP/acme.sh" rev-parse HEAD)" || got=""
  if [ "$got" != "$NAAF_ACME_SH_COMMIT" ]; then
    warn "acme.sh $NAAF_ACME_SH_VERSION is $got, not the pinned $NAAF_ACME_SH_COMMIT"
    warn "refusing to install it — the tag moved, or the clone is not what we pinned"
    return 1
  fi
  # An address only matters for the CA's expiry notices; acme.sh registers
  # without one. Do not pass an empty -m.
  if [ -n "$NAAF_ACME_EMAIL" ]; then
    args+=(-m "$NAAF_ACME_EMAIL")
  else
    warn "NAAF_ACME_EMAIL is empty — no expiry notices from the CA"
  fi
  log "installing acme.sh into $ACME_HOME"
  # --install is also what creates acme.sh's own daily renewal cron. We add no
  # timer of our own: one renewal owner, the same one that issued.
  if ! (cd "$CLONE_TMP/acme.sh" && HOME="${HOME:-/root}" ./acme.sh "${args[@]}"); then
    warn "acme.sh --install failed"
    return 1
  fi
}

if ! install_acme_sh; then
  warn "continuing with the self-signed certificates already in place"
  exit 0
fi
# Match the command, not the path: acme.sh writes the entry as
# `"/opt/acme.sh"/acme.sh --cron --home "/opt/acme.sh"`, quotes and all, so a
# grep for the plain path never matches and warns on a perfectly good install.
#
# Repair it rather than telling the operator to re-run, because re-running is a
# no-op: the cron entry is installed only inside `acme.sh --install`, and
# install_acme_sh above returns early the moment the binary exists. If cron was
# missing the first time this step ran (it is not in 10-packages.sh's apt list),
# the old advice looped forever — the same two warnings on every deploy, every
# CA-issued certificate silently expiring at 90 days, and verify.sh's
# `acme.sh renewal cron entry` check failing on every run, which makes
# ./deploy.sh exit 1 permanently. `--install-cronjob` is idempotent (it greps for
# an existing entry itself) and is the one command that actually fixes it.
if ! crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; then
  log "no acme.sh entry in root's crontab — installing the renewal cron job"
  if acme_run --install-cronjob >/dev/null 2>&1 &&
    crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; then
    log "acme.sh renewal cron job installed"
  else
    warn "could not install the acme.sh cron entry — certificates will NOT renew"
    warn "themselves. acme.sh needs a crontab: apt-get install cron, then re-run"
    warn "  ./deploy.sh --step 60-certs"
  fi
fi

# ── 5. the DNS credential ───────────────────────────────────────────────────
# Each plugin reads its own variable name, so the mapping is pinned here rather
# than guessed. An unknown plugin is not fatal: an operator can write the file
# by hand, and acme.sh saves credentials into its own account.conf after a first
# successful issue, which is the other way this can already be satisfied.
case "$NAAF_ACME_DNS_API" in
  dns_dnsimple) TOKEN_VAR=DNSimple_OAUTH_TOKEN ;;
  dns_cf) TOKEN_VAR=CF_Token ;;
  *) TOKEN_VAR="" ;;
esac

if [ -n "${NAAF_ACME_DNS_TOKEN:-}" ]; then
  if [ -z "$TOKEN_VAR" ]; then
    warn "no pinned variable name for $NAAF_ACME_DNS_API — write $ACME_ENV by hand"
    warn "(one KEY=value line, the name that plugin reads) and re-run this step"
    exit 0
  fi
  # 0600 root:root, NOT 0640 root:naaf the way litestream.env is. Litestream
  # runs as the naaf user and needs to read its credential; acme.sh runs as
  # root, and this one can rewrite DNS. /etc/naaf is 0750 root:naaf so the naaf
  # group can traverse in — the file mode is the entire barrier.
  # Single-quoted, with any embedded quote closed-escaped-reopened ('\''). This
  # file is `.`-sourced by root in acme_run, so an unquoted value is not a
  # quoting nicety: a token containing `$(…)` or `;` would EXECUTE. acme.sh
  # writes its own saved credentials the same way for the same reason.
  esc="${NAAF_ACME_DNS_TOKEN//\'/\'\\\'\'}"
  log "writing $ACME_ENV ($TOKEN_VAR for $NAAF_ACME_DNS_API)"
  (
    umask 077
    printf "%s='%s'\n" "$TOKEN_VAR" "$esc" >"$ACME_ENV"
  )
  chown root:root "$ACME_ENV"
  chmod 0600 "$ACME_ENV"
elif [ -s "$ACME_ENV" ]; then
  log "no NAAF_ACME_DNS_TOKEN in the environment — keeping the existing $ACME_ENV"
  chown root:root "$ACME_ENV"
  chmod 0600 "$ACME_ENV"
elif [ -n "$TOKEN_VAR" ] && [ -f "$ACME_HOME/account.conf" ] &&
  grep -q "^SAVED_$TOKEN_VAR=" "$ACME_HOME/account.conf"; then
  log "acme.sh already has a saved $TOKEN_VAR — no token needed this run"
else
  warn "no DNS API token: NAAF_ACME_DNS_TOKEN is unset and $ACME_ENV is empty."
  warn "pass it once —  export NAAF_ACME_DNS_TOKEN=…; ./deploy.sh --sync"
  warn "                ./deploy.sh --step 60-certs"
  warn "keeping the self-signed certificates. It never goes in naaf.conf: that"
  warn "file is EnvironmentFile= for the web app."
  exit 0
fi

# ── 6. prove the delegation before asking the CA ────────────────────────────
# A missing CNAME is a validation failure, and five of those lock production
# Let's Encrypt out for an hour. Checking costs one DNS query.
#
# One CNAME covers both vpn.example.com and *.vpn.example.com: they share the
# challenge name _acme-challenge.vpn.example.com, which is why the wildcard
# prefix is stripped rather than looked up.
delegation_ok() { # <first san>
  local san="$1" challenge want got
  [ -n "$NAAF_ACME_CHALLENGE_ALIAS" ] || return 0
  if ! command -v dig >/dev/null 2>&1; then
    warn "dig is not installed — cannot check the _acme-challenge delegation"
    return 0
  fi
  challenge="_acme-challenge.${san#\*.}"
  want="_acme-challenge.$NAAF_ACME_CHALLENGE_ALIAS"
  got="$(dig +short CNAME "$challenge" 2>/dev/null | head -1)" || got=""
  got="${got%.}"
  if [ "$got" = "$want" ]; then
    log "$challenge delegates to $want"
    return 0
  fi
  warn "$challenge does not CNAME to $want (got '${got:-nothing}')."
  warn "create that record, then re-run: ./deploy.sh --step 60-certs"
  return 1
}

# ── 7. issue ────────────────────────────────────────────────────────────────
for i in "${!SLUGS[@]}"; do
  IFS=, read -r -a sans <<<"${NAMES[$i]}"
  # No public CA issues for a bare address, so never spend a request on one. On a
  # default deploy the endpoint IS an address (endpoint_v4, no NAAF_ENDPOINT_HOST)
  # and it is added to this list unconditionally, so without this guard every
  # ACME-enabled bare-IP box hands the CA a `-d 1.2.3.4` it can only refuse, on
  # every single deploy. Same `*[!0-9.:]*` shape test cert_self_signed uses to
  # choose an IP: SAN over a DNS: one. deploy/verify.sh section 9 skips its
  # CA-issued assertion on exactly the same test.
  case "${SLUGS[$i]}" in
    *[!0-9.:]*) ;;
    *)
      log "${SLUGS[$i]} is a bare address — no CA can certify it, keeping the self-signed one"
      continue
      ;;
  esac
  if ! delegation_ok "${sans[0]}"; then
    warn "not asking the CA for ${SLUGS[$i]} — the self-signed certificate stays"
    continue
  fi
  if ! cert_acme_issue "${SLUGS[$i]}" "${sans[@]}"; then
    warn "no CA-issued certificate for ${SLUGS[$i]} — the self-signed one stays in place"
  fi
done

log "certificate store ready — inspect with: openssl x509 -in $NAAF_CERT_DIR/<name>/cert.pem -noout -subject -issuer -dates -ext subjectAltName"
exit 0
