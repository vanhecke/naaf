# frozen_string_literal: true

require "erb"
require "ipaddr" # allowed_ips audits every route against the endpoint address
require "console" # the split-flavor route warning
require_relative "config"

module Naaf
  class ConfigBuilder
    FLAVORS = %w[split split-nodns full split-ws split-ws-nodns].freeze

    # The two flavors that carry WireGuard inside a TLS WebSocket. They are
    # wg-quick(8) only: the [Interface] hooks they emit make wireguard-apple and
    # wireguard-android throw interfaceHasUnrecognizedKey, so there is no QR for
    # them and the qr route refuses them outright.
    #
    # There is deliberately no full-tunnel-over-wstunnel flavor:
    # AllowedIPs = 0.0.0.0/0 would capture wstunnel's own TCP session, and
    # wg-quick's `not fwmark <table>` exemption covers the kernel WireGuard
    # socket, not a userspace process. Omitting the flavor is not on its own
    # enough — extra_routes is folded into AllowedIPs verbatim, so the same
    # config is reachable through a route. audit_transport_capture is what
    # actually holds the line.
    WS_FLAVORS = %w[split-ws split-ws-nodns].freeze

    # The client-side relay: wstunnel binds this on 127.0.0.1 and WireGuard
    # dials it instead of the real endpoint.
    WS_LOCAL_PORT = 51820
    # /var/run, not /run — macOS has no /run. Named after the local port rather
    # than wg-quick's %i, which expands to the config name on Linux but to the
    # utunN device on macOS; %I exists only on macOS. Neither is stable, so
    # neither appears anywhere in a hook.
    WS_PIDFILE = "/var/run/naaf-wstunnel-#{WS_LOCAL_PORT}.pid".freeze
    WS_LOGFILE = "/var/log/naaf-wstunnel.log"
    # IPv4 overhead is 110 B/datagram (32 WireGuard + 4 unmasked WebSocket frame
    # + 22 TLS 1.3 record + 32 TCP + 20 IPv4), so 1280 + 110 = 1390 sits inside a
    # 1400-byte outer path. The IPv6 overhead is 130 and would NOT fit at the
    # usual 1420, and endpoint_v6 is a supported family — so lean on the argument
    # that generalises: over TCP an oversized MTU costs efficiency, never
    # connectivity, so err low. 1280 is also the IPv6 minimum link MTU and
    # already the floor of param_mtu. A constant and not a naaf.conf key: it
    # describes the client's path and matches nothing on the server.
    WS_MTU = 1280

    # wg-quick runs each hook as `(eval "$hook")` AS ROOT on the client machine,
    # and Config[] prefers ENV — so any value that reaches naaf.service's
    # environment reaches that eval on every client that downloads a config.
    # These are whitelists rather than escaping: every character they admit is
    # inert to sh, which is what leaves nothing to quote around.
    #
    # "inert to sh" has to hold for the FIRST character too, which a flat
    # character class does not give you: a leading `-` turns the word into an
    # argv flag (`--tls-sni-override -x` makes wstunnel exit with "unexpected
    # argument", in the child, where `&` hides it) and a leading `~` is
    # tilde-expanded in an unquoted word (`-P ~root` reaches the server as
    # `/var/root`). So both name classes are anchored the way app.rb's HOSTNAME
    # already is — same value class, no reason for this path to be laxer than
    # the Settings form — and the prefix must start alphanumeric.
    #
    # WS_SAFE_HOST admits no brackets and no colons. It used to, "for the v6
    # literal", but the ws flavors cannot reach one: wstunnel_locals calls
    # endpoint_addr with the default family: :v4, so a v6-only box raises
    # "endpoint address is unset or malformed" instead. Brackets are bash
    # pathname-expansion metacharacters in the unquoted `wss://#{host}:#{port}`
    # word (with a `wss:` directory in cwd, `echo wss://[2001:db8::5]:443`
    # prints `wss://b:443`), so admitting them for a form that cannot occur was
    # a live hazard one argument away. Adding v6 here means single-quoting that
    # argv element first.
    # Two names for one shape, not one constant used twice: they validate
    # different values (the dialed host, the presented cover name) and only
    # happen to agree — RFC 6066 forbids an IP literal in SNI, so WS_SAFE_SNI can
    # never widen the way WS_SAFE_HOST might.
    WS_SAFE_HOST = /\A(?=.{1,253}\z)[a-z0-9](-*[a-z0-9])*(\.[a-z0-9](-*[a-z0-9])*)*\z/i
    WS_SAFE_SNI = /\A(?=.{1,253}\z)[a-z0-9](-*[a-z0-9])*(\.[a-z0-9](-*[a-z0-9])*)*\z/i
    WS_SAFE_PREFIX = /\A[A-Za-z0-9][A-Za-z0-9._~-]{0,127}\z/ # RFC 3986 unreserved
    WS_PORT_RANGE = (1..65535)

    class << self
      # Methods, never constants frozen at load. Config[] re-reads ENV on every
      # call, which is both the test seam and what makes a live
      # `--step 65-wstunnel` (which writes /etc/naaf/wstunnel.env and then
      # `systemctl try-restart naaf`) take effect without a code change.
      def wstunnel? = Config.bool("NAAF_WSTUNNEL_ENABLED")

      # Enabled is the operator's intent; ready is whether 65-wstunnel.sh has
      # actually run. Without a valid prefix every config we could emit would
      # dial a path the server rejects, so the UI shows a half-provisioned
      # banner instead of handing out configs that cannot work.
      def wstunnel_ready? = wstunnel? && WS_SAFE_PREFIX.match?(path_prefix)

      # Read straight from ENV, not through Config[]. The prefix has no DEFAULTS
      # entry on purpose — deploy/install-config.sh iterates the incoming file
      # only, so a key on the box but absent from the operator's naaf.conf is
      # dropped and regenerated, silently invalidating every issued split-ws
      # config — and Config#[] ends in DEFAULTS.fetch, which would raise KeyError
      # for a key it does not know. ENV is exactly where it belongs: 65 writes
      # /etc/naaf/wstunnel.env and naaf.service pulls it in with EnvironmentFile=.
      def path_prefix = ENV["NAAF_WSTUNNEL_PATH_PREFIX"].to_s

      def available_flavors = wstunnel? ? FLAVORS : FLAVORS - WS_FLAVORS

      def available?(flavor) = available_flavors.include?(flavor)
    end

    def initialize(db, client)
      @db = db
      @client = client
      @s = Naaf.settings
    end

    def render(flavor, private_key: nil)
      raise ArgumentError, "unknown flavor" unless FLAVORS.include?(flavor)
      ws = WS_FLAVORS.include?(flavor)
      raise ArgumentError, "flavor #{flavor} needs NAAF_WSTUNNEL_ENABLED=1" if ws && !self.class.wstunnel?

      path = File.expand_path("../../views/conf_#{flavor.tr("-", "_")}.erb", __dir__)
      client = @client
      s = @s
      pk = private_key || "REPLACE_WITH_YOUR_PRIVATE_KEY"
      allowed = allowed_ips(flavor)
      # Every local is bound for every flavor so that no template can reference
      # an undefined one; the ws_* locals are nil for the non-ws templates,
      # which never read them.
      ep = ws ? "127.0.0.1:#{WS_LOCAL_PORT}" : endpoint
      mtu = ws ? WS_MTU : s[:mtu]
      w = ws ? wstunnel_locals : {}
      ws_endpoint = w[:endpoint]
      ws_guard = w[:guard]
      ws_preup = w[:preup]
      ws_postdown = w[:postdown]
      ws_sni_note = w[:sni_note]
      ERB.new(File.read(path), trim_mode: "-").result(binding)
    end

    def allowed_ips(flavor)
      return "0.0.0.0/0" if flavor == "full"
      # The ws flavors fall through to here deliberately: what they change is how
      # the packets travel, not which ones do, so a split-ws config routes
      # exactly what a split config routes, extra_routes included — with the one
      # exception audit_transport_capture enforces, which is that they must not
      # route the transport itself.
      routes = [@s[:wg_subnet]]
      # NOTE: `where(client_id: [nil, id])` renders as `client_id IN (NULL, id)`,
      # and SQL `IN (NULL, ...)` never matches NULL rows — so the global routes
      # (client_id IS NULL) would be silently dropped. Use an explicit OR.
      routes += @db[:extra_routes]
        .where(Sequel[client_id: nil] | Sequel[client_id: @client[:id]])
        .select_map(:cidr)
      # Site LANs are global: every split client should send them to the hub
      # so Naaf can cryptokey-route them to the remote peer. Deduped with
      # extra_routes below — adding the same CIDR on both pages is harmless.
      routes += @db[:site_networks]
        .where(site_id: @db[:sites].where(enabled: true).select(:id))
        .select_map(:cidr)
      routes = routes.uniq
      audit_transport_capture(routes, ws: WS_FLAVORS.include?(flavor))
      routes.join(", ")
    end

    # Split from #endpoint because the wss:// URL needs the host WITHOUT the
    # WireGuard port glued on — wstunnel listens on NAAF_WSTUNNEL_PORT.
    def endpoint_addr(family: :v4)
      @s[:endpoint_host] || ((family == :v6) ? "[#{@s[:endpoint_v6]}]" : @s[:endpoint_v4])
    end

    def endpoint(family: :v4) = "#{endpoint_addr(family: family)}:#{@s[:listen_port]}"

    private

    # The WS_FLAVORS invariant, enforced where it can actually be broken.
    # "There is deliberately no full-tunnel-over-wstunnel flavor" is not a
    # sufficient guard, because allowed_ips folds extra_routes in verbatim and
    # param_cidr accepts 0.0.0.0/0 — a plausible way for an admin to hand
    # everyone a default route. Two shapes route wstunnel's own TCP session into
    # the tunnel it is carrying:
    #
    #   /0        wg-quick's add_route() dispatches any */0 to add_default(),
    #             which installs `ip rule add not fwmark <table> table <table>`
    #             plus `suppress_prefixlength 0`. The fwmark exemption covers
    #             the kernel WireGuard socket; wstunnel is a userspace process
    #             and its socket carries no mark, so the transport goes into
    #             wg0. The interface comes up, never handshakes, and
    #             suppress_prefixlength 0 takes the machine's own default route
    #             with it — no network at all until `wg-quick down`.
    #   covering  a route that merely CONTAINS the hub's public address
    #             (203.0.113.0/24 for an endpoint of 203.0.113.7 — the natural
    #             "let me reach the hub's datacenter LAN" entry) is enough:
    #             wg-quick puts `ip route add 203.0.113.0/24 dev wg0` in the
    #             main table, in front of the transport.
    #
    # Neither errors anywhere else: the guard hook only checks that the wstunnel
    # binary exists, so without this the client downloads a *-ws.conf that comes
    # up clean and silently never handshakes.
    #
    # The asymmetry between ws and split is deliberate. A /0 is FINE for plain
    # split — the kernel WireGuard socket really is fwmark-exempt on that path,
    # which is how `split` plus a /0 extra route works as a full tunnel today —
    # so refusing it would break a configuration that ships and works. A
    # covering route breaks plain split too, but that hazard predates the ws
    # flavors, and it can be a false alarm: when endpoint_host resolves to
    # something other than endpoint_v4 the transport never touches that address.
    # So ws raises and split warns.
    def audit_transport_capture(routes, ws:)
      # endpoint_host is what the client dials, but the server cannot resolve a
      # name — checking the addresses it does hold is the available approximation
      # and is right whenever the name points at this box, which is the only
      # arrangement the docs describe.
      hub = [@s[:endpoint_v4], @s[:endpoint_v6]].filter_map { |addr| parse_cidr(addr) }
      routes.each do |cidr|
        net = parse_cidr(cidr)
        # A route we cannot parse is a route we cannot clear. Rows come from
        # param_cidr, so this is unreachable through the UI; for the ws flavors
        # refuse anyway rather than emit an unaudited AllowedIPs.
        raise ArgumentError, "AllowedIPs route #{cidr} is not a valid CIDR" if ws && net.nil?
        next if net.nil?

        if net.prefix.zero?
          next unless ws
          raise ArgumentError,
            "AllowedIPs route #{cidr} is a default route, which would capture wstunnel's own " \
            "TCP session — that is why there is no full-tunnel-over-wstunnel flavor. Remove " \
            "the route or use the split flavor."
        end

        next unless hub.any? { |addr| net.include?(addr) }
        unless ws
          Console.warn(self, "an AllowedIPs route contains the endpoint address, so WireGuard's " \
            "own packets to the hub route into the tunnel", route: cidr)
          next
        end
        raise ArgumentError,
          "AllowedIPs route #{cidr} contains the endpoint address, so it would route wstunnel's " \
          "own TCP session into the tunnel it carries. Narrow the route so it excludes the endpoint."
      end
    end

    # nil rather than an exception: the caller decides what an unparseable value
    # means, and it means different things for a route and for endpoint_v6.
    def parse_cidr(value)
      IPAddr.new(value.to_s)
    rescue IPAddr::Error
      nil
    end

    # The wstunnel half of the template binding, validated before a single
    # character of it is composed. Built in Ruby and not in ERB on purpose:
    # views/conf_*.erb are rendered by a bare ERB.new(...).result(binding), so
    # h() and Naaf::Format are not in scope there and <%= %> is raw by
    # construction — the escaping has to happen before the template sees it.
    def wstunnel_locals
      # Never interpolate a rejected value into the message: the path prefix is a
      # shared secret and this string reaches the journal through the error handler.
      prefix = self.class.path_prefix
      raise ArgumentError, "NAAF_WSTUNNEL_PATH_PREFIX is unset or malformed" unless WS_SAFE_PREFIX.match?(prefix)

      host = endpoint_addr.to_s
      raise ArgumentError, "endpoint address is unset or malformed" unless WS_SAFE_HOST.match?(host)

      # Config[] already collapses an empty value to the default, which is nil.
      sni = Config["NAAF_WSTUNNEL_SNI"]
      raise ArgumentError, "NAAF_WSTUNNEL_SNI is malformed" if sni && !WS_SAFE_SNI.match?(sni)

      port = ws_port(Config["NAAF_WSTUNNEL_PORT"], "NAAF_WSTUNNEL_PORT")
      listen_port = ws_port(@s[:listen_port], "listen_port")
      verify = tls_verify?(sni)

      # The one genuinely broken combination, and the only one refused.
      # --tls-sni-override also sets the name the certificate is checked against,
      # and the self-signed fallback is issued for the endpoint — so verification
      # against a cover name can never pass, whatever the client trusts. With
      # ACME on it can: that is the strong form, and holding a real certificate
      # for the cover name is the operator's side of the bargain.
      if verify && sni && !Config.bool("NAAF_ACME_ENABLED")
        raise ArgumentError,
          "NAAF_WSTUNNEL_TLS_VERIFY=on with NAAF_WSTUNNEL_SNI needs a real certificate " \
          "for the cover name (NAAF_ACME_ENABLED=1)"
      end

      {
        endpoint: "wss://#{host}:#{port}",
        guard: ws_guard_hook,
        # Keywords, not positionals: listen_port and port are both integers and
        # swapping them would produce a config that dials the wrong service on
        # both ends and still looks plausible.
        preup: ws_preup_hook(prefix: prefix, verify: verify, sni: sni, listen_port: listen_port, host: host, port: port),
        postdown: ws_postdown_hook,
        sni_note: ws_sni_note(host, port, sni)
      }
    end

    # Two preconditions, one hook, because both have the same remedy: fail before
    # anything is started rather than after.
    #
    # 1. With `&`, a missing binary fails only in the child: the parent's async
    #    list returns 0 and the user gets an interface that silently never
    #    handshakes. `exit 1` trips wg-quick's `set -e` while its
    #    `trap 'del_if; exit' EXIT` is armed, so the half-built interface is torn
    #    down instead.
    #
    # 2. One machine has one WS_LOCAL_PORT, so two ws configs genuinely cannot
    #    coexist — and /clients hands every client both a *-ws.conf and a
    #    *-wsnd.conf, so having two is the normal state. Per-client ports would
    #    be a lie (they would still share the one UDP port on the hub side of
    #    nothing; the real constraint is this machine's 51820). What must not
    #    happen is the collision being SILENT: `up A; up B` had B's wstunnel die
    #    on EADDRINUSE while `echo $! >PIDFILE` recorded its pid anyway, so
    #    `down A` then read B's dead pid, killed nothing, and removed the
    #    pidfile — leaving A's root-owned relay holding a TLS session to the hub
    #    and owning 127.0.0.1:51820 after every interface was down, which
    #    silently breaks every later `up` until reboot. Refusing when the pidfile
    #    names a LIVE wstunnel makes the second `up` fail loudly and leaves the
    #    first one's pidfile pairing intact.
    #
    # The `ps`/`case` shape is the reaper's, for the reasons documented there. A
    # `case` with no matching branch returns 0, so the hook ends 0 when there is
    # no collision and 1 only where it says `exit 1`.
    def ws_guard_hook
      'command -v wstunnel >/dev/null 2>&1 || { echo "naaf: wstunnel is not on PATH - ' \
        'see docs/WSTUNNEL.md" >&2; exit 1; }; ' \
        "p=$(cat #{WS_PIDFILE} 2>/dev/null || true); " \
        'case "$(ps -p "${p:-0}" -o comm= 2>/dev/null)" in *wstunnel) ' \
        'echo "naaf: a naaf wstunnel relay is already running (pid $p) - one ws config at a ' \
        'time per machine, take the other one down first" >&2; exit 1 ;; esac'
    end

    def ws_preup_hook(prefix:, verify:, sni:, listen_port:, host:, port:)
      argv = ["nohup", "wstunnel", "client", "-P", prefix]
      argv << "--tls-verify-certificate" if verify
      argv.push("--tls-sni-override", sni) if sni
      # The local bind address is PINNED. Never the short `udp://51820:...` form:
      # wstunnel's default bind for it was never established, and if it is
      # 0.0.0.0 then every laptop running this flavor becomes an open UDP relay
      # from its LAN into the hub's WireGuard port — on exactly the untrusted
      # networks these flavors exist for.
      #
      # The single quotes are load-bearing: a second query parameter's `&` would
      # otherwise background the command mid-string.
      #
      # No `-c 1`. --connection-min-idle 1 delays the local UDP bind until the
      # TCP+TLS+upgrade to the server succeeds, so an unreachable server means it
      # never binds at all while wstunnel retries with backoff. The default binds
      # immediately and WireGuard's 5 s handshake retry absorbs the connect
      # latency — which is what makes the PreUp race harmless.
      argv.push("-L", "'udp://127.0.0.1:#{WS_LOCAL_PORT}:127.0.0.1:#{listen_port}?timeout_sec=0'")
      argv << "wss://#{host}:#{port}"
      # nohup, not a bare `&`: a hand-run `sudo wg-quick up` in a terminal would
      # otherwise SIGHUP the transport when the terminal closes. POSIX and present
      # on both platforms, unlike setsid, which macOS does not ship. nohup
      # execvp()s, so `$!` really is wstunnel's own pid.
      #
      # umask 077 before the redirect: wg-quick echoes every hook verbatim to
      # stderr and the logfile is otherwise created under root's ambient umask.
      # The prefix is necessarily visible to anyone who can read this client's
      # config or journal — the same trust boundary as its private key — but the
      # log should not be world-readable on disk.
      "umask 077; #{argv.join(" ")} >#{WS_LOGFILE} 2>&1 & echo $! >#{WS_PIDFILE}"
    end

    # Both `|| true` are load-bearing under wg-quick's `set -e`.
    # `p=$(cat ... 2>/dev/null)` is a simple command whose status is the
    # substitution's, so a missing pidfile would abort one statement earlier than
    # the `kill $(cat pidfile)` shape this replaces; and `kill` can lose a race
    # with a pid that died between the `ps` and the `kill`, skipping the `rm -f`
    # and leaving a stale pidfile behind. `down` without an `up` (a config
    # imported and then torn down, or a relay that died on its own) reaches both
    # paths for real; the guard hook is what keeps a SECOND `up` from reaching
    # them with the wrong pid in hand.
    #
    # The `case` glob is not belt-and-braces. macOS `ps -p N -o comm=` prints
    # argv[0] as exec'd — a full path when invoked by path, a bare basename when
    # resolved from PATH — and Linux truncates comm to 15 characters. The glob
    # covers every form; an equality test would only happen to work today. A
    # `case` with no matching branch returns 0, and `rm -f` is last and cannot
    # fail, so the whole line is safe under `set -e`.
    def ws_postdown_hook
      "p=$(cat #{WS_PIDFILE} 2>/dev/null || true); " \
        'case "$(ps -p "${p:-0}" -o comm= 2>/dev/null)" in *wstunnel) kill "$p" 2>/dev/null || true ;; esac; ' \
        "rm -f #{WS_PIDFILE}"
    end

    # A comment block, not a hook — it exists so the person holding the file can
    # switch on the cover name without reading the docs first.
    def ws_sni_note(host, port, sni)
      opening =
        if sni
          ["# TLS/SNI: this dials wss://#{host}:#{port}",
            "# but presents #{sni} on the wire as SNI (--tls-sni-override below),",
            "# which is the name an inspecting firewall evaluates its policy against."]
        else
          ["# TLS/SNI: this dials wss://#{host}:#{port},",
            "# so #{host} is what goes on the wire as SNI.",
            "# To present a cover name to an inspecting firewall, add:",
            "#   --tls-sni-override www.example.com"]
        end
      (opening + [
        "# Certificate verification composes with it: keep --tls-verify-certificate only",
        "# if you hold a real certificate for the cover name, otherwise remove it.",
        "# See docs/WSTUNNEL.md."
      ]).join("\n")
    end

    # auto | on | off. SNI override and certificate verification DO compose —
    # wstunnel declares conflicts_with only between --tls-sni-disable and
    # --tls-sni-override — so these are two independent knobs.
    #
    #   auto  verify exactly when the dialed name and the served certificate
    #         agree: ACME on and no SNI override.
    #   on    always verify. Alongside NAAF_WSTUNNEL_SNI this is the strong form —
    #         a cover domain you own, holding a real DNS-01 certificate, where the
    #         SNI and the certificate agree AND the client checks. Without one it
    #         is an explicit override that says "I have trust-stored this box's
    #         certificate"; it is not refused, because that is a real arrangement
    #         and the operator asked for it in so many words.
    #   off   never verify. Correct for the self-signed default.
    #
    # `auto` reads NAAF_ACME_ENABLED, which is the operator's INTENT, not the
    # issuer of the certificate that ended up installed — 60-certs.sh warns and
    # exits 0 with the self-signed fallback in several paths (no DNS API token,
    # git missing, acme.sh commit mismatch, a bare-IP endpoint), and in those
    # `auto` emits --tls-verify-certificate against a self-signed certificate and
    # the handshake fails. Kept optimistic anyway, deliberately:
    #
    #   - the conservative version needs a signal that does not exist. Reading
    #     the achieved issuer means 60-certs.sh recording it next to the path
    #     prefix in /etc/naaf/wstunnel.env; until it does, the only thing this
    #     side can read IS the intent flag, and defaulting `auto` to "off
    #     whenever ACME is on" would silently discard verification on every
    #     correctly provisioned box — trading a loud failure for a quiet one,
    #     which is the wrong direction for a security control.
    #   - the failure is already loud and same-run: deploy/verify.sh section 9
    #     asserts each certificate is CA-issued when ACME is on and exits
    #     nonzero, so ./deploy.sh fails on the deploy that caused it. The
    #     exposure window is an ignored verify failure, not a silent state.
    #   - it is one setting away from correct in either direction:
    #     NAAF_WSTUNNEL_TLS_VERIFY=off pins the fallback behaviour.
    #
    # If wstunnel.env ever grows an achieved-issuer key, this is the method that
    # should read it instead.
    def tls_verify?(sni)
      case Config["NAAF_WSTUNNEL_TLS_VERIFY"].to_s.downcase
      when "on" then true
      when "off" then false
      when "auto" then Config.bool("NAAF_ACME_ENABLED") && sni.nil?
      else raise ArgumentError, "NAAF_WSTUNNEL_TLS_VERIFY must be auto, on or off"
      end
    end

    # A port is the one field here with no legitimate non-numeric form, so
    # Integer() plus an explicit range is the whole gate. Integer() raises
    # ArgumentError for nil, "" and anything else unparseable, which is the same
    # class render() raises for every other rejection.
    def ws_port(value, name)
      port = Integer(value.to_s, 10)
      raise ArgumentError, "#{name} must be 1-65535" unless WS_PORT_RANGE.cover?(port)
      port
    end
  end
end
