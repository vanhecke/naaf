# frozen_string_literal: true

require "roda"
require "rack/session"
require "bcrypt"
require "rqrcode"
require "ipaddr"
require "console" # error_handler and structured logging reference Console directly
require_relative "db"
require_relative "ipam"
require_relative "reconciler"
require_relative "config_builder"
require_relative "zone"

module WGCP
  class App < Roda
    class << self; attr_accessor :reconciler; end

    plugin :render, engine: "erb", views: "views", layout: "layouts/app"
    plugin :public, root: "vendor"
    # Roda's cookie defaults carry no Expires/Max-Age, which makes the session a
    # browser-session cookie that dies when the browser quits. max_age keeps the
    # login for a week; max_seconds enforces the same ceiling server-side so a
    # replayed cookie cannot outlive it.
    SESSION_SECONDS = 7 * 24 * 60 * 60
    plugin :sessions,
      secret: ENV.fetch("WGCP_SESSION_SECRET"),
      key: "wgcp.session",
      max_seconds: SESSION_SECONDS,
      cookie_options: {max_age: SESSION_SECONDS}
    plugin :flash
    plugin :route_csrf
    plugin :halt
    plugin :error_handler do |e|
      Console.error(self, "request failed", exception: e)
      response.status = 500
      "Internal error"
    end

    def reconciler = App.reconciler

    # The one-shot generated private key is bound to the client it was generated
    # for. take_/peek_ only yield it when the requested id matches, so client A's
    # freshly-generated key can never be rendered into client B's config or QR.
    def take_oneshot_privkey(id)
      stash = session["oneshot_privkey"]
      return nil unless stash.is_a?(Hash) && stash["id"] == id.to_s
      session.delete("oneshot_privkey")
      stash["key"]
    end

    def peek_oneshot_privkey(id)
      stash = session["oneshot_privkey"]
      stash["key"] if stash.is_a?(Hash) && stash["id"] == id.to_s
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
      unless id && WGCP.db[:clients].where(id: id).count == 1
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
      clash = WGCP.db[:exposed_ports]
        .where(client_id: client_id, proto: proto)
        .where { (port <= last) & (Sequel.function(:coalesce, :port_end, :port) >= first) }
        .first
      return unless clash
      other = (clash[:port_end] && clash[:port_end] != clash[:port]) ?
        "#{clash[:port]}-#{clash[:port_end]}" : clash[:port].to_s
      raise ValidationError, "That overlaps #{proto} #{other}, which is already exposed."
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
          hash = WGCP.settings[:admin_pw_hash]
          if hash && BCrypt::Password.new(hash) == r.params["password"].to_s
            session["admin"] = true
            r.redirect safe_return_to
          end
          flash["error"] = "Invalid password"
          r.redirect "/login"
        end
      end

      unless session["admin"]
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
        @clients = WGCP.db[:clients].order(:wg_ip).all
        @settings = WGCP.settings
        view("dashboard")
      end

      r.on "clients" do
        r.post true do
          hostname = param_hostname(r.params["hostname"])
          keys = reconciler.helper.genkeys
          supplied = r.params["pubkey"].to_s.strip
          pubkey = supplied.empty? ? keys[:public_key] : supplied

          id = WGCP.db[:clients].insert(
            name: r.params["name"],
            hostname: hostname,
            wg_ip: IPAM.allocate(WGCP.db),
            pubkey: pubkey,
            psk: keys[:preshared_key],
            created_at: Time.now
          )
          reconciler.apply!
          # Private key is shown ONCE, bound to this client id, never persisted.
          if supplied.empty?
            session["oneshot_privkey"] = {"id" => id.to_s, "key" => keys[:private_key]}
          end
          r.redirect "/"
        rescue ValidationError => e
          flash["error"] = e.message
          r.redirect "/"
        rescue Sequel::UniqueConstraintViolation
          flash["error"] = "That name or hostname is already taken."
          r.redirect "/"
        end

        r.on Integer do |id|
          client = WGCP.db[:clients][id: id] || r.halt(404)

          r.post("delete") do
            WGCP.db[:clients].where(id: id).delete
            reconciler.apply!
            r.redirect "/"
          end

          r.post("toggle") do
            WGCP.db[:clients].where(id: id).update(enabled: !client[:enabled])
            reconciler.apply!
            r.redirect "/"
          end

          r.get "config", String do |flavor|
            conf = ConfigBuilder.new(WGCP.db, client)
              .render(flavor, private_key: take_oneshot_privkey(id))
            response["Content-Type"] = "text/plain"
            response["Content-Disposition"] =
              "attachment; filename=\"#{client[:hostname]}-#{flavor}.conf\""
            conf
          end

          r.get "qr", String do |flavor|
            conf = ConfigBuilder.new(WGCP.db, client)
              .render(flavor, private_key: peek_oneshot_privkey(id))
            response["Content-Type"] = "image/svg+xml"
            RQRCode::QRCode.new(conf, level: :l).as_svg(use_path: true, viewbox: true)
          end
        end
      end

      r.on "exposed-ports" do
        r.get true do
          @clients = WGCP.db[:clients].order(:name).all
          @rows = WGCP.db[:exposed_ports].order(:client_id, :port).all
          view("exposed_ports")
        end

        r.post true do
          submit("/exposed-ports") do
            client_id = param_client_id(r.params["client_id"])
            proto = param_proto(r.params["proto"])
            first, last = param_port_range(r.params["port"])
            assert_no_overlap!(client_id, proto, first, last)
            WGCP.db[:exposed_ports].insert(
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
            submit("/exposed-ports") { WGCP.db[:exposed_ports].where(id: id).delete }
          end
        end
      end

      r.on "port-forwards" do
        r.get true do
          @clients = WGCP.db[:clients].order(:name).all
          @rows = WGCP.db[:port_forwards].order(:public_port).all
          view("port_forwards")
        end

        r.post true do
          submit("/port-forwards") do
            WGCP.db[:port_forwards].insert(
              client_id: param_client_id(r.params["client_id"]),
              proto: param_proto(r.params["proto"]),
              public_port: param_port(r.params["public_port"]),
              target_port: param_port(r.params["target_port"])
            )
          end
        end

        r.on Integer do |id|
          r.post "toggle" do
            submit("/port-forwards") do
              row = WGCP.db[:port_forwards][id: id] || r.halt(404)
              WGCP.db[:port_forwards].where(id: id).update(enabled: !row[:enabled])
            end
          end

          r.post "delete" do
            submit("/port-forwards") { WGCP.db[:port_forwards].where(id: id).delete }
          end
        end
      end

      r.on "dns-records" do
        r.get true do
          @rows = WGCP.db[:dns_records].order(:name, :value).all
          @auto_rows = WGCP::Zone.auto_records(WGCP.db)
            .select { |rec| rec[:rtype] == "A" && rec[:source] != :client_bare }
          @shadowed = @rows.select { |r| r[:rtype] == "A" }
            .map { |r| WGCP::Zone.normalize(r[:name]) }.to_set
          @settings = WGCP.settings
          view("dns_records")
        end

        r.post true do
          submit("/dns-records") do
            WGCP.db[:dns_records].insert(
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
            submit("/dns-records") { WGCP.db[:dns_records].where(id: id).delete }
          end
        end
      end

      r.on "extra-routes" do
        r.get true do
          @clients = WGCP.db[:clients].order(:name).all
          @rows = WGCP.db[:extra_routes].order(:client_id).all
          view("extra_routes")
        end

        r.post true do
          submit("/extra-routes") do
            WGCP.db[:extra_routes].insert(
              client_id: optional_client(r.params["client_id"]),
              cidr: param_cidr(r.params["cidr"])
            )
          end
        end

        r.on Integer do |id|
          r.post "delete" do
            submit("/extra-routes") { WGCP.db[:extra_routes].where(id: id).delete }
          end
        end
      end

      r.on "settings" do
        r.get true do
          @settings = WGCP.settings
          view("settings")
        end

        # Change the admin password. No apply! — it touches nothing the kernel sees.
        r.post "password" do
          pw = r.params["password"].to_s
          if pw.length < 8
            flash["error"] = "Password must be at least 8 characters."
          else
            WGCP.db[:settings].update(admin_pw_hash: BCrypt::Password.create(pw))
            flash["notice"] = "Admin password updated."
          end
          r.redirect "/settings"
        end

        # Edit only the safe subset. wg_subnet/server_ip/listen_port/keys are NOT
        # writable here: they change boot-time binds or invalidate every client
        # config (AGENTS.md "Ask first"), so they stay read-only in the UI.
        r.post true do
          submit("/settings") do
            WGCP.db[:settings].update(
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
