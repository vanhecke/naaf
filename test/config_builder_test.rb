# frozen_string_literal: true

require_relative "helper"
require "naaf/config_builder"
require "console/capture"
require "tempfile"
require "tmpdir"

describe Naaf::ConfigBuilder do
  before do
    @db = reset_db!(
      server_pubkey: "SRVPUB", server_ip: "10.8.0.1",
      endpoint_v4: "203.0.113.5", endpoint_v6: "2001:db8::5",
      listen_port: 51820, mtu: 1420, wg_subnet: "10.8.0.0/24", dns_domain: "vpn"
    )
    id = make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "LAPPUB", psk: "LAPPSK")
    @client = @db[:clients][id: id]
  end

  # The second PreUp — the one that actually starts the relay.
  def hook_of(conf)
    conf.lines.grep(/^PreUp = umask/).first.to_s.chomp
  end

  def build(flavor, **opts)
    Naaf::ConfigBuilder.new(@db, @client).render(flavor, **opts)
  end

  # Every PreUp/PostDown value the config carries, in order. All hook assertions
  # run against these and never against the whole file: the SNI comment block
  # legitimately names --tls-sni-override and --tls-verify-certificate, so a
  # whole-file search would pass no matter what the hooks actually contain.
  def hooks(conf)
    conf.scan(/^(?:PreUp|PostDown) = (.*)$/).flatten
  end

  # `bash -n` parses without executing anything. Returns nil when the hook is
  # valid shell, the parser's complaint otherwise. This is what stands in for
  # actually running wg-quick: it catches every quoting bug and any stray
  # newline that would split one directive into two.
  def bash_error(script)
    Tempfile.create("naaf-hook") do |f|
      f.write(script)
      f.flush
      out = IO.popen(["bash", "-n", f.path], err: [:child, :out], &:read)
      $?.success? ? nil : out.strip
    end
  end

  # The warn-severity records Console emitted during the block. Swapping the
  # logger keeps the assertion honest — otherwise the only evidence a warning
  # exists is a line printed into the suite's own output.
  def captured_warnings
    capture = Console::Capture.new
    previous = Console.logger
    Console.logger = Console::Logger.new(capture)
    yield
    capture.records.select { |r| r[:severity] == :warn }
  ensure
    Console.logger = previous
  end

  # The message of the ArgumentError render raised, or nil if it did not raise.
  def render_error(flavor)
    build(flavor)
    nil
  rescue ArgumentError => e
    e.message
  end

  it "split has a DNS line and routes only the vpn subnet" do
    c = build("split")
    expect(c).to be(:include?, "DNS = 10.8.0.1")
    expect(c).to be(:include?, "Endpoint = 203.0.113.5:51820")
    expect(c).to be(:include?, "AllowedIPs = 10.8.0.0/24")
    expect(c).to be(:include?, "MTU = 1420")
    expect(c.include?("0.0.0.0/0")).to be == false
  end

  it "split-nodns is split without the DNS line" do
    c = build("split-nodns")
    expect(c.include?("DNS =")).to be == false
    expect(c).to be(:include?, "AllowedIPs = 10.8.0.0/24")
    expect(c).to be(:include?, "MTU = 1420")
  end

  it "full routes 0.0.0.0/0 and never ::/0 (interior is IPv4-only)" do
    c = build("full")
    # Assert on the actual AllowedIPs line — the template's explanatory comment
    # legitimately mentions ::/0, so a bare string search would false-positive.
    expect(c[/^AllowedIPs = .*/]).to be == "AllowedIPs = 0.0.0.0/0"
    expect(c).to be(:include?, "DNS = 10.8.0.1")
  end

  it "uses the placeholder when no private key is supplied" do
    expect(build("split")).to be(:include?, "REPLACE_WITH_YOUR_PRIVATE_KEY")
  end

  it "injects the one-shot private key when supplied, and the DB never stores one" do
    expect(build("split", private_key: "ONESHOTPRIV")).to be(:include?, "PrivateKey = ONESHOTPRIV")
    expect(@db[:clients].columns.include?(:privkey)).to be == false
    expect(@db[:clients].columns.include?(:private_key)).to be == false
  end

  it "folds global and per-client extra routes into split AllowedIPs" do
    @db[:extra_routes].insert(client_id: nil, cidr: "192.168.9.0/24")
    @db[:extra_routes].insert(client_id: @client[:id], cidr: "10.99.0.0/16")
    c = build("split")
    expect(c).to be(:include?, "192.168.9.0/24")
    expect(c).to be(:include?, "10.99.0.0/16")
  end

  it "folds enabled site networks into split AllowedIPs and dedups extra_routes" do
    make_site(@db, name: "unifi", networks: ["192.168.1.0/24", "10.0.0.0/16"])
    make_site(@db, name: "off", enabled: false, networks: ["172.16.0.0/12"])
    @db[:extra_routes].insert(client_id: nil, cidr: "192.168.1.0/24")
    line = build("split")[/^AllowedIPs = .*/]
    expect(line).to be(:include?, "192.168.1.0/24")
    expect(line).to be(:include?, "10.0.0.0/16")
    expect(line.include?("172.16.0.0/12")).to be == false
    expect(line.scan("192.168.1.0/24").length).to be == 1
  end

  it "rejects unknown flavors" do
    expect { build("bogus") }.to raise_exception(ArgumentError, message: be =~ /unknown flavor/)
  end

  it "splits endpoint into address and address:port so the wss:// URL can use its own port" do
    b = Naaf::ConfigBuilder.new(@db, @client)
    expect(b.endpoint_addr).to be == "203.0.113.5"
    expect(b.endpoint).to be == "203.0.113.5:51820"
    expect(b.endpoint_addr(family: :v6)).to be == "[2001:db8::5]"
    expect(b.endpoint(family: :v6)).to be == "[2001:db8::5]:51820"
  end

  # ---- wstunnel flavors ----------------------------------------------------

  it "split-ws dials the local relay while the hook holds the real endpoint" do
    with_wstunnel do
      c = build("split-ws")
      expect(c).to be(:include?, "Endpoint = 127.0.0.1:51820")
      expect(c).to be(:include?, "MTU = 1280")
      expect(c).to be(:include?, "AllowedIPs = 10.8.0.0/24")
      expect(c).to be(:include?, "wss://203.0.113.5:443")
      expect(c).to be(:include?, "DNS = 10.8.0.1")
      # No full-tunnel-over-wstunnel flavor exists, and split must not grow one
      # by accident: 0.0.0.0/0 would capture wstunnel's own TCP session.
      expect(c.include?("0.0.0.0/0")).to be == false
      # WireGuard must dial the relay, never the endpoint directly.
      expect(c.include?("Endpoint = 203.0.113.5")).to be == false
    end
  end

  it "split-ws-nodns is split-ws minus the DNS line, hooks identical" do
    with_wstunnel do
      ws = build("split-ws")
      nd = build("split-ws-nodns")
      expect(nd.include?("DNS =")).to be == false
      expect(nd).to be(:include?, "MTU = 1280")
      expect(nd).to be(:include?, "Endpoint = 127.0.0.1:51820")
      expect(hooks(nd)).to be == hooks(ws)
    end
  end

  it "emits exactly three hooks and every one of them parses as shell" do
    # Cover the shapes that add tokens to the command: verification, an SNI
    # override, and both together. A quoting bug is likeliest where the string
    # grows.
    [
      {},
      {"NAAF_ACME_ENABLED" => "1"},
      {"NAAF_WSTUNNEL_SNI" => "www.example.com"},
      {"NAAF_WSTUNNEL_TLS_VERIFY" => "on", "NAAF_ACME_ENABLED" => "1", "NAAF_WSTUNNEL_SNI" => "www.example.com"}
    ].each do |env|
      with_wstunnel(env) do
        Naaf::ConfigBuilder::WS_FLAVORS.each do |flavor|
          h = hooks(build(flavor))
          expect(h.size).to be == 3
          h.each { |hook| expect(bash_error(hook)).to be_nil }
        end
      end
    end
  end

  it "keeps out of every hook the two things wg-quick would mangle" do
    with_wstunnel("NAAF_WSTUNNEL_SNI" => "www.example.com") do
      hooks(build("split-ws")).each do |hook|
        # `#` comments out the rest of the line in a wg.conf AND in the shell
        # wg-quick eval's the hook in.
        expect(hook.include?("#")).to be == false
        # %i is the config name on Linux but the utunN device on macOS, and %I
        # exists only on macOS — neither survives both platforms.
        expect(hook.include?("%i")).to be == false
        expect(hook.include?("%I")).to be == false
      end
    end
  end

  it "pins the relay to 127.0.0.1 and never delays the local bind" do
    with_wstunnel do
      preup = hooks(build("split-ws"))[1]
      local = preup[/-L '([^']*)'/, 1]
      # Never the short `udp://51820:...` form: if wstunnel's default bind for it
      # is 0.0.0.0, every laptop running this flavor is an open UDP relay from
      # its LAN into the hub's WireGuard port.
      expect(local).to be(:start_with?, "udp://127.0.0.1:")
      expect(local).to be == "udp://127.0.0.1:51820:127.0.0.1:51820?timeout_sec=0"
      # -c 1 would hold the local bind until the server answers, turning an
      # unreachable hub into an interface that never binds at all.
      expect(preup.include?("-c 1")).to be == false
      expect(preup).to be(:include?, "umask 077;")
      expect(preup).to be(:include?, "nohup wstunnel client ")
      expect(preup).to be(:include?, ">/var/log/naaf-wstunnel.log 2>&1 & echo $! >/var/run/naaf-wstunnel-51820.pid")
    end
  end

  it "guards on PATH and reaps the relay through the pidfile" do
    with_wstunnel do
      guard, _, postdown = hooks(build("split-ws"))
      # Without this the missing binary fails only in the child and the user
      # gets an interface that silently never handshakes.
      expect(guard).to be(:start_with?, "command -v wstunnel >/dev/null 2>&1 || {")
      expect(guard).to be(:include?, "exit 1; }")
      # One machine, one WS_LOCAL_PORT. The second `up` must fail here rather
      # than let its relay die on EADDRINUSE while `echo $! >PIDFILE` records the
      # dead pid over the live one — that mispairing is what orphaned the first
      # relay past every `wg-quick down`.
      expect(guard).to be(:include?, "in *wstunnel)")
      expect(guard).to be(:include?, "already running")
      # Both `|| true` are load-bearing under wg-quick's `set -e`.
      expect(postdown).to be(:include?, "p=$(cat /var/run/naaf-wstunnel-51820.pid 2>/dev/null || true)")
      expect(postdown).to be(:include?, 'kill "$p" 2>/dev/null || true')
      # The glob covers a full path, a bare basename, and Linux's 15-char comm
      # truncation. Do not simplify it to an equality test.
      expect(postdown).to be(:include?, "in *wstunnel)")
      expect(postdown).to be(:end_with?, "rm -f /var/run/naaf-wstunnel-51820.pid")
    end
  end

  # `bash -n` cannot tell a guard that refuses from a guard that does nothing, so
  # run the emitted guard for real. The only edit is WS_PIDFILE -> a writable
  # path (/var/run needs root); the logic under test is verbatim.
  #
  # `wstunnel` is a SYMLINK to /bin/sleep, not a copy: both platforms take comm
  # from the path handed to execve, so `ps -p N -o comm=` really reports a name
  # ending in "wstunnel" — which is the whole thing the `case` glob keys off —
  # and a copy of a signed system binary is SIGKILLed on arm64 macOS.
  it "the guard refuses a second ws config while the first relay is alive" do
    Dir.mktmpdir("naaf-guard") do |dir|
      bin = File.join(dir, "wstunnel")
      File.symlink("/bin/sleep", bin)
      pidfile = File.join(dir, "relay.pid")

      guard = with_wstunnel { hooks(build("split-ws")).first }
        .gsub(Naaf::ConfigBuilder::WS_PIDFILE, pidfile)

      # -e, because wg-quick runs `(eval "$hook")` under `set -e`: the hook has to
      # end 0 on the happy path even though `ps -p 0` exits 1 and the `case`
      # matches nothing.
      run = lambda do
        out = IO.popen({"PATH" => "#{dir}:#{ENV["PATH"]}"}, ["bash", "-ec", guard], err: [:child, :out], &:read)
        [$?.exitstatus, out]
      end

      # No pidfile at all: the first `up` proceeds.
      expect(run.call.first).to be == 0

      pid = Process.spawn(bin, "30", out: File::NULL, err: File::NULL)
      begin
        File.write(pidfile, "#{pid}\n")
        status, out = run.call
        # Loud, and before the PreUp that would have overwritten the pidfile with
        # a pid whose wstunnel is about to die on EADDRINUSE.
        expect(status).to be == 1
        expect(out).to be(:include?, "already running")
      ensure
        Process.kill("KILL", pid)
        Process.wait(pid)
      end

      # A stale pidfile is not a collision — the relay died, and `up` must work.
      expect(run.call.first).to be == 0
    end
  end

  it "carries the path prefix and lets NAAF_WSTUNNEL_PORT move only the wss:// port" do
    with_wstunnel("NAAF_WSTUNNEL_PATH_PREFIX" => "aBc-123_x.y~z", "NAAF_WSTUNNEL_PORT" => "8443") do
      c = build("split-ws")
      preup = hooks(c)[1]
      expect(preup).to be(:include?, "-P aBc-123_x.y~z ")
      expect(preup).to be(:include?, "wss://203.0.113.5:8443")
      # The WireGuard port is what the relay forwards TO; it is not the TLS port.
      expect(preup).to be(:include?, ":127.0.0.1:51820?timeout_sec=0")
      expect(c).to be(:include?, "Endpoint = 127.0.0.1:51820")
      expect(c.include?("Endpoint = 203.0.113.5")).to be == false
    end
  end

  it "dials endpoint_host when the settings row has one" do
    # endpoint_host is how a box is migrated by repointing DNS, so the wss:// URL
    # has to follow it and not the detected address.
    @db[:settings].update(endpoint_host: "vpn.example.com")
    with_wstunnel do
      expect(hooks(build("split-ws"))[1]).to be(:include?, "wss://vpn.example.com:443")
    end
  end

  it "refuses an endpoint address that is not a bare hostname or IPv4 literal" do
    # A leading `-` becomes an argv flag; brackets are bash pathname-expansion
    # metacharacters in the unquoted wss:// word. The bracketed v6 literal is on
    # this list on purpose: wstunnel_locals calls endpoint_addr with the default
    # family: :v4, so the ws flavors cannot produce one, and admitting a form the
    # code cannot reach is what left the bracket hazard sitting there.
    ["vpn example.com", "vpn.example.com; sh", "$(id).example.com", "a" * 254,
      "-x", "x.", ".", "-", "a..b", "[2001:db8::5]"].each do |bad|
      @db[:settings].update(endpoint_host: bad)
      with_wstunnel do
        expect(render_error("split-ws")).to be =~ /endpoint address/
      end
    end
  end

  it "refuses a v6-only box outright rather than emitting a bracketed host" do
    @db[:settings].update(endpoint_host: nil, endpoint_v4: nil)
    with_wstunnel do
      expect(render_error("split-ws")).to be =~ /endpoint address/
    end
  end

  it "composes SNI override and verification per NAAF_WSTUNNEL_TLS_VERIFY" do
    cover = "www.example.com"
    [
      # verify, acme, sni, expect --tls-verify-certificate?
      ["auto", "0", nil, false],
      ["auto", "0", cover, false],
      ["auto", "1", nil, true],
      # auto means "the dialed name and the served certificate agree"; an SNI
      # override is exactly what breaks that, so auto drops verification.
      ["auto", "1", cover, false],
      ["on", "0", nil, true],
      ["on", "1", nil, true],
      # The strong form: a cover domain you own, holding a real DNS-01 cert.
      ["on", "1", cover, true],
      ["off", "0", nil, false],
      ["off", "0", cover, false],
      ["off", "1", nil, false],
      ["off", "1", cover, false]
    ].each do |verify, acme, sni, want_verify|
      env = {"NAAF_WSTUNNEL_TLS_VERIFY" => verify, "NAAF_ACME_ENABLED" => acme, "NAAF_WSTUNNEL_SNI" => sni}
      with_wstunnel(env) do
        preup = hooks(build("split-ws"))[1]
        expect(preup.include?("--tls-verify-certificate")).to be == want_verify
        expect(preup.include?("--tls-sni-override #{cover}")).to be == !sni.nil?
      end
    end
  end

  it "refuses only the broken TLS cell: verify on, self-signed, SNI overridden" do
    env = {"NAAF_WSTUNNEL_TLS_VERIFY" => "on", "NAAF_ACME_ENABLED" => "0", "NAAF_WSTUNNEL_SNI" => "www.example.com"}
    with_wstunnel(env) do
      expect(render_error("split-ws")).to be =~ /real certificate/
    end
  end

  it "rejects an unrecognised NAAF_WSTUNNEL_TLS_VERIFY instead of guessing" do
    with_wstunnel("NAAF_WSTUNNEL_TLS_VERIFY" => "yes") do
      expect(render_error("split-ws")).to be =~ /auto, on or off/
    end
  end

  # The `bash -n` and no-`#` examples above only cover values they happen to
  # pass, and they do pass some of these: "x\nPostUp = sh" is perfectly valid
  # shell. Only the whitelist stops it, so test the whitelist directly.
  it "refuses every SNI that could escape the command wg-quick evals as root" do
    # "-x" is not a quoting problem, it is an argv one: `--tls-sni-override -x`
    # makes wstunnel exit with "unexpected argument", in the child, where `&`
    # hides it — the interface comes up and never handshakes. "." / "-" / "a..b"
    # / "x." are simply not names; app.rb's HOSTNAME rejects all of them and
    # there is no reason this path should be laxer than the Settings form.
    ["x $(id)", "x; sh", "x\nPostUp = sh", "x#y", "x`id`", "x&y", "x|y", "x>y", "x'y", 'x"y', "*",
      "a" * 254, "-x", "x.", ".", "-", "a..b"].each do |bad|
      with_wstunnel("NAAF_WSTUNNEL_SNI" => bad) do
        expect(render_error("split-ws")).to be =~ /NAAF_WSTUNNEL_SNI is malformed/
      end
    end
  end

  it "refuses every path prefix that could escape the same command" do
    # "~root" is the leading-character case: bash tilde-expands it in the
    # unquoted `-P` word, so the client would dial /var/root and every ws config
    # on the box would fail the upgrade. Mid-word `~` is inert and stays legal.
    ["x $(id)", "x; sh", "x\nPostUp = sh", "x#y", "x`id`", "x/y", "x&y", "*", "a" * 129,
      "~root", "~", "-P", "._x"].each do |bad|
      with_wstunnel("NAAF_WSTUNNEL_PATH_PREFIX" => bad) do
        expect(render_error("split-ws")).to be =~ /NAAF_WSTUNNEL_PATH_PREFIX/
      end
    end
  end

  it "never repeats the rejected path prefix back into the error message" do
    with_wstunnel("NAAF_WSTUNNEL_PATH_PREFIX" => "sekrit prefix") do
      expect(render_error("split-ws").include?("sekrit")).to be == false
    end
  end

  it "refuses a non-numeric or out-of-range wstunnel port" do
    ["0", "65536", "443; sh", "http", "0x1bb"].each do |bad|
      with_wstunnel("NAAF_WSTUNNEL_PORT" => bad) do
        expect(render_error("split-ws").nil?).to be == false
      end
    end
    # An empty value is not a bad value: Config[] collapses it to the default.
    with_wstunnel("NAAF_WSTUNNEL_PORT" => "") do
      expect(build("split-ws")).to be(:include?, "wss://203.0.113.5:443")
    end
  end

  it "refuses an out-of-range listen_port from the settings row" do
    @db[:settings].update(listen_port: 0)
    with_wstunnel do
      expect(render_error("split-ws")).to be =~ /listen_port must be 1-65535/
    end
  end

  it "folds extra routes into split-ws and leaves full at exactly 0.0.0.0/0" do
    @db[:extra_routes].insert(client_id: nil, cidr: "192.168.9.0/24")
    @db[:extra_routes].insert(client_id: @client[:id], cidr: "10.99.0.0/16")
    with_wstunnel do
      c = build("split-ws")
      expect(c[/^AllowedIPs = .*/]).to be == "AllowedIPs = 10.8.0.0/24, 192.168.9.0/24, 10.99.0.0/16"
    end
    # conf_full.erb now renders `allowed` instead of a hardcoded literal, so pin
    # that extra routes still cannot leak into the full-tunnel line.
    expect(build("full")[/^AllowedIPs = .*/]).to be == "AllowedIPs = 0.0.0.0/0"
  end

  # param_cidr accepts "0.0.0.0/0", so "give everyone a default route" is one
  # form submission away — and it turns every ws config into the
  # full-tunnel-over-wstunnel arrangement WS_FLAVORS says cannot exist. wg-quick
  # takes add_default(), whose `not fwmark` rule exempts the kernel WireGuard
  # socket and not the userspace relay, so the transport is routed into the
  # tunnel it carries AND suppress_prefixlength 0 takes the client's own default
  # route with it. Nothing downstream errors: the guard hook only tests PATH.
  it "refuses a default extra route for the ws flavors and still allows it for split" do
    @db[:extra_routes].insert(client_id: nil, cidr: "0.0.0.0/0")
    with_wstunnel do
      Naaf::ConfigBuilder::WS_FLAVORS.each do |flavor|
        expect(render_error(flavor)).to be =~ /default route/
      end
    end
    # Unchanged for plain split: the kernel WireGuard socket IS fwmark-exempt on
    # that path, so split plus a /0 route is a working full tunnel today.
    expect(build("split")[/^AllowedIPs = .*/]).to be == "AllowedIPs = 10.8.0.0/24, 0.0.0.0/0"
  end

  # param_cidr is the only writer the form has, so an unparseable row means the
  # database was edited by hand or by a future migration. A route the audit
  # cannot parse is a route it cannot clear, and for the ws flavors an
  # unaudited AllowedIPs is exactly the line that captures the relay's own
  # session — so refuse rather than emit it and hope.
  it "refuses an unparseable extra route for the ws flavors rather than auditing nothing" do
    @db[:extra_routes].insert(client_id: nil, cidr: "not-a-cidr")
    with_wstunnel do
      Naaf::ConfigBuilder::WS_FLAVORS.each do |flavor|
        expect(render_error(flavor)).to be =~ /AllowedIPs route not-a-cidr is not a valid CIDR/
      end
    end
  end

  # The weaker shape, and the likelier one: no /0 anywhere, just a route that
  # happens to contain the hub. wg-quick puts `ip route add 203.0.113.0/24 dev
  # wg0` in the main table, in front of wstunnel's own session.
  it "refuses a ws route that merely covers the endpoint address" do
    @db[:extra_routes].insert(client_id: nil, cidr: "203.0.113.0/24")
    with_wstunnel do
      expect(render_error("split-ws")).to be =~ /contains the endpoint address/
      # A route next to the endpoint, not containing it, is fine.
      @db[:extra_routes].update(cidr: "203.0.114.0/24")
      expect(build("split-ws")[/^AllowedIPs = .*/]).to be == "AllowedIPs = 10.8.0.0/24, 203.0.114.0/24"
    end
  end

  it "refuses a site CIDR that covers the endpoint address for the ws flavors" do
    make_site(@db, name: "bad", networks: ["203.0.113.0/24"])
    with_wstunnel do
      expect(render_error("split-ws")).to be =~ /contains the endpoint address/
    end
  end

  it "warns but still renders plain split when a route covers the endpoint address" do
    # The same route breaks plain split — WireGuard's own packets to the hub go
    # into wg0 — but that hazard predates the ws flavors and is a false alarm
    # whenever endpoint_host resolves somewhere other than endpoint_v4, so
    # refusing would break a config that renders today. Warn, do not raise.
    @db[:extra_routes].insert(client_id: nil, cidr: "203.0.113.0/24")
    warned = captured_warnings do
      expect(build("split")[/^AllowedIPs = .*/]).to be == "AllowedIPs = 10.8.0.0/24, 203.0.113.0/24"
    end
    expect(warned.size).to be == 1
    expect(warned.first[:route]).to be == "203.0.113.0/24"
  end

  it "refuses a ws route covering endpoint_v6 as well" do
    @db[:extra_routes].insert(client_id: nil, cidr: "2001:db8::/32")
    with_wstunnel do
      expect(render_error("split-ws")).to be =~ /contains the endpoint address/
    end
  end

  it "still renders the ws flavors when no endpoint address is known to cover" do
    # endpoint_host with neither literal: the server cannot resolve the name, so
    # there is nothing to compare against and the audit must not invent a reason
    # to refuse.
    @db[:settings].update(endpoint_host: "vpn.example.com", endpoint_v4: nil, endpoint_v6: nil)
    @db[:extra_routes].insert(client_id: nil, cidr: "203.0.113.0/24")
    with_wstunnel do
      expect(build("split-ws")[/^AllowedIPs = .*/]).to be == "AllowedIPs = 10.8.0.0/24, 203.0.113.0/24"
    end
  end

  it "hides the ws flavors entirely unless NAAF_WSTUNNEL_ENABLED=1" do
    expect(Naaf::ConfigBuilder.wstunnel?).to be == false
    expect(Naaf::ConfigBuilder.wstunnel_ready?).to be == false
    expect(Naaf::ConfigBuilder.available_flavors).to be == %w[split split-nodns full]
    expect(Naaf::ConfigBuilder.available?("split-ws")).to be == false
    expect(Naaf::ConfigBuilder.available?("split-ws-nodns")).to be == false
    expect(render_error("split-ws")).to be =~ /NAAF_WSTUNNEL_ENABLED/
    # FLAVORS is the vocabulary and never varies with the environment; only
    # availability does. Nothing here may be a constant frozen at load.
    expect(Naaf::ConfigBuilder::FLAVORS.size).to be == 5
    with_wstunnel do
      expect(Naaf::ConfigBuilder::FLAVORS.size).to be == 5
      expect(Naaf::ConfigBuilder.wstunnel?).to be == true
      expect(Naaf::ConfigBuilder.wstunnel_ready?).to be == true
      expect(Naaf::ConfigBuilder.available_flavors).to be == Naaf::ConfigBuilder::FLAVORS
      expect(Naaf::ConfigBuilder.available?("split-ws")).to be == true
    end
  end

  it "raises rather than emitting a config when 65-wstunnel wrote no prefix" do
    with_wstunnel("NAAF_WSTUNNEL_PATH_PREFIX" => nil) do
      expect(Naaf::ConfigBuilder.wstunnel?).to be == true
      # Enabled but unprovisioned — the UI shows a banner off exactly this.
      expect(Naaf::ConfigBuilder.wstunnel_ready?).to be == false
      expect(render_error("split-ws")).to be =~ /NAAF_WSTUNNEL_PATH_PREFIX/
    end
  end

  it "has a template on disk for every flavor" do
    # Template-per-flavor is deliberate: this is a security artifact whose value
    # is that one flat file shows exactly what a client gets. This is the cheap
    # structural guard that keeps the set honest.
    Naaf::ConfigBuilder::FLAVORS.each do |flavor|
      path = File.expand_path("../views/conf_#{flavor.tr("-", "_")}.erb", __dir__)
      expect(File.file?(path)).to be == true
    end
  end

  # The DNS deadlock. The ws flavors point DNS at the tunnel's own resolver, and
  # wstunnel resolves the endpoint lazily — on the first datagram, by which time
  # wg-quick's set_dns has already repointed DNS into a tunnel that cannot come
  # up until wstunnel connects. Observed in production before this flag existed:
  # the client sat in "Opening TCP connection" on a backoff and never handshook.
  it "pins a resolver reachable without the tunnel, breaking the DNS deadlock" do
    with_wstunnel do
      expect(hook_of(build("split-ws"))).to be(:include?, "--dns-resolver dns://1.1.1.1")
    end
  end

  # "off", never blank. Config#[] treats an empty value as "unset" and falls
  # through to DEFAULTS, so a blank key would silently keep emitting the flag —
  # an opt-out that looks set and does nothing. Both halves are asserted because
  # the blank case is the one that reads as if it should work.
  it "omits the resolver flag for off, and NOT for a blank value" do
    with_wstunnel("NAAF_WSTUNNEL_DNS_RESOLVER" => "off") do
      expect(hook_of(build("split-ws")).include?("--dns-resolver")).to be == false
    end
    with_wstunnel("NAAF_WSTUNNEL_DNS_RESOLVER" => "") do
      expect(hook_of(build("split-ws"))).to be(:include?, "--dns-resolver dns://1.1.1.1")
    end
  end

  it "accepts the resolver forms wstunnel understands" do
    ["dns://9.9.9.9", "dns://1.1.1.1:5353", "dns+https://dns.google/dns-query"].each do |r|
      with_wstunnel("NAAF_WSTUNNEL_DNS_RESOLVER" => r) do
        expect(hook_of(build("split-ws"))).to be(:include?, "--dns-resolver #{r}")
      end
    end
  end

  # This lands in an unquoted argv word inside a command wg-quick runs AS ROOT on
  # the client, and Config[] prefers ENV — so it gets the same whitelist every
  # other value on that path already gets. A bare address is rejected too:
  # wstunnel wants a scheme, and accepting one would emit a flag it cannot parse.
  it "refuses a resolver that could break out of the hook" do
    bad = ["1.1.1.1", "ftp://1.1.1.1", "-dns://1.1.1.1", "dns://1.1.1.1 --foo",
      "dns://1.1.1.1;id", "dns://1.1.1.1" + "|sh", "dns://" + "$(id)",
      "dns://1.1.1.1\nPostUp = sh"]
    bad.each do |value|
      with_wstunnel("NAAF_WSTUNNEL_DNS_RESOLVER" => value) do
        expect(render_error("split-ws")).to be =~ /DNS_RESOLVER/
      end
    end
  end
end
