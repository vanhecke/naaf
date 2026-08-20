# frozen_string_literal: true

# The single source of truth for every process-level default.
#
# Deliberately require-free. bin/naaf-helper runs as root and loads this file via
# require_relative, so it must never pull in Sequel, Roda, or any gem — that is
# what keeps the privileged process a small auditable thing with no gem surface.
# bin/ci asserts this file contains no `require` line. Do not add one.
#
# Values resolve in this order:
#   1. the process environment  (systemd EnvironmentFile, a shell export, a test)
#   2. the first readable naaf.conf found  (see SEARCH)
#   3. DEFAULTS
#
# The file is a *source of environment*, never a runtime dependency: under systemd
# the same file is already loaded as EnvironmentFile=, so a missing or unreadable
# naaf.conf is not an error.
module Naaf
  module Config
    DEFAULTS = {
      # identity
      "NAAF_USER" => "naaf",
      "NAAF_GROUP" => "naaf",

      # paths
      "NAAF_APP_DIR" => "/opt/naaf",
      "NAAF_STATE_DIR" => "/var/lib/naaf",
      "NAAF_DB" => "/var/lib/naaf/naaf.db",
      "NAAF_RUN_DIR" => "/run/naaf",
      "NAAF_HELPER_SOCKET" => "/run/naaf/helper.sock",
      "NAAF_WG_CONF_DIR" => "/etc/wireguard",
      "NAAF_LOG_DIR" => "/var/log/naaf-provision",

      # listen / session
      "NAAF_WEB_PORT" => "8080",
      "NAAF_DNS_PORT" => "53",
      "NAAF_DNS_UPSTREAM_TIMEOUT" => "4",
      "NAAF_RECONCILE_INTERVAL" => "30",
      "NAAF_SESSION_SECRET" => nil, # required; no sane default exists
      "NAAF_SESSION_COOKIE" => "naaf.session",
      "NAAF_SESSION_DAYS" => "7",

      # dashboard metrics (in-memory only; nothing here touches the database)
      "NAAF_METRICS_INTERVAL" => "2",
      "NAAF_METRICS_HISTORY" => "180",
      "NAAF_METRICS_SSE" => "1",
      "NAAF_METRICS_POLL_INTERVAL" => "5",
      "NAAF_METRICS_DNS_NAMES" => "1",

      # first-boot seeds for the settings table (the DB wins after first boot)
      "NAAF_WG_INTERFACE" => "wg0",
      "NAAF_WG_SUBNET" => "10.8.0.0/24",
      "NAAF_SERVER_IP" => "10.8.0.1",
      "NAAF_LISTEN_PORT" => "51820",
      "NAAF_WAN_INTERFACE" => "eth0",
      "NAAF_DNS_UPSTREAM" => "1.1.1.1",
      "NAAF_DNS_DOMAIN" => "vpn",
      "NAAF_MTU" => "1420",
      "NAAF_ENDPOINT_HOST" => nil,
      # Normally auto-detected at bootstrap. Set these only when detection cannot
      # work (no outbound HTTP, or the box is behind NAT and its public address
      # is not the one it sees).
      "NAAF_ENDPOINT_V4" => nil,
      "NAAF_ENDPOINT_V6" => nil,

      # backups
      "NAAF_BACKUP_ENABLED" => "1",
      "NAAF_BACKUP_DIR" => "/var/lib/naaf/backups",
      "NAAF_BACKUP_INTERVAL" => "3600",
      "NAAF_BACKUP_KEEP" => "24",

      # litestream (shape only — credentials live in /etc/naaf/litestream.env)
      "NAAF_LITESTREAM_ENABLED" => "0",
      "NAAF_LITESTREAM_VERSION" => "0.5.16",
      "NAAF_LITESTREAM_REPLICA_TYPE" => "file",
      "NAAF_LITESTREAM_PATH" => "/var/lib/naaf/replica",
      "NAAF_LITESTREAM_BUCKET" => nil,
      "NAAF_LITESTREAM_PREFIX" => "naaf",
      "NAAF_LITESTREAM_REGION" => nil,
      "NAAF_LITESTREAM_ENDPOINT" => nil,
      "NAAF_LITESTREAM_SNAPSHOT_INTERVAL" => "24h",
      "NAAF_LITESTREAM_SNAPSHOT_RETENTION" => "168h",

      # wstunnel — WireGuard inside a TLS WebSocket, for networks that pass only
      # tcp/443. Off by default: an open 443 with nothing behind it is an
      # advertisement, so the firewall rule, the unit and the client flavors all
      # appear together or not at all.
      #
      # These are naaf.conf keys and NOT settings-table columns on purpose. The
      # port has to match the systemd unit AND /etc/nftables.conf, both rendered
      # from naaf.conf at provisioning time; a database copy would be a second
      # source of truth that can drift. The *host* clients dial stays in settings.
      #
      # NAAF_WSTUNNEL_PATH_PREFIX is deliberately absent. deploy/install-config.sh
      # iterates the INCOMING file only, so a key present on the box but missing
      # from the operator's copy is dropped, re-appended empty by 40-app.sh, and
      # regenerated — a silent outage for every split-ws config ever issued. It
      # lives in /etc/naaf/wstunnel.env, written by 65-wstunnel.sh and pulled into
      # naaf.service's environment by an EnvironmentFile=, so Config[] still
      # finds it via ENV.
      "NAAF_WSTUNNEL_ENABLED" => "0",
      "NAAF_WSTUNNEL_VERSION" => "10.6.2",
      "NAAF_WSTUNNEL_PORT" => "443",
      # Fleet-wide cover name for --tls-sni-override. Empty is already correct:
      # dialing wss://<endpoint>:443 puts the endpoint on the wire as SNI. Set it
      # only to show an inspecting firewall a name in a category it does not
      # decrypt. No per-client value — wstunnel's server never inspects SNI.
      "NAAF_WSTUNNEL_SNI" => nil,
      # auto | on | off. auto verifies when ACME is on and no SNI override is
      # set, i.e. exactly when the dialed name and the served certificate agree.
      "NAAF_WSTUNNEL_TLS_VERIFY" => "auto",
      # Breaks the DNS deadlock: the ws flavors point DNS at the tunnel's own
      # resolver, but wstunnel must resolve the endpoint BEFORE that tunnel can
      # exist. Set it to "off" to omit the flag (NOT blank — blank means "unset"
      # and falls through to this default). It sends udp/53 to a public resolver,
      # which the networks these flavors target may block; there, use a
      # split-ws-nodns config, which never repoints DNS at all.
      "NAAF_WSTUNNEL_DNS_RESOLVER" => "dns://1.1.1.1",

      # certificates — a general-purpose store owned by 60-certs.sh. Not
      # namespaced under wstunnel: wstunnel is its first consumer, not its owner,
      # and consumers register in <cert>/consumers.d/ rather than growing a
      # second ACME path. Self-signed by default and that is complete; ACME is
      # DNS-01 only, so no inbound port is ever opened.
      "NAAF_CERT_DIR" => "/etc/naaf/certs",
      "NAAF_ACME_ENABLED" => "0",
      "NAAF_ACME_EMAIL" => nil,
      "NAAF_ACME_SERVER" => "letsencrypt",
      "NAAF_ACME_DNS_API" => "dns_dnsimple",
      "NAAF_ACME_CHALLENGE_ALIAS" => nil,
      # Space-separated certificates, comma-separated SANs within one. The DNS
      # API token is NOT a key here — naaf.conf is EnvironmentFile= for the web
      # app, and a credential that can rewrite DNS has no business in that
      # process. It reaches /etc/naaf/acme.env (0600 root:root) through
      # deploy.sh's secret channel instead.
      "NAAF_ACME_DOMAINS" => nil,
      # acme.sh is installed from a git clone pinned to the tag AND asserted
      # against the commit that tag pointed at, because a tag can be moved and a
      # commit SHA is content-addressed. Not `curl | sh`, and not the release
      # tarball: acme.sh publishes no assets and GitHub's generated ones are not
      # byte-stable, so a pinned sha256 would be a time bomb. Bump both together.
      "NAAF_ACME_SH_VERSION" => "3.1.4",
      "NAAF_ACME_SH_COMMIT" => "3661fd86b6304115e42f43910e6dd452ab9866d6",

      # deploy (workstation-side; stripped before the file is installed on a box)
      "NAAF_SSH_HOST" => nil,
      "NAAF_SSH_USER" => "root",
      "NAAF_SSH_KEY" => nil,
      "NAAF_RUBY_VERSION" => "4.0.6",
      "NAAF_RV_VERSION" => "0.6.0",
      "NAAF_SWAP_GB" => "2",
      "NAAF_PROVIDER" => nil,
      "NAAF_DNS_PROVIDER" => nil
    }.freeze

    # Keys a complete naaf.conf.example may legitimately omit.
    #   NAAF_ADMIN_PASSWORD is consumed once at bootstrap and hashed into the DB;
    #     the plaintext must not sit on disk, so it is never written to the file.
    #   NAAF_RUBY_PREFIX is derived from NAAF_RUBY_VERSION by
    #     deploy/provision/00-lib.sh. Writing it in the file would shadow the
    #     version, so bumping NAAF_RUBY_VERSION alone would silently do nothing.
    #     No Ruby code reads it — only the provisioning shell does.
    OPTIONAL = ["NAAF_ADMIN_PASSWORD", "NAAF_RUBY_PREFIX"].freeze

    # settings-table column => the naaf.conf key that seeds it on first boot.
    # After first boot the DB is authoritative; these exist so bin/naaf can warn
    # when the two disagree.
    SEEDS = {
      wg_interface: "NAAF_WG_INTERFACE",
      wg_subnet: "NAAF_WG_SUBNET",
      server_ip: "NAAF_SERVER_IP",
      listen_port: "NAAF_LISTEN_PORT",
      wan_interface: "NAAF_WAN_INTERFACE",
      dns_upstream: "NAAF_DNS_UPSTREAM",
      dns_domain: "NAAF_DNS_DOMAIN",
      mtu: "NAAF_MTU"
    }.freeze

    # Seeds that bootstrap DETECTS from the box rather than taking from the
    # operator. naaf.conf still carries a placeholder so the key list is complete,
    # but the stored value comes from `ip -o -4 route show to default`, so on any
    # box whose NIC is not eth0 — which is most of them — conf and DB disagree by
    # design. Reporting that as drift would fire on every boot forever, and a
    # warning that always fires is one nobody reads when wg_interface really is
    # half-renamed. That case is what drift is for; keep it audible.
    DETECTED = [:wan_interface].freeze

    SEARCH = ["/etc/naaf/naaf.conf", File.expand_path("../../naaf.conf", __dir__)].freeze

    # KEY=value only. No `export`, no expansion — the grammar is the intersection
    # of what systemd EnvironmentFile=, `set -a; . file`, and this parser accept.
    LINE = /\A(?:export\s+)?([A-Z][A-Z0-9_]*)=(.*?)\s*\z/

    class << self
      def path
        return @path if defined?(@path)
        @path = ENV["NAAF_CONF"] || SEARCH.find { |p| File.readable?(p) }
      end

      def file
        @file ||= (path && File.readable?(path)) ? parse(File.read(path)) : {}
      end

      def parse(text)
        text.each_line.with_object({}) do |line, acc|
          next if line.start_with?("#") || line.strip.empty?
          next unless (m = LINE.match(line))
          v = m[2]
          v = v[1..-2] if v.length >= 2 && v.start_with?("'") && v.end_with?("'")
          acc[m[1]] = v
        end
      end

      # An empty value means "unset", so `NAAF_ENDPOINT_HOST=` in the file falls
      # through to the default rather than yielding "". DEFAULTS.fetch (not [])
      # so a typo'd key raises at the call site instead of returning nil.
      def [](key)
        v = ENV[key]
        v = file[key] if v.nil? || v.empty?
        v = DEFAULTS.fetch(key) if v.nil? || v.empty?
        v
      end

      def fetch!(key)
        self[key] || raise(KeyError, "#{key} is not set (see #{path || "naaf.conf"})")
      end

      def int(key) = Integer(fetch!(key), 10)

      def bool(key) = ["1", "true", "yes", "on"].include?(self[key].to_s.downcase)

      # Pairs where naaf.conf and the settings row disagree. The DB wins at
      # runtime; this exists so a half-finished change announces itself in the
      # journal instead of silently pointing the firewall and the daemon at
      # different interfaces.
      def drift(settings)
        SEEDS.filter_map do |col, key|
          next if DETECTED.include?(col)
          want = self[key].to_s
          have = settings[col].to_s
          next if want.empty? || want == have
          {key: key, conf: want, db: have}
        end
      end

      # Test seam: forget the memoized file so a test can point NAAF_CONF elsewhere.
      def reset!
        remove_instance_variable(:@path) if defined?(@path)
        @file = nil
      end
    end
  end
end
