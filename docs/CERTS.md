# Naaf — the certificate store

A box-local TLS certificate store: self-signed by default, Let's Encrypt over
DNS-01 when you turn it on. It exists because `naaf-wstunnel` needs a
certificate, but it is deliberately **not** wstunnel's — it is shared
infrastructure with exactly **one owner** (`deploy/provision/60-certs.sh`, the
only thing that ever issues or renews) and any number of **consumers**, which
register themselves against a certificate and inherit renewal for free.

wstunnel is the first consumer, not the last. The stated next one is a hub-side
TLS proxy for internal apps under `*.vpn.example.com`; §9 walks through adding it
and is explicitly **not yet built**.

If you only care about the transport, read [`WSTUNNEL.md`](WSTUNNEL.md) — this
file is the layer underneath it.

---

## 1. Why a certificate at all

wstunnel ships with one compiled into the binary. It is byte-identical on every
deployment in the world, which makes it a perfect fingerprint for anyone
cataloguing TLS endpoints. Every box gets its own instead, and the unit is
rendered with `--tls-certificate`/`--tls-private-key` so the embedded one is
never reached (`deploy/verify.sh` section 8 asserts exactly that).

A **self-signed** certificate is a complete, supported configuration. It gives
you a per-box fingerprint and an encrypted transport; what it does not give you
is a certificate a client can *verify*, so `NAAF_WSTUNNEL_TLS_VERIFY=auto`
correctly declines to verify against it. ACME is the upgrade, not the baseline.

---

## 2. Layout

```
/etc/naaf/certs/                    0755 root:root   $NAAF_CERT_DIR
  vpn.example.com/                  0755 root:root   slug = first SAN
    cert.pem                        0644 root:root   fullchain
    key.pem                         0600 root:root
    sans                            0644 root:root   one SAN per line
    consumers.d/                    0755 root:root
      naaf-wstunnel.service         0644 root:root   empty marker
  _wildcard.vpn.example.com/        ...              a `*` becomes _wildcard
/usr/local/sbin/naaf-cert-reload    0755 root:root
/etc/naaf/acme.env                  0600 root:root   the DNS API token
/opt/acme.sh/                                        acme.sh's own home
```

**The directory modes are the privilege boundary, not decoration.** `/etc/naaf`
is `0750 root:naaf`, so the service group can traverse into the store — the file
mode on `key.pem` is the only thing between the `naaf` uid and a TLS private key,
and a writable directory anywhere on the path would make it irrelevant (whoever
can write the directory replaces the file). Every node is re-pinned with
`install -d -o root -g root -m …` on every run rather than inheriting whatever
umask was in force, and `naaf-cert-reload` re-pins `cert.pem`/`key.pem` after
every renewal, attended or not.

**The slug.** The directory name is the certificate's first SAN with `*`
rewritten to the literal `_wildcard`, so nothing in the store is ever a path that
globs. `cert_slug` validates *shape*, not just the character set, because `.` and
`..` are built entirely out of allowed characters: `cert_dir ..` would otherwise
resolve to `/etc/naaf` and write a TLS private key there. A leading `-` is
rejected for the same class of reason — the next command that sees the name reads
it as an option.

**One trailing dot is stripped, not refused.** `vpn.example.com.` is the
fully-qualified spelling of the same name — it is what `dig` prints, so it is
what gets copy-pasted into `NAAF_ENDPOINT_HOST`, and `lib/naaf/bootstrap.rb`
takes that variable verbatim (the Settings UI is the only validated path into
`endpoint_host`). Refusing it cost the box its entire store: every name skipped,
`60-certs.sh` exiting 0 with nothing generated, and then `65-wstunnel.sh` dying
on its `|| die` — a deploy that failed on every subsequent run. The dot is
stripped in `cert_slug` **and** per-SAN in `add_cert`, because a certificate SAN
carries the wire name and `DNS:vpn.example.com.` matches nothing. Exactly one
dot: `..` is still path traversal and is still refused, as are `.`, `-x` and
`a/../b`.

---

## 3. What runs, and when

`60-certs.sh` is a normal provisioning step:

```
05-swap 10-packages 20-system 30-ruby 40-app 45-litestream 50-bringup 60-certs 65-wstunnel
```

**It runs after `50-bringup`, and that ordering is load-bearing.** The name a
certificate has to match is `endpoint_host || endpoint_v4` **from the settings
table** — the `naaf.conf` copies ship blank by design and `endpoint_v4` is
detected by `bin/bootstrap.rb` at step 50. Running certs earlier meant an empty
name on every default bare-IP deploy, an empty slug, a TLS key written into the
store root, and a failed step — which `provision.sh` turns into a fatal `die`,
so `50-bringup` would never run and the box would have no WireGuard interface
at all.

**It runs unconditionally; only its ACME half is gated.** And it **never exits
non-zero**: an `EXIT` trap forces `exit 0` and logs loudly if the body aborted.
A CA outage, an expired token, a typo in `NAAF_ACME_DOMAINS` or a missing DNS
record must cost you a certificate — never the deploy, and never the VPN that
is already up by the time this step starts. Every failure path in the store
`return`s or `warn`s; nothing in `lib-certs.sh` calls `die`.

`65-wstunnel.sh` *may* die, and does: it is the last step, the VPN is already up,
and a transport enabled against a certificate that does not exist is a silent
outage.

The order inside the step:

1. Create `$NAAF_CERT_DIR`; install `/usr/local/sbin/naaf-cert-reload`. Both
   happen before anything could need them and regardless of ACME — the reload
   helper is the extension point, `verify.sh` checks for it either way, and a
   certificate you drop in by hand still wants a way to tell its consumers.
2. Build the certificate list: the endpoint's own name from the settings table
   (`select coalesce(nullif(endpoint_host,''), endpoint_v4) from settings` —
   `65-wstunnel.sh` makes the same read to derive the slug it serves, and that
   agreement is the only thing that makes its certificate path resolve), then
   every entry in `NAAF_ACME_DOMAINS`. **Merged** by slug, not deduped (§5). If
   no name can be derived at all it is skipped with a warning rather than
   invented.
3. `cert_ensure` for every entry — **self-signed first and unconditionally**, so
   every consumer has a loadable pair even with ACME off, the token revoked, or
   Let's Encrypt down.
4. Stop here unless `NAAF_ACME_ENABLED=1`.
5. Install acme.sh (§4), write `/etc/naaf/acme.env` (§4), prove the delegation
   (§4), then issue per certificate — **skipping any slug that is a bare
   address**, because no public CA issues for one (§10, §11).

---

## 4. Turning ACME on

```
NAAF_ACME_ENABLED=1
NAAF_ACME_EMAIL=you@example.com
NAAF_ACME_SERVER=letsencrypt_test          # for the first run — see §6
NAAF_ACME_DNS_API=dns_dnsimple
NAAF_ACME_CHALLENGE_ALIAS=acme-vpn.example.net
```

```sh
export NAAF_ACME_DNS_TOKEN=...
./deploy.sh --sync                          # --step alone does NOT sync or install naaf.conf
./deploy.sh --step 60-certs
```

> None of the ACME half of this document has been run against a live CA. It is
> design-reviewed only, which is the other reason to start on
> `letsencrypt_test`.

### acme.sh itself: pinned to a tag *and* a commit

```
NAAF_ACME_SH_VERSION=3.1.4
NAAF_ACME_SH_COMMIT=3661fd86b6304115e42f43910e6dd452ab9866d6
```

`60-certs.sh` installs acme.sh into `/opt/acme.sh` from a **shallow git clone of
that tag**, then `rev-parse HEAD` and refuses to install anything whose commit is
not the pinned one. Bump the two keys together or the step declines and keeps the
self-signed certificates.

Why this shape and not the two obvious alternatives: `curl … | sh` is what
`AGENTS.md` forbids for Ruby and the reason generalises; and the release tarball
cannot be checksummed, because acme.sh publishes no assets and no checksums of
its own and GitHub's auto-generated tarballs are not byte-stable, so a pinned
`sha256` would be a time bomb. A git commit is content-addressed, and checking it
rather than trusting the tag is what makes *moving the tag* not enough.

The clone goes to a `mktemp -d` cleaned up by the step's `EXIT` trap, and the
install is skipped entirely once `/opt/acme.sh/acme.sh` exists.

**`--install` is also what creates the daily renewal cron entry**, and naaf adds
no timer of its own (§7). That entry is therefore the entire renewal mechanism,
and it needs a crontab: `cron` is **not** in `10-packages.sh`'s apt list, so on
an image without it the first `--install` silently produces no entry. `60-certs.sh`
checks for the entry on every run and repairs it with `acme.sh --install-cronjob`
(idempotent) rather than telling you to re-run the step — re-running is a no-op,
because the install short-circuits the moment the binary exists. If the repair
also fails, it says so and names the fix (`apt-get install cron`), and
`deploy/verify.sh`'s certificate section fails on the missing entry meanwhile.

### DNS-01, never HTTP-01

The challenge type is not configurable, and that is a feature. DNS-01 needs **no
inbound port** — no tcp/80, no socat, nothing binding a privileged port outside
the wstunnel unit. `verify.sh` asserts in *both* branches that tcp/80 is closed;
a rule there means someone reached for HTTP-01. DNS-01 also issues for names that
do not resolve to this box and for **wildcards**, which HTTP-01 cannot do at all
— which is what makes §9 possible.

### The token, and where it does not go

`NAAF_ACME_DNS_TOKEN` is **not** a `naaf.conf` key. `naaf.conf` is
`EnvironmentFile=` for `naaf.service`, so every key in it becomes an environment
variable of the tunnel-facing web application, and a credential that can rewrite
DNS has no business there. It travels through `deploy.sh`'s secret channel (the
same one that carries the admin password and the object-store keys) and
`60-certs.sh` writes it to `/etc/naaf/acme.env`.

That file is **`0600 root:root`, deliberately not `litestream.env`'s `0640
root:naaf`.** Litestream runs as the `naaf` user and needs to read its
credential; acme.sh runs as root, and `/etc/naaf` is traversable by the `naaf`
group — so the file mode is the entire barrier between the web application's uid
and a token that can rewrite your DNS.

**acme.sh does not read `NAAF_ACME_DNS_TOKEN`.** Each plugin reads its own
variable name, so `60-certs.sh` writes the file under a pinned mapping:

| `NAAF_ACME_DNS_API` | variable written to `acme.env` |
|---|---|
| `dns_dnsimple` | `DNSimple_OAUTH_TOKEN` |
| `dns_cf` | `CF_Token` |
| anything else | none — write the one line by hand and re-run the step |

The value is single-quoted with any embedded quote closed-escaped-reopened. That
is not a quoting nicety: the file is `.`-sourced by root immediately before
acme.sh runs, so an unquoted token containing `$(…)` or `;` would *execute*.

Three ways the credential can already be satisfied, in the order `60-certs.sh`
checks them: `NAAF_ACME_DNS_TOKEN` in the environment (rewrites the file); an
existing non-empty `acme.env` (kept, modes re-pinned); a `SAVED_<var>=` line in
`/opt/acme.sh/account.conf`, which acme.sh writes itself after a first success.
None of the three → warn, keep the self-signed certificates, `exit 0`.

### Delegation, and why a second provider account is the load-bearing part

Give the box a token and the box can rewrite DNS. The usual containment story is
`--challenge-alias`: put a CNAME in your real zone pointing the challenge name at
a throwaway zone, so validation happens somewhere harmless.

**That is not enough on its own, and DNSimple is the worked case.** DNSimple v2
issues *User* tokens (valid for every account you belong to) or *Account* tokens
(valid for one whole account). There is **no per-zone and no per-record scope**,
and `dns_dnsimple.sh` takes a plain `DNSimple_OAUTH_TOKEN`. So the CNAME redirects
where the *challenge* is answered while leaving the *token* able to reach every
zone in the account — including rewriting the endpoint's own `A` record and
minting DV certificates for any name you own.

Containment comes from the **account boundary**:

1. Register a **second DNSimple account**, separate from the one holding
   `example.com`.
2. Put a throwaway delegation zone in it — `acme-vpn.example.net`. Nothing else
   ever lives in this account.
3. In your **real** zone (first account), create
   `_acme-challenge.vpn.example.com  CNAME  _acme-challenge.acme-vpn.example.net`.
   **One CNAME covers both `vpn.example.com` and `*.vpn.example.com`** — they
   share a challenge name, which is why `60-certs.sh` strips the wildcard prefix
   before looking it up.
4. Generate an **Account token for the second account only** and pass it as
   `NAAF_ACME_DNS_TOKEN`.
5. `NAAF_ACME_CHALLENGE_ALIAS=acme-vpn.example.net`.

Now the redirect and the token scope line up and the blast radius of a box
compromise really is a zone you do not care about. **The second account is the
control. The CNAME is only what makes it usable.** The same reasoning applies to
any provider whose tokens are account-wide; check yours before assuming a
`--challenge-alias` bought you anything.

`60-certs.sh` verifies the CNAME with `dig` **before** contacting the CA, and
declines to issue that certificate if it is missing — five failed validations
lock production Let's Encrypt out for an hour, and checking costs one query. The
warning names the exact record to create. A missing `dig` is a warning, not a
block.

---

## 5. `NAAF_ACME_DOMAINS`

One **certificate** per space-separated entry; SANs **comma-separated** within an
entry. The endpoint's own certificate is always derived from the settings table
and does not go here.

```
NAAF_ACME_DOMAINS='vpn.example.com,*.vpn.example.com apps.example.com'
```

That is two certificates: `vpn.example.com` (slug `vpn.example.com`, covering
both the bare name and the wildcard) and `apps.example.com`.

- **Single-quote it.** `naaf.conf`'s grammar — the intersection of systemd
  `EnvironmentFile=`, `set -a; . file`, and `lib/naaf/config.rb` — rejects an
  unquoted value containing a space.
- **The `*` is literal.** No pathname expansion applies to a shell *assignment*,
  so all three readers take the string as written. The glob risk is at the *use*
  site, and `60-certs.sh` wraps the word-splitting loop in `set -f` / `set +f` for
  exactly that reason. Anything you add near that loop must stay inside it.
- **Leave it empty unless you mean it.** `naaf.conf.example` ships the sample
  commented out with the `#` in column 1; an uncommented one would ask a
  rate-limited CA for `example.com` on every deploy.
- A bad entry costs its certificate and nothing else: `cert_slug` refuses it,
  `60-certs.sh` warns and moves on to the next.
- The first SAN names the certificate. `'*.vpn.example.com,vpn.example.com'` and
  `'vpn.example.com,*.vpn.example.com'` are the same certificate stored under two
  different slugs — pick one spelling and keep it, or the store grows a duplicate.
- **A slug collision merges, it does not drop.** The endpoint's own name is added
  first, so the exact spelling above — whose first SAN *is* the endpoint host —
  computes a slug that already exists. `add_cert` appends the SANs that are new
  to the existing entry and keeps the recorded first SAN, so the slug (and
  therefore the store directory, and `65-wstunnel.sh`'s independently derived
  copy of it) stays put while the certificate grows the wildcard. Exact
  duplicates are a no-op. This is the behaviour §9's worked example depends on:
  dropping the entry instead left a certificate covering only the bare name,
  under a `log` line that read like a benign no-op.
- `cert_self_signed` compares the requested list against `<slug>/sans`, so a SAN
  added this way regenerates the pair on the next run even though the expiry has
  not moved.

---

## 6. Staging vs production

`NAAF_ACME_SERVER` is passed straight to acme.sh's `--server`, so any CA alias it
knows works. Two things to know:

**Start on `letsencrypt_test`.** Production Let's Encrypt locks you out for a
week after five failed validations against the same account, and the failures you
are most likely to hit — a missing CNAME, a token for the wrong account — are
exactly the ones that burn attempts.

**Switching to production is not just a config change.** acme.sh keeps
per-certificate state under `/opt/acme.sh/<first SAN>*/` and, once a certificate
exists and is not near expiry, `--issue` returns `RENEW_SKIP` (status 2).
`cert_acme_issue` treats that as success on purpose — it is how a rebuilt store
re-registers its reload command against an existing acme.sh — so flipping
`NAAF_ACME_SERVER` on its own can leave the **staging** certificate installed and
report success. Remove acme.sh's state for that name and re-run the step:

```sh
rm -rf /opt/acme.sh/vpn.example.com /opt/acme.sh/vpn.example.com_ecc
./deploy.sh --step 60-certs
```

**`verify.sh` will not catch this for you.** Section 9's CA-issued check asserts
that the issuer differs from the subject — a staging certificate passes it
happily. Read the issuer yourself:

```sh
openssl x509 -in /etc/naaf/certs/vpn.example.com/cert.pem -noout -subject -issuer -dates
```

`(STAGING) Let's Encrypt` in the issuer means clients that verify will reject it.

---

## 7. `consumers.d/` — the extension point

A consumer is any unit that loads a certificate out of the store. It registers a
marker and gets renewal handling for free:

```
/etc/naaf/certs/<slug>/consumers.d/<unit>     empty file, 0644 root:root
```

On renewal, acme.sh runs the `--reloadcmd` that `cert_acme_issue` installed:

```
/usr/local/sbin/naaf-cert-reload <slug>
```

which re-pins the file modes and `systemctl restart`s every unit named by a
marker. A marker naming a unit that is not installed is skipped with a log line,
not an error — a consumer you turned off must not make every future renewal
report failure.

**`restart`, not `reload`, and that is forced by `LoadCredential=`.** Consumer
units read the pair through systemd credentials so the key can stay `0600
root:root` with no persistent uid able to read it — but the credential directory
is a **start-time snapshot**, so a running process cannot see a renewal any other
way. Sub-second, roughly every 60 days; WireGuard re-handshakes within 5 s.

**`naaf-cert-reload` trusts nothing, and the reasons are specific.** It runs as
root, unattended, from cron, with an argument that came out of a config file
acme.sh wrote. So it re-validates `$1` with the same shape check that minted the
slug (rather than trusting its caller), and it treats the contents of
`consumers.d/` as untrusted names: only `*.service`, `*.socket` and `*.target`
are acted on, only `[A-Za-z0-9@._-]`, and always `systemctl restart -- "$u"`.
Without that filter one file named `--now` turns a certificate renewal into a
root-chosen `systemctl` invocation. It is also deliberately self-contained — it
does not source `lib-certs.sh`, because it must keep working while `/opt/naaf` is
mid-`rsync`.

**Write access to a `consumers.d/` decides whether an unprivileged user can make
root restart an arbitrary unit.** That is why the directory is `0755 root:root`
and why `verify.sh` reports anything else in there as a finding rather than as
noise.

Renewal itself is acme.sh's own daily cron entry, created at `--install` time and
repaired with `--install-cronjob` on any later run that finds it missing (§4).
Naaf adds **no timer of its own**: one renewal owner, the same one that issued.

---

## 8. `lib-certs.sh` — the function contract

Sourced after `00-lib.sh`, never executed. Every function reports to stderr and
**`return`s non-zero**; none of them exits, so the caller decides whether a
failure is fatal. `60-certs.sh` decides it never is; `65-wstunnel.sh` decides it
always is, and turns the bare non-zero into a `|| die` naming the step.

| function | contract |
|---|---|
| `cert_slug <domain>` | prints the directory name (`*` → `_wildcard`, one trailing dot stripped); non-zero and a reason on any name that is not a safe path component |
| `cert_dir <slug>` | prints `$NAAF_CERT_DIR/<slug>`. A pure string join — validation happens where slugs are *minted*, and again at the one root-executed entry point |
| `cert_ensure <slug> <san…>` | creates the layout with pinned modes, guarantees a usable pair via `cert_self_signed`, writes `sans`. **Never contacts a CA. `60-certs.sh`'s alone — a consumer must not call it** (below) |
| `cert_register <slug> <unit>` | idempotent marker in `consumers.d/`; refuses a name that is not `[A-Za-z0-9@._-]` or does not end `.service`/`.socket`/`.target`; refuses a slug with no certificate directory |
| `cert_self_signed <slug> <san…>` | EC P-256, 3650 days, `CN=<first SAN>`, one `subjectAltName` covering every SAN. Regenerates only when needed (below) |
| `cert_acme_issue <slug> <san…>` | `--issue` then `--install-cert` with the `--reloadcmd`. **Only `60-certs.sh` calls this** |

**What a consumer calls, in order:** `cert_slug` → `cert_dir` → assert
`cert.pem`/`key.pem` are both there → `cert_register`. That is the shape
`65-wstunnel.sh` uses and the one §9 prescribes, and `cert_ensure` is
deliberately not in it. A consumer calling `cert_ensure` would mint a self-signed
pair for a name that is not in `NAAF_ACME_DOMAINS` — a certificate nothing ever
renews, which is strictly worse than the missing-pair error it was papering over.
A missing pair means `60-certs.sh` has not run or the name is not registered with
it; both are for the operator to fix.

`cert_self_signed` leaves an existing pair alone when either:

- the certificate's **issuer differs from its subject** — that is a CA-issued
  certificate and acme.sh owns those files. Without this test the two would race
  at exactly the wrong boundary: Let's Encrypt renews at 60 days of a 90-day
  life, which is the same instant as the 30-days-left threshold below, and a real
  certificate would be replaced by a self-signed one for a month; or
- the recorded `sans` file matches the requested list **and**
  `openssl x509 -checkend 2592000` passes. The `sans` comparison is what notices
  a SAN *added* to an existing entry, which keeps the slug and the expiry and
  would otherwise be invisible.

SANs are split by shape: anything containing a character outside `0-9.:` becomes
`DNS:`, everything else becomes `IP:`. A bare-IP deploy has no hostname to
certify, and a `DNS:` entry holding an address matches nothing — the kind of
failure you only find with a client that actually verifies.

Writes go to a `.tmp` name under `umask 077` and are renamed into place, key
first: a certificate without its key is the harmless order to be caught in.
openssl's chatter is held back and printed only on failure, because left alone it
writes a bare `-----` to stderr, which in a provisioning log looks exactly like
the first line of a leaked PEM.

---

## 9. Worked example — a second consumer for `*.vpn.example.com`

> **Not built.** No such proxy exists in this repo. This section is the shape the
> store was designed around, written out so the next consumer does not grow a
> second ACME path — which is the one thing that would make this store worse than
> no store at all. Treat it as a design sketch, not a runbook.

Goal: a hub-side TLS proxy serving internal apps at `grafana.vpn.example.com`,
`status.vpn.example.com`, … over the tunnel, on one wildcard certificate.

**Step 1 — ask for the names.** The wildcard rides along on the endpoint
certificate, so there is one certificate and one CNAME:

```
NAAF_ACME_DOMAINS='vpn.example.com,*.vpn.example.com'
```

```sh
./deploy.sh --sync && ./deploy.sh --step 60-certs
```

Nothing about `60-certs.sh` changes. The delegation already in place covers the
wildcard: `_acme-challenge.vpn.example.com` is the challenge name for **both**
SANs.

Confirm before going further:

```sh
openssl x509 -in /etc/naaf/certs/vpn.example.com/cert.pem -noout -ext subjectAltName
#   DNS:vpn.example.com, DNS:*.vpn.example.com
```

**Step 2 — the consumer's provisioning step**, `deploy/provision/70-proxy.sh`,
added to the `STEPS` array in **both** `deploy.sh` and
`deploy/provision/provision.sh` after `65-wstunnel`:

```sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-lib.sh
source "$DIR/00-lib.sh"
# shellcheck source=lib-certs.sh
source "$DIR/lib-certs.sh"
require_root

[ "$NAAF_PROXY_ENABLED" = "1" ] || {
  log "NAAF_PROXY_ENABLED is not 1 — skipping"
  systemctl disable --now naaf-proxy 2>/dev/null || true   # bare form exits non-zero
  exit 0
}

# The same name 60-certs.sh derived, derived the same way, so the slugs agree by
# construction rather than by a string written down twice.
ENDPOINT="$(sqlite3 "$NAAF_DB" \
  "select coalesce(nullif(endpoint_host,''), nullif(endpoint_v4,''), '') from settings")"
SLUG="$(cert_slug "$ENDPOINT")" || die "no certificate name for '$ENDPOINT'"
CERT_PATH="$(cert_dir "$SLUG")"
[ -f "$CERT_PATH/cert.pem" ] && [ -f "$CERT_PATH/key.pem" ] ||
  die "no certificate pair under $CERT_PATH — run 60-certs.sh first"

cert_register "$SLUG" naaf-proxy.service || die "could not register as a consumer"
# … render the unit with __NAAF_CERT_PATH__ = $CERT_PATH, grep -q '__NAAF_' && die,
# install 0644 root:root, systemctl daemon-reload, enable, restart.
```

**Step 3 — the unit reads the pair as a credential**, never by path:

```ini
[Service]
Type=exec
DynamicUser=yes
LoadCredential=tls-cert:__NAAF_CERT_PATH__/cert.pem
LoadCredential=tls-key:__NAAF_CERT_PATH__/key.pem
ExecStart=/usr/local/bin/naaf-proxy --cert %d/tls-cert --key %d/tls-key …
```

systemd reads both files as root and exposes them to this service only, so
`key.pem` stays `0600 root:root` and no persistent uid can read it. `DynamicUser`
rather than `User=naaf`: a proxy compromise must not land inside the uid that
owns `naaf.db` (the server private key and the admin hash).

That is the whole integration. `naaf-cert-reload` picks up the new marker with no
change to anything, and renewal restarts the proxy alongside wstunnel.

**What a consumer must never do:**

- **Call `cert_acme_issue`, or talk to a CA at all.** Names go in
  `NAAF_ACME_DOMAINS`; issuance is `60-certs.sh`'s and nothing else's.
- **Call `cert_ensure`.** Same reason one step earlier: it would create a store
  directory and a self-signed pair for a name `60-certs.sh` never registered, so
  nothing would ever renew it. Assert the pair and `die`; do not create it.
- **Add a renewal timer.** acme.sh's cron is the one renewal owner.
- **Write into another certificate's directory**, or into `consumers.d/` for any
  unit but its own.
- **Open an inbound port for validation.** DNS-01 needs none; tcp/80 stays shut.
- **Run as the `naaf` user**, or read the key by path instead of through
  `LoadCredential=`.

---

## 10. Checking it

`./deploy.sh --verify` covers the store in section 9, unconditionally: directory
and file modes, owners, `cert.pem` valid for at least another week,
`naaf-cert-reload` present and `0755 root:root`, every unit named in a
`consumers.d/` actually installed, and — with `NAAF_ACME_ENABLED=1` — that the
certificate is CA-issued rather than the self-signed fallback still sitting there,
that acme.sh's cron entry exists, and that `acme.env` is `0600 root:root`.

**The CA-issued assertion skips a slug that is a bare address**, and so does the
issue loop in `60-certs.sh`: the default deploy has no `NAAF_ENDPOINT_HOST`, so
the endpoint is `endpoint_v4` and no public CA issues over DNS-01 for an address.
It reports `self-signed by design` instead. Without that both halves misfired in
the same way on every ACME-enabled bare-IP box — a `-d 1.2.3.4` spent on the CA
on every deploy, and a section-9 failure that could never be cleared, which
`deploy.sh` runs without `|| true` and therefore turned into a permanently failing
deploy. An empty store is likewise a `note`, naming the two ways to get one.

By hand:

```sh
openssl x509 -in /etc/naaf/certs/<slug>/cert.pem -noout -subject -issuer -dates -ext subjectAltName
ls -l /etc/naaf/certs/<slug>/consumers.d/          # who gets restarted on renewal
/usr/local/sbin/naaf-cert-reload <slug>            # exercise the reload path
crontab -l | grep acme.sh                          # the entire renewal mechanism
/opt/acme.sh/acme.sh --home /opt/acme.sh --list    # what acme.sh thinks it owns
```

From a client, to prove the served certificate is the box's own and not
wstunnel's embedded one:

```sh
openssl s_client -connect vpn.example.com:443 </dev/null 2>/dev/null |
  openssl x509 -noout -subject -issuer -fingerprint
```

---

## 11. Things that will bite you

- **`--step` alone neither syncs the repo nor installs `naaf.conf`.** Every
  recipe here that edits `naaf.conf` starts with `./deploy.sh --sync`. Skip it
  and you re-run the step against the old configuration and wonder why nothing
  changed.
- **`NAAF_ACME_*` are `naaf.conf` keys, so exporting them does nothing.** Both
  `deploy.sh` on your workstation and `00-lib.sh` on the box do
  `set -a; . naaf.conf`, which clobbers whatever you exported. Only
  `NAAF_ACME_DNS_TOKEN` travels by export, because it is deliberately *not* a
  key in that file.
- **Turning wstunnel off does not remove the store.** `65-wstunnel.sh` leaves
  `$NAAF_CERT_DIR` alone on purpose — it belongs to `60-certs.sh` and its other
  consumers, and the marker in `consumers.d/` stays so a re-enable is a no-op.
  Delete markers by hand if you mean it.
- **A `warn` in `60-certs.sh` is not a failed deploy, by design.** The step
  always reports success. If you want to know whether the CA actually answered,
  read the step's log or run `--verify`; do not read the exit status.
- **`sans` is written after the pair, not before.** `cert_self_signed` compares
  against the *previous* contents to notice a SAN added to an existing
  certificate, so anything that rewrites that file early defeats the check.
- **A self-signed certificate expiring is a ten-year problem, a CA-issued one is
  a 90-day problem.** `verify.sh`'s week of slack is tuned for the second: with
  acme.sh renewing at 60 days, "under 7 days left" means renewal has been failing
  silently for about a month.
- **`NAAF_ACME_ENABLED=1` on a bare-IP box gets you nothing, by design.** There
  is no hostname to certify, so the endpoint's certificate stays self-signed and
  both `60-certs.sh` and `verify.sh` say so and move on. Set `NAAF_ENDPOINT_HOST`
  (or a name in the Settings UI) first — that value is also the certificate's
  name and `65-wstunnel.sh`'s slug.
- **`cron` is not in `10-packages.sh`'s apt list.** acme.sh's renewal entry needs
  a crontab; `60-certs.sh` repairs a missing entry itself (§4), but on an image
  with no cron at all the repair fails and says so, and every CA-issued
  certificate on that box expires at 90 days. `crontab -l | grep acme.sh` is the
  one-line check.
- **Changing `endpoint_host` renames the certificate.** The slug is derived from
  it, so the next `60-certs.sh` run mints a *new* directory and leaves the old
  one behind, unrenewed — and `65-wstunnel.sh` will `die` until that run has
  happened. Re-run `60-certs` before `65-wstunnel`, and delete the stale
  directory by hand.
