# frozen_string_literal: true

require "roda"
require "rack/session"
require "bcrypt"
require "rqrcode"
require "ipaddr"
require "console" # error_handler and structured logging reference Console directly
require_relative "config"
require_relative "db"
require_relative "backup"
require_relative "format"
require_relative "ipam"
require_relative "reconciler"
require_relative "config_builder"
require_relative "zone"
require_relative "metrics"
require_relative "renderers/svg"

module Naaf
  class App < Roda
    # Both set by bin/naaf before config.ru freezes this class. A test assigns
    # its own stand-ins the same way and never freezes.
    class << self; attr_accessor :reconciler, :metrics; end

    plugin :render, engine: "erb", views: "views", layout: "layouts/app"
    plugin :public, root: "vendor"
    # Roda's cookie defaults carry no Expires/Max-Age, which makes the session a
    # browser-session cookie that dies when the browser quits. max_age keeps the
    # login for a week; max_seconds enforces the same ceiling server-side so a
    # replayed cookie cannot outlive it.
    SESSION_SECONDS = Config.int("NAAF_SESSION_DAYS") * 24 * 60 * 60
    plugin :sessions,
      secret: Config.fetch!("NAAF_SESSION_SECRET"),
      key: Config["NAAF_SESSION_COOKIE"],
      max_seconds: SESSION_SECONDS,
      cookie_options: {max_age: SESSION_SECONDS}
    plugin :flash
    plugin :route_csrf
    plugin :halt
    plugin :h # escaping for the dashboard, which renders names off the network

    # Milliseconds. Only tunes the browser's own EventSource reconnect; once the
    # browser gives up, the htmx extension's backoff takes over and that one is
    # fixed and not settable from here.
    SSE_RETRY_MS = 3000
    plugin :error_handler do |e|
      Console.error(self, "request failed", exception: e)
      response.status = 500
      "Internal error"
    end

    def reconciler = App.reconciler

    def metrics = App.metrics

    # Before the collector's first tick there is nothing to draw, and on a box
    # with no /proc there never will be much. An empty snapshot has every key a
    # fragment touches, so no template needs a nil guard around a container.
    def snapshot = metrics&.snapshot || Metrics::Snapshot.empty

    # Short names because every dashboard fragment uses them on nearly every
    # line. Both are pure modules; neither touches the request or the database.
    def fmt = Naaf::Format

    def svg = Renderers::SVG

    # The one-shot generated private key is bound to the client it was generated
    # for: this only yields it when the requested id matches, so client A's
    # freshly-generated key can never be rendered into client B's config or QR.
    def peek_oneshot_privkey(id)
      stash = session["oneshot_privkey"]
      stash["key"] if stash.is_a?(Hash) && stash["id"] == id.to_s
    end

    # Peek, build, and only THEN consume — the one and only way to spend the
    # stash. There is deliberately no bare take_: the stash is the one and only
    # copy of a freshly generated private key (nothing persists it, and the
    # documented recovery is deleting and re-adding the client), so anything that
    # can raise between the take and a finished response destroys it for good.
    # And plenty can: ConfigBuilder#render raises ArgumentError for five wstunnel
    # misconfigurations no route-level guard can see (missing/malformed path
    # prefix, malformed SNI, out-of-range port, unrecognised TLS_VERIFY, and the
    # deliberately refused verify-with-SNI-but-no-ACME cell), all of which
    # error_handler flattens to a 500 while the session after-hook still writes
    # the emptied cookie. Consuming only on the success path makes that 500
    # harmless: the key is still there for the next download.
    #
    # `if key` and not an unconditional delete: the stash is bound to one client
    # id, and a config download for client B must not clear client A's key.
    def with_oneshot_privkey(id)
      key = peek_oneshot_privkey(id)
      result = yield key
      session.delete("oneshot_privkey") if key
      result
    end

    # Raised by the param_* validators; caught by #submit and turned into a
    # flash error + redirect so a bad form never reaches the DB or the kernel.
    class ValidationError < StandardError; end

    # The single write-path for the resource forms: run the mutation, push it to
    # the kernel via the reconciler, then redirect. A validation or uniqueness
    # failure short-circuits to a flash error with no apply — the DB write either
    # succeeded whole or never happened.
    def submit(path)
      yield
      reconciler.apply!
      request.redirect(path)
    rescue ValidationError => e
      flash["error"] = e.message
      request.redirect(path)
    rescue Sequel::UniqueConstraintViolation
      flash["error"] = "That entry already exists."
      request.redirect(path)
    end

    def param_client_id(raw)
      id = Integer(raw.to_s, exception: false)
      unless id && Naaf.db[:clients].where(id: id).count == 1
        raise ValidationError, "Select a client."
      end
      id
    end

    def param_proto(raw)
      proto = raw.to_s.downcase
      raise ValidationError, "Protocol must be tcp or udp." unless %w[tcp udp].include?(proto)
      proto
    end

    def param_port(raw)
      n = Integer(raw.to_s, exception: false)
      raise ValidationError, "Port must be between 1 and 65535." unless n && (1..65535).cover?(n)
      n
    end

    # What already owns `proto/port` ON THE BOX, or nil if nothing does.
    #
    # A port forward becomes a DNAT in `inet naaf` prerouting, and nat hook
    # prerouting runs BEFORE the routing decision — so a forward on a port the
    # host answers on rewrites packets addressed to the host itself and hands
    # them to a client, and the forward chain's `ct status dnat accept` waves
    # them through. tcp/22 takes SSH away, udp/<listen_port> stops every
    # WireGuard handshake (and the two together leave only the provider's serial
    # console), and tcp/<wstunnel port> silently kills the transport every
    # split-ws client rides while the unit stays active and the port stays open.
    #
    # Protocol-aware on purpose: udp/22 and tcp/<listen_port> steal nothing, and
    # there is no reason to refuse them. NAAF_WEB_PORT is deliberately NOT here —
    # the admin UI binds only the WireGuard IP and 127.0.0.1, so a DNAT for
    # traffic arriving on the WAN interface cannot reach it.
    def reserved_port_owner(proto, port)
      return "SSH" if proto == "tcp" && port == 22
      return "WireGuard" if proto == "udp" && port == Naaf.settings[:listen_port].to_i
      # Integer(exception: false), not Config.int: a malformed NAAF_WSTUNNEL_PORT
      # means 65-wstunnel.sh never brought a listener up, so there is nothing to
      # reserve — and a form must not 500 over it.
      if proto == "tcp" && ConfigBuilder.wstunnel? &&
          port == Integer(Config["NAAF_WSTUNNEL_PORT"].to_s, 10, exception: false)
        return "the wstunnel transport"
      end
      nil
    end

    def param_public_port(raw, proto)
      port = param_port(raw)
      owner = reserved_port_owner(proto, port)
      if owner
        raise ValidationError,
          "#{proto}/#{port} is what this box uses for #{owner}. " \
          "Forwarding it would take #{owner} away from the box — pick another public port."
      end
      port
    end

    # A single port ("22") or an inclusive range ("8000-8100"), returned as
    # [first, last]. Deliberately stricter than param_port: an anchored regex
    # rejects the "0x22"/" 22 " forms Integer() would otherwise accept.
    PORT_RANGE = /\A(\d{1,5})(?:-(\d{1,5}))?\z/
    def param_port_range(raw)
      m = PORT_RANGE.match(raw.to_s.strip)
      raise ValidationError, "Port must be a number or a range like 8000-8100." unless m
      first = Integer(m[1], 10)
      last = m[2] ? Integer(m[2], 10) : first
      unless (1..65535).cover?(first) && (1..65535).cover?(last)
        raise ValidationError, "Ports must be between 1 and 65535."
      end
      raise ValidationError, "Range start must not be after its end." if first > last
      [first, last]
    end

    # Overlapping rows would be silently merged into one nft interval, leaving the
    # UI listing two entries that no longer describe the ruleset. Reject up front
    # so what the table shows is what the kernel enforces.
    def assert_no_overlap!(client_id, proto, first, last)
      clash = Naaf.db[:exposed_ports]
        .where(client_id: client_id, proto: proto)
        .where { (port <= last) & (Sequel.function(:coalesce, :port_end, :port) >= first) }
        .first
      return unless clash
      other = (clash[:port_end] && clash[:port_end] != clash[:port]) ?
        "#{clash[:port]}-#{clash[:port_end]}" : clash[:port].to_s
      raise ValidationError, "That overlaps #{proto} #{other}, which is already exposed."
    end

    # A human-facing label: the client name. Unlike param_name it keeps case and
    # spaces, because it is a display name rather than a DNS label — but it must
    # reject control characters. Renderers::WireGuard writes the name into
    # wg0.conf as `# <name> (<hostname>)`, so an embedded newline would break out
    # of that comment and inject lines into the file the root helper feeds to
    # `wg-quick strip`.
    LABEL = /\A[^[:cntrl:]]{1,64}\z/
    def param_label(raw)
      s = raw.to_s.strip
      raise ValidationError, "Name is required." if s.empty?
      unless LABEL.match?(s)
        raise ValidationError, "Name must be at most 64 characters and contain no control characters."
      end
      s
    end

    def param_name(raw)
      name = raw.to_s.strip.downcase
      raise ValidationError, "Name is required." if name.empty?
      name
    end

    def param_ipv4(raw)
      ip = IPAddr.new(raw.to_s.strip)
      raise ValidationError, "Value must be an IPv4 address." unless ip.ipv4?
      ip.to_s
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      raise ValidationError, "Value must be an IPv4 address."
    end

    def param_ttl(raw)
      s = raw.to_s.strip
      return 60 if s.empty?
      n = Integer(s, exception: false)
      raise ValidationError, "TTL must be a non-negative integer." unless n && n >= 0
      n
    end

    # A single DNS label (RFC 1123): the client hostname becomes <hostname>.<domain>
    # in the internal zone, so it must be resolvable. Lowercased for the zone.
    HOSTNAME_LABEL = /\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/
    def param_hostname(raw)
      s = raw.to_s.strip.downcase
      raise ValidationError, "Hostname is required." if s.empty?
      unless HOSTNAME_LABEL.match?(s)
        raise ValidationError, "Hostname must be a DNS label (letters, digits, hyphens; no dots)."
      end
      s
    end

    def presence(raw)
      s = raw.to_s.strip
      s.empty? ? nil : s
    end

    # Where to land after a successful login. The value is only ever a path this
    # app wrote itself, but re-validate anyway: a leading "//" or a scheme would
    # turn the post-login redirect into an open redirect.
    def safe_return_to
      path = session.delete("return_to").to_s
      (path.start_with?("/") && !path.start_with?("//")) ? path : "/"
    end

    # A split-tunnel route. IPAddr masks the address to its network, so
    # "10.99.5.3/16" normalizes to "10.99.0.0/16" — the canonical AllowedIPs form.
    def param_cidr(raw)
      s = raw.to_s.strip
      raise ValidationError, "Route must be in CIDR form, e.g. 192.168.0.0/24." unless s.include?("/")
      ip = IPAddr.new(s)
      "#{ip}/#{ip.prefix}"
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      raise ValidationError, "Route must be a valid CIDR, e.g. 192.168.0.0/24."
    end

    # A client selector that may be left blank to mean "global" (client_id NULL).
    def optional_client(raw)
      return nil if raw.to_s.strip.empty?
      param_client_id(raw)
    end

    # Optional IPv6 literal (settings endpoint_v6). Blank clears it.
    def param_ipv6(raw)
      s = raw.to_s.strip
      return nil if s.empty?
      ip = IPAddr.new(s)
      raise ValidationError, "Must be an IPv6 address." unless ip.ipv6?
      ip.to_s
    rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
      raise ValidationError, "Must be an IPv6 address."
    end

    # Optional endpoint hostname (settings endpoint_host). Blank reverts to raw-IP.
    HOSTNAME = /\A(?=.{1,253}\z)[a-z0-9](-*[a-z0-9])*(\.[a-z0-9](-*[a-z0-9])*)*\z/
    def param_host(raw)
      s = raw.to_s.strip.downcase
      return nil if s.empty?
      raise ValidationError, "Endpoint host must be a valid hostname." unless HOSTNAME.match?(s)
      s
    end

    def param_mtu(raw)
      n = Integer(raw.to_s, exception: false)
      raise ValidationError, "MTU must be between 1280 and 1500." unless n && (1280..1500).cover?(n)
      n
    end

    def param_iface(raw)
      s = raw.to_s.strip
      raise ValidationError, "Interface name is required." if s.empty?
      raise ValidationError, "Invalid interface name." unless /\A[a-z0-9._-]{1,15}\z/i.match?(s)
      s
    end

    # wg-quick(8) derives the interface name from the .conf basename and refuses
    # anything outside [a-zA-Z0-9_=+.-]{1,15}\.conf — it exits before reading a
    # line of the file. `<hostname>-<flavor>.conf` blows that on the first long
    # name, and `laptop-split-nodns` (18) already did. Short suffixes plus a
    # truncated hostname keep every flavor inside the limit; the suffix is the
    # part that must survive, since it is what tells two downloads apart.
    FLAVOR_SUFFIX = {
      "split" => "split",
      "split-nodns" => "nodns",
      "full" => "full",
      "split-ws" => "ws",
      "split-ws-nodns" => "wsnd"
    }.freeze
    FILENAME_STEM_MAX = 15
    def config_filename(hostname, flavor)
      suffix = FLAVOR_SUFFIX.fetch(flavor, flavor)
      # param_hostname already confines the hostname to [a-z0-9-], every
      # character of which wg-quick accepts, so truncation is the only work left.
      host = hostname.to_s[0, FILENAME_STEM_MAX - suffix.length - 1]
      "#{host}-#{suffix}.conf"
    end

    route do |r|
      r.public # vendored css/js halt here, so they stay cacheable

      # Every app response is private to one admin, and the config/QR routes
      # render a client private key. None of it may sit in a cache — browser,
      # proxy, or the reverse-proxy-shaped one Falcon ships with.
      response["Cache-Control"] = "no-store"

      r.on "login" do
        r.get do
          # The auth gate below never sees /login, so without this a logged-in
          # admin returning here (restored tab, back button, bookmark) gets a
          # login form with the nav bar rendered behind it.
          r.redirect "/" if session["admin"]
          view("login")
        end
        r.post do
          check_csrf!
          hash = Naaf.settings[:admin_pw_hash]
          if hash && BCrypt::Password.new(hash) == r.params["password"].to_s
            session["admin"] = true
            r.redirect safe_return_to
          end
          flash["error"] = "Invalid password"
          r.redirect "/login"
        end
      end

      unless session["admin"]
        # EventSource follows a 302, gets 200 text/html back, and fails the
        # connection with no retry of its own — so an expired session would turn
        # the dashboard into a page that silently stops updating while the
        # extension's backoff hammers /events forever. A 401 says what actually
        # happened; the canary element at the foot of views/dashboard.erb is
        # what actually bounces the tab, via the HX-Redirect below.
        r.halt(401, "Unauthorized") if r.path == "/events"

        # htmx follows a redirect transparently and would swap the whole login
        # PAGE into whichever panel asked. HX-Redirect navigates the tab instead.
        if r.env["HTTP_HX_REQUEST"]
          response["HX-Redirect"] = "/login"
          r.halt(204, "")
        end

        # Only remember page navigations. A browser fetches /favicon.ico on its
        # own, and that request lands here too — recording it would send the
        # admin to a 404 after logging in instead of the page they asked for.
        session["return_to"] = r.path if r.get? && r.env["HTTP_ACCEPT"].to_s.include?("text/html")
        r.redirect "/login"
      end

      # After the auth gate, not before it: a POST from a page whose session has
      # since lapsed would otherwise fail the CSRF check first and surface as a
      # bare 500 instead of sending the admin back to the login form.
      check_csrf! unless r.get?

      r.root do
        @snapshot = snapshot
        view("dashboard")
      end

      # The same fragments the SSE stream pushes, as plain GETs. They are what
      # the page polls when NAAF_METRICS_SSE=0, and they are how every panel is
      # tested without a reactor. Read-only, so no CSRF work and no forms.
      r.on "metrics" do
        r.get String do |name|
          # A whitelist, not a convenience: interpolating an arbitrary segment
          # into a template path is a directory traversal.
          r.halt(404) unless Metrics::FRAGMENTS.include?(name)
          render("metrics/#{name}", locals: {s: snapshot})
        end
      end

      # One long-lived response per open dashboard tab.
      #
      # A Rack 3 *callable* body, deliberately NOT Roda's :streaming plugin. An
      # each-able body is pulled through an Enumerator fiber the scheduler does
      # not own: Async::Task.current does not exist inside it, a client
      # disconnect raises nothing, and the block's ensure never runs — so every
      # closed tab would leak. protocol-rack runs a callable body under
      # Fiber.schedule instead, as a real task where stream.write raises EPIPE
      # when the browser goes away.
      #
      # Set Content-Type and nothing else. protocol-rack turns a Content-Length
      # into a hard transport length and raises on the first chunk past it, and
      # strips Transfer-Encoding as a hop header — chunking is added for us.
      r.get "events" do
        response["Content-Type"] = "text/event-stream"
        hub = metrics.hub
        seen = 0
        body = proc do |stream|
          stream.write(Metrics::SSE.retry_after(SSE_RETRY_MS))
          loop do
            result = hub.wait(seen) or break # nil once the hub has closed
            seen, snap = result
            Metrics::LIVE_FRAGMENTS.each do |name|
              # One panel that raises must not end the stream. The response has
              # already been returned, so error_handler cannot see this; the
              # browser would just see a cleanly finished response and reconnect
              # every SSE_RETRY_MS forever, logging a backtrace each time.
              html = begin
                render("metrics/#{name}", locals: {s: snap})
              rescue => e
                Console.error(self, "dashboard fragment failed", fragment: name, exception: e)
                next
              end
              stream.write(Metrics::SSE.frame(html, event: name))
            end
          end
        rescue SystemCallError, IOError, Protocol::HTTP::Body::Writable::Closed
          # The tab went away: EPIPE or ECONNRESET locally, ETIMEDOUT or
          # EHOSTUNREACH when a VPN peer vanishes mid-stream, and Closed when
          # the body was shut from the other side. All normal termination — and
          # a failed write is the only way the server learns the peer is gone.
        ensure
          stream.close
        end
        # finish_with_body, not a bare rack array: it keeps Cache-Control:
        # no-store and still runs the session and flash after-hooks.
        throw :halt, response.finish_with_body(body)
      end

      r.on "clients" do
        # r.get true, not r.root: inside this block the remaining path is "",
        # and r.root wants "/". A bare `r.get` would be worse still — with no
        # argument it matches ANY get and would swallow /clients/5/config/split
        # and /clients/5/qr/split before they ever reached their handlers.
        r.get true do
          @clients = Naaf.db[:clients].order(:wg_ip).all
          @settings = Naaf.settings
          # Methods, not constants: Config[] re-reads ENV on every call, so a
          # `--step 65-wstunnel` that writes /etc/naaf/wstunnel.env and restarts
          # naaf is picked up without a code change.
          @flavors = ConfigBuilder.available_flavors
          # Enabled is the operator's intent; ready is whether 65-wstunnel has
          # actually run. In the gap the ws buttons are offered but every config
          # they would produce dials a path the server rejects, so the page says
          # so rather than leaving the admin to discover it on a client.
          @wstunnel_unprovisioned = ConfigBuilder.wstunnel? && !ConfigBuilder.wstunnel_ready?
          view("clients")
        end

        r.post true do
          hostname = param_hostname(r.params["hostname"])
          keys = reconciler.helper.genkeys
          supplied = r.params["pubkey"].to_s.strip
          pubkey = supplied.empty? ? keys[:public_key] : supplied

          id = Naaf.db[:clients].insert(
            name: param_label(r.params["name"]),
            hostname: hostname,
            wg_ip: IPAM.allocate(Naaf.db),
            pubkey: pubkey,
            psk: keys[:preshared_key],
            created_at: Time.now
          )
          reconciler.apply!
          # Private key is shown ONCE, bound to this client id, never persisted.
          if supplied.empty?
            session["oneshot_privkey"] = {"id" => id.to_s, "key" => keys[:private_key]}
          end
          r.redirect "/clients"
        rescue ValidationError => e
          flash["error"] = e.message
          r.redirect "/clients"
        rescue Sequel::UniqueConstraintViolation
          flash["error"] = "That name or hostname is already taken."
          r.redirect "/clients"
        end

        r.on Integer do |id|
          client = Naaf.db[:clients][id: id] || r.halt(404)

          r.post("delete") do
            Naaf.db[:clients].where(id: id).delete
            reconciler.apply!
            r.redirect "/clients"
          end

          r.post("toggle") do
            Naaf.db[:clients].where(id: id).update(enabled: !client[:enabled])
            reconciler.apply!
            r.redirect "/clients"
          end

          r.get "config", String do |flavor|
            # Turns .../config/bogus from a 500 (render raises ArgumentError,
            # which error_handler flattens to "Internal error") into the 404 an
            # unknown path always should have been. It is NOT what protects the
            # one-shot key — it cannot be, since it says nothing about whether
            # the wstunnel half of the config is renderable. with_oneshot_privkey
            # is what protects the key, by consuming it only on success.
            r.halt(404) unless ConfigBuilder.available?(flavor)
            with_oneshot_privkey(id) do |pk|
              # Everything that could raise happens inside the block, headers
              # included: the stash is spent only once a complete, deliverable
              # response has been built.
              conf = ConfigBuilder.new(Naaf.db, client).render(flavor, private_key: pk)
              response["Content-Type"] = "text/plain"
              response["Content-Disposition"] =
                "attachment; filename=\"#{config_filename(client[:hostname], flavor)}\""
              conf
            end
          end

          r.get "qr", String do |flavor|
            # No QR for a ws flavor, enabled or not. wireguard-apple's parser
            # allows only privatekey/listenport/address/dns/mtu in [Interface]
            # and throws interfaceHasUnrecognizedKey for anything else, as does
            # wireguard-android; a ws config carries PreUp, so every phone
            # rejects the scan. wg-quick(8) only.
            r.halt(404) if ConfigBuilder::WS_FLAVORS.include?(flavor)
            r.halt(404) unless ConfigBuilder.available?(flavor)
            conf = ConfigBuilder.new(Naaf.db, client)
              .render(flavor, private_key: peek_oneshot_privkey(id))
            response["Content-Type"] = "image/svg+xml"
            RQRCode::QRCode.new(conf, level: :l).as_svg(use_path: true, viewbox: true)
          end
        end
      end

      r.on "exposed-ports" do
        r.get true do
          @clients = Naaf.db[:clients].order(:name).all
          @rows = Naaf.db[:exposed_ports].order(:client_id, :port).all
          view("exposed_ports")
        end

        r.post true do
          submit("/exposed-ports") do
            client_id = param_client_id(r.params["client_id"])
            proto = param_proto(r.params["proto"])
            first, last = param_port_range(r.params["port"])
            assert_no_overlap!(client_id, proto, first, last)
            Naaf.db[:exposed_ports].insert(
              client_id: client_id,
              proto: proto,
              port: first,
              port_end: last,
              description: presence(r.params["description"])
            )
          end
        end

        r.on Integer do |id|
          r.post "delete" do
            submit("/exposed-ports") { Naaf.db[:exposed_ports].where(id: id).delete }
          end
        end
      end

      r.on "port-forwards" do
        r.get true do
          @clients = Naaf.db[:clients].order(:name).all
          @rows = Naaf.db[:port_forwards].order(:public_port).all
          view("port_forwards")
        end

        r.post true do
          submit("/port-forwards") do
            # proto first and in a local: the public port's reservation check is
            # protocol-aware, so it needs the validated protocol in hand.
            proto = param_proto(r.params["proto"])
            Naaf.db[:port_forwards].insert(
              client_id: param_client_id(r.params["client_id"]),
              proto: proto,
              public_port: param_public_port(r.params["public_port"], proto),
              target_port: param_port(r.params["target_port"])
            )
          end
        end

        r.on Integer do |id|
          r.post "toggle" do
            submit("/port-forwards") do
              row = Naaf.db[:port_forwards][id: id] || r.halt(404)
              # Re-check on the way ON, not just at insert: a row predating this
              # check (or written straight into SQLite) reaches the kernel the
              # moment someone enables it. Disabling is always allowed.
              unless row[:enabled]
                owner = reserved_port_owner(row[:proto], row[:public_port])
                if owner
                  raise ValidationError,
                    "#{row[:proto]}/#{row[:public_port]} is what this box uses for #{owner}. " \
                    "Delete this forward rather than enabling it."
                end
              end
              Naaf.db[:port_forwards].where(id: id).update(enabled: !row[:enabled])
            end
          end

          r.post "delete" do
            submit("/port-forwards") { Naaf.db[:port_forwards].where(id: id).delete }
          end
        end
      end

      r.on "dns-records" do
        r.get true do
          @rows = Naaf.db[:dns_records].order(:name, :value).all
          @auto_rows = Naaf::Zone.auto_records(Naaf.db)
            .select { |rec| rec[:rtype] == "A" && rec[:source] != :client_bare }
          @shadowed = @rows.select { |r| r[:rtype] == "A" }
            .map { |r| Naaf::Zone.normalize(r[:name]) }.to_set
          @settings = Naaf.settings
          view("dns_records")
        end

        r.post true do
          submit("/dns-records") do
            Naaf.db[:dns_records].insert(
              name: param_name(r.params["name"]),
              rtype: "A",
              value: param_ipv4(r.params["value"]),
              ttl: param_ttl(r.params["ttl"]),
              managed: false
            )
          end
        end

        r.on Integer do |id|
          r.post "delete" do
            submit("/dns-records") { Naaf.db[:dns_records].where(id: id).delete }
          end
        end
      end

      r.on "extra-routes" do
        r.get true do
          @clients = Naaf.db[:clients].order(:name).all
          @rows = Naaf.db[:extra_routes].order(:client_id).all
          view("extra_routes")
        end

        r.post true do
          submit("/extra-routes") do
            Naaf.db[:extra_routes].insert(
              client_id: optional_client(r.params["client_id"]),
              cidr: param_cidr(r.params["cidr"])
            )
          end
        end

        r.on Integer do |id|
          r.post "delete" do
            submit("/extra-routes") { Naaf.db[:extra_routes].where(id: id).delete }
          end
        end
      end

      r.on "settings" do
        r.get true do
          @settings = Naaf.settings
          # A backup you never observe is a backup you do not have. One Dir.glob
          # over at most NAAF_BACKUP_KEEP entries — no new state, no new route,
          # and deliberately no download link: that would serve server_privkey
          # and admin_pw_hash over HTTP.
          @backups_enabled = Config.bool("NAAF_BACKUP_ENABLED")
          @backup_dir = Config["NAAF_BACKUP_DIR"]
          @last_backup = @backups_enabled ? Backup.new(Naaf.db).latest : nil
          view("settings")
        end

        # Change the admin password. No apply! — it touches nothing the kernel sees.
        r.post "password" do
          pw = r.params["password"].to_s
          if pw.length < 8
            flash["error"] = "Password must be at least 8 characters."
          else
            Naaf.db[:settings].update(admin_pw_hash: BCrypt::Password.create(pw))
            flash["notice"] = "Admin password updated."
          end
          r.redirect "/settings"
        end

        # Edit only the safe subset. wg_subnet/server_ip/listen_port/keys are NOT
        # writable here: they change boot-time binds or invalidate every client
        # config (AGENTS.md "Ask first"), so they stay read-only in the UI.
        r.post true do
          submit("/settings") do
            Naaf.db[:settings].update(
              endpoint_host: param_host(r.params["endpoint_host"]),
              endpoint_v4: param_ipv4(r.params["endpoint_v4"]),
              endpoint_v6: param_ipv6(r.params["endpoint_v6"]),
              dns_upstream: param_ipv4(r.params["dns_upstream"]),
              dns_domain: param_name(r.params["dns_domain"]),
              mtu: param_mtu(r.params["mtu"]),
              wan_interface: param_iface(r.params["wan_interface"])
            )
          end
        end
      end

      r.post "apply" do
        reconciler.apply!
        r.redirect "/"
      end
    end
  end
end
