# frozen_string_literal: true

require_relative "helper"
require "json"

# Point the helper's wg-conf write at a throwaway dir BEFORE loading the
# script: SOCKET_PATH / WG_CONF / WG_IF are constants assigned at load.
ENV["NAAF_WG_CONF_DIR"] ||= Dir.mktmpdir("naaf-helper-wg-")

HELPER_SRC = File.expand_path("../bin/naaf-helper", __dir__)
load HELPER_SRC unless Object.private_method_defined?(:handle)

describe "bin/naaf-helper" do
  def run!(*argv, stdin: nil)
    @run_calls << {argv: argv, stdin: stdin}
    cmd = argv[0, 2]
    return "PRIV\n" if cmd == ["wg", "genkey"]
    return "PUB\n" if cmd == ["wg", "pubkey"]
    return "PSK\n" if cmd == ["wg", "genpsk"]
    return "DUMP\n" if argv == ["wg", "show", WG_IF, "dump"]
    return @exit_dump.to_s if argv == ["wg", "show", EXIT_IF, "dump"]
    return @addr_show.to_s if argv == ["ip", "-4", "-o", "addr", "show", "dev", WG_IF]
    return @all_addr_show.to_s if argv == ["ip", "-4", "-o", "addr", "show"]
    return @route_show.to_s if argv == ["ip", "-4", "route", "show", "proto", SITE_ROUTE_PROTO, "dev", WG_IF]
    if argv == ["ip", "-4", "route", "show", "table", "159"]
      if @missing_table159
        raise "ip failed (2): Error: ipv4: FIB table does not exist.\nDump terminated"
      end
      return @table159.to_s
    end
    if argv == ["ip", "route", "flush", "table", "159"]
      raise "ip failed (2): Flush terminated" if @missing_table159
      return ""
    end
    return @rules.to_s if argv == ["ip", "-4", "rule", "show"]
    return @default_route.to_s if argv == ["ip", "-4", "route", "show", "default"]
    if argv[0, 4] == ["ip", "link", "show", "dev"]
      raise "ip failed (1): Device \"#{argv[4]}\" does not exist." unless @links.include?(argv[4])
      return ""
    end
    if argv[0, 3] == ["ip", "link", "add"]
      @links << argv[3]
      return ""
    end
    if argv[0, 3] == ["ip", "link", "del"]
      @links.delete(argv[3])
      return ""
    end
    ""
  end

  def steal_targets = @steal_targets || []

  # Shaped like real `ip -4 -o addr show` / `ip -4 route show` output, trailing
  # junk included: the helper parses those lines with a regex and a field split,
  # so a stub that only emits the bare address would not exercise the parse.
  def addr_line(cidr) = "4: #{WG_IF}    inet #{cidr} scope global #{WG_IF}\\       valid_lft forever preferred_lft forever\n"

  # iproute2 suppresses the fields it was filtered on, so `ip -4 route show
  # proto 158 dev wg0` prints neither `proto` nor `dev` back.
  def route_line(dst) = "#{dst} scope link\n"

  def ip_calls = @run_calls.map { |c| c[:argv] }.select { |a| a.first == "ip" }

  def addr_writes = ip_calls.select { |a| a[0, 2] == ["ip", "addr"] }

  def route_writes = ip_calls.select { |a| a[0, 2] == ["ip", "route"] }

  def apply_line(**extra)
    JSON.generate({
      cmd: "apply",
      wg_conf: "[Interface]\nPrivateKey = x\n",
      nft_ruleset: "table inet naaf {}\n"
    }.merge(extra))
  end

  def addr_line_on(dev, cidr) = "4: #{dev}    inet #{cidr} scope global #{dev}\\       valid_lft forever preferred_lft forever\n"

  def exit_payload(**over)
    {
      "conf" => "[Interface]\nPrivateKey = EXITPRIV\n\n[Peer]\nPublicKey = EXITPUB\nAllowedIPs = 0.0.0.0/0\nEndpoint = engage.cloudflareclient.com:2408\nPersistentKeepalive = 25\n",
      "dev" => EXIT_IF,
      "address" => "172.16.0.2",
      "mtu" => 1280,
      "table" => 159,
      "mark" => 159,
      "routes" => [
        {"dst" => "192.168.1.0/24", "dev" => WG_IF},
        {"dst" => "192.168.2.2/32", "dev" => WG_IF},
        {"dst" => "default", "dev" => EXIT_IF}
      ],
      "rules" => [
        {"pref" => 15800, "spec" => ["fwmark", "159", "lookup", "main"]},
        {"pref" => 15850, "spec" => ["iif", WG_IF, "to", "10.8.0.0/24", "lookup", "main"]},
        {"pref" => 15900, "spec" => ["iif", WG_IF, "lookup", "159"]}
      ]
    }.merge(over)
  end

  def rule_writes = ip_calls.select { |a| a[0, 3] == ["ip", "-4", "rule"] }

  def wg_quick_calls = @run_calls.map { |c| c[:argv] }.select { |a| a.first == "wg-quick" }

  before do
    @run_calls = []
    @links = Set.new
  end

  it "answers ping without touching the kernel" do
    expect(handle(%({"cmd":"ping"}))).to be == {ok: true}
    expect(@run_calls).to be(:empty?)
  end

  it "dispatches genkeys and dump through run!, never a shell string" do
    keys = handle(%({"cmd":"genkeys"}))
    expect(keys).to be == {private_key: "PRIV", public_key: "PUB", preshared_key: "PSK"}
    expect(handle(%({"cmd":"dump"}))).to be == {dump: "DUMP\n"}
    @run_calls.each { |c| expect(c[:argv]).to be_a(Array) }
  end

  it "refuses an unknown command rather than evaling it" do
    expect(handle(%({"cmd":"rm"}))[:error]).to be == "unknown command"
  end

  it "returns a parse error as {error:} so a bad line cannot crash the loop" do
    expect(handle("not-json")[:error].nil?).to be == false
  end

  it "applies wg + nft and treats missing routes/addresses as empty" do
    expect(handle(apply_line)).to be == {ok: true}
    argv = @run_calls.map { |c| c[:argv] }
    expect(argv).to be(:include?, ["wg-quick", "strip", WG_IF])
    expect(argv.any? { |a| a[0, 2] == ["wg", "syncconf"] }).to be == true
    expect(argv.any? { |a| a[0, 3] == ["nft", "-c", "-f"] }).to be == true
    expect(argv.any? { |a| a[0, 2] == ["nft", "-f"] && a[1] != "-c" }).to be == true
  end

  it "refuses an oversized wg_conf or nft_ruleset before writing anything" do
    big = "x" * 1_000_001
    expect(handle(apply_line(wg_conf: big))[:error]).to be == "wg_conf too large"
    expect(handle(apply_line(nft_ruleset: big))[:error]).to be == "nft_ruleset too large"
    expect(@run_calls).to be(:empty?)
  end

  it "refuses a default route, even if the form somehow stored one" do
    line = apply_line(routes: [{dst: "0.0.0.0/0", dev: WG_IF}])
    expect(handle(line)[:error]).to be == "invalid site route"
  end

  it "refuses a route or address on any interface but the tunnel" do
    expect(handle(apply_line(routes: [{dst: "192.168.1.0/24", dev: "eth0"}]))[:error])
      .to be == "route must be on #{WG_IF}"
    expect(handle(apply_line(addresses: [{addr: "192.168.2.2", dev: "eth0"}]))[:error])
      .to be == "address must be on #{WG_IF}"
  end

  it "refuses a dest that covers a steal-target (gateway or a local address)" do
    @steal_targets = ["203.0.113.1"]
    expect(handle(apply_line(routes: [{dst: "203.0.113.0/24", dev: WG_IF}]))[:error])
      .to be(:include?, "covers 203.0.113.1")
    expect(handle(apply_line(addresses: [{addr: "203.0.113.1", dev: WG_IF}]))[:error])
      .to be(:include?, "covers 203.0.113.1")
  end

  # Everything below drives the add/delete diff. Every other apply test either
  # raises during validation or passes empty lists, so the diff never actually
  # moved an address or a route: a helper that added nothing, or deleted the
  # wrong thing, would still have gone green.
  describe "address diff" do
    it "adds a site address the tunnel is not carrying yet" do
      @addr_show = addr_line("10.8.0.1/24")
      expect(handle(apply_line(addresses: [{addr: "10.8.0.9", dev: WG_IF}]))).to be == {ok: true}
      expect(addr_writes).to be == [["ip", "addr", "replace", "10.8.0.9/32", "dev", WG_IF]]
    end

    it "drops a /32 the site no longer claims, so a revoked address cannot answer forever" do
      @addr_show = addr_line("10.8.0.1/24") + addr_line("10.8.0.9/32")
      expect(handle(apply_line(addresses: []))).to be == {ok: true}
      expect(addr_writes).to be == [["ip", "addr", "del", "10.8.0.9/32", "dev", WG_IF]]
    end

    it "never deletes the interface's own /24 — that address is proto kernel and is the tunnel" do
      @addr_show = addr_line("10.8.0.1/24") + addr_line("10.8.0.9/32") + addr_line("10.8.0.10/32")
      expect(handle(apply_line(addresses: [{addr: "10.8.0.10", dev: WG_IF}]))).to be == {ok: true}
      deleted = addr_writes.select { |a| a[2] == "del" }.map { |a| a[3] }
      expect(deleted).to be == ["10.8.0.9/32"]
    end

    it "leaves an address that is present and still wanted completely alone" do
      @addr_show = addr_line("10.8.0.1/24") + addr_line("10.8.0.9/32")
      expect(handle(apply_line(addresses: [{addr: "10.8.0.9", dev: WG_IF}]))).to be == {ok: true}
      expect(addr_writes).to be(:empty?)
    end
  end

  describe "route diff" do
    it "adds a desired site route the kernel does not carry yet" do
      expect(handle(apply_line(routes: [{dst: "192.168.10.0/24", dev: WG_IF}]))).to be == {ok: true}
      expect(route_writes).to be ==
        [["ip", "route", "replace", "192.168.10.0/24", "dev", WG_IF, "proto", SITE_ROUTE_PROTO]]
    end

    it "deletes a proto 158 route the site no longer asks for" do
      @route_show = route_line("192.168.10.0/24")
      expect(handle(apply_line(routes: []))).to be == {ok: true}
      expect(route_writes).to be ==
        [["ip", "route", "del", "192.168.10.0/24", "proto", SITE_ROUTE_PROTO, "dev", WG_IF]]
    end

    it "leaves an unchanged route in place instead of churning it on every apply" do
      @route_show = route_line("192.168.10.0/24")
      expect(handle(apply_line(routes: [{dst: "192.168.10.0/24", dev: WG_IF}]))).to be == {ok: true}
      expect(route_writes).to be(:empty?)
    end

    it "skips a default route found in the kernel's output rather than deleting WAN egress" do
      @route_show = "default via 10.8.0.1\n" + route_line("192.168.10.0/24")
      expect(handle(apply_line(routes: []))).to be == {ok: true}
      expect(route_writes.map { |a| a[3] }).to be == ["192.168.10.0/24"]
    end
  end

  describe "validators" do
    it "accepts a host route and a real prefix, never /0" do
      expect(valid_v4_cidr?("192.168.1.0/24")).to be == true
      expect(valid_v4_cidr?("10.0.0.1/32")).to be == true
      expect(valid_v4_cidr?("0.0.0.0/0")).to be == false
      expect(valid_v4_cidr?("10.0.0.0/0")).to be == false
      expect(valid_v4_cidr?("999.0.0.0/24")).to be == false
      expect(valid_v4_cidr?("2001:db8::/32")).to be == false
    end

    it "treats a bad octet as not-an-address" do
      expect(valid_v4?("192.168.1.1")).to be == true
      expect(valid_v4?("192.168.1.256")).to be == false
      expect(valid_v4?("not-an-ip")).to be == false
    end
  end

  describe "internet exit" do
    # The parent group overrides steal_targets so site-route tests can name a
    # victim IP without stubbing `ip`. That seam hides a broken
    # local_v4_except_wg, so this group binds the real method.
    def steal_targets
      Object.instance_method(:steal_targets).bind_call(self)
    end

    it "filters a wg-exit address out of stubbed ip -4 -o addr show output" do
      @all_addr_show = addr_line_on("eth0", "203.0.113.5/24") +
        addr_line_on(WG_IF, "10.8.0.1/24") +
        addr_line_on(EXIT_IF, "172.16.0.2/32")
      expect(local_v4_except_wg).to be == ["203.0.113.5"]
    end

    it "applies the same exit payload twice without the steal-check self-collision" do
      @all_addr_show = addr_line_on("eth0", "203.0.113.5/24")
      @default_route = "default via 203.0.113.1 dev eth0\n"
      line = apply_line(exit: exit_payload)
      expect(handle(line)).to be == {ok: true}
      @all_addr_show += addr_line_on(EXIT_IF, "172.16.0.2/32")
      expect(handle(line)).to be == {ok: true}
    end

    it "allows a table-159 default on the exit iface and refuses one on wg0" do
      @all_addr_show = addr_line_on("eth0", "203.0.113.5/24")
      expect(handle(apply_line(exit: exit_payload))).to be == {ok: true}
      expect(ip_calls).to be(:include?, ["ip", "route", "replace", "default", "dev", EXIT_IF, "table", "159"])
      bad = exit_payload("routes" => [{"dst" => "default", "dev" => WG_IF}])
      expect(handle(apply_line(exit: bad))[:error]).to be == "default route must be on #{EXIT_IF}"
    end

    it "never runs wg-quick against the exit iface" do
      @all_addr_show = addr_line_on("eth0", "203.0.113.5/24")
      expect(handle(apply_line(exit: exit_payload))).to be == {ok: true}
      expect(wg_quick_calls.any? { |a| a.include?(EXIT_IF) }).to be == false
      expect(@run_calls.map { |c| c[:argv] }.any? { |a| a[0, 2] == ["wg", "setconf"] }).to be == false
      sync = @run_calls.map { |c| c[:argv] }.find { |a| a[0, 3] == ["wg", "syncconf", EXIT_IF] }
      expect(sync.nil?).to be == false
      expect(sync[3].include?("/etc/wireguard")).to be == false
    end

    it "does not churn pref 15850 when iproute2 dumps to before iif" do
      @all_addr_show = addr_line_on("eth0", "203.0.113.5/24")
      @rules = "15800:\tfrom all fwmark 0x9f lookup main\n" \
        "15850:\tfrom all to 10.8.0.0/24 iif #{WG_IF} lookup main\n" \
        "15900:\tfrom all iif #{WG_IF} lookup 159\n"
      expect(handle(apply_line(exit: exit_payload))).to be == {ok: true}
      expect(rule_writes.any? { |a| a.include?("del") }).to be == false
    end

    it "replaces pref 15850 when wg_subnet in the spec changes, instead of leaving the old to" do
      @all_addr_show = addr_line_on("eth0", "203.0.113.5/24")
      @rules = "15800:\tfrom all fwmark 0x9f lookup main\n" \
        "15850:\tfrom all iif #{WG_IF} to 10.8.0.0/24 lookup main\n" \
        "15900:\tfrom all iif #{WG_IF} lookup 159\n"
      payload = exit_payload("rules" => [
        {"pref" => 15800, "spec" => ["fwmark", "159", "lookup", "main"]},
        {"pref" => 15850, "spec" => ["iif", WG_IF, "to", "10.9.0.0/24", "lookup", "main"]},
        {"pref" => 15900, "spec" => ["iif", WG_IF, "lookup", "159"]}
      ])
      expect(handle(apply_line(exit: payload))).to be == {ok: true}
      expect(rule_writes).to be(:include?, ["ip", "-4", "rule", "del", "pref", "15850"])
      expect(rule_writes).to be(:include?,
        ["ip", "-4", "rule", "add", "iif", WG_IF, "to", "10.9.0.0/24", "lookup", "main", "pref", "15850"])
      expect(rule_writes.any? { |a| a.include?("15800") && a.include?("del") }).to be == false
      expect(rule_writes.any? { |a| a.include?("15900") && a.include?("del") }).to be == false
    end

    it "treats a missing exit key as a no-op" do
      @links << EXIT_IF
      @rules = "15800:\tfrom all fwmark 0x9f lookup main\n"
      expect(handle(apply_line)).to be == {ok: true}
      expect(ip_calls).not.to be(:include?, ["ip", "link", "del", EXIT_IF])
      expect(ip_calls).not.to be(:include?, ["ip", "route", "flush", "table", "159"])
      expect(@links).to be(:include?, EXIT_IF)
    end

    it "on down deletes the link, the three prefs, leftover proxy prefs, and flushes table 159" do
      @links << EXIT_IF
      @rules = "15800:\tfrom all fwmark 0x9f lookup main\n" \
        "15850:\tfrom all iif #{WG_IF} to 10.8.0.0/24 lookup main\n" \
        "15870:\tfrom all uidrange 123-123 to 127.0.0.0/8 lookup main\n" \
        "15875:\tfrom all uidrange 123-123 to 10.8.0.0/24 lookup main\n" \
        "15880:\tfrom all uidrange 123-123 lookup 159\n" \
        "15900:\tfrom all iif #{WG_IF} lookup 159\n"
      expect(handle(apply_line(exit: nil))).to be == {ok: true}
      expect(ip_calls).to be(:include?, ["ip", "link", "del", EXIT_IF])
      expect(ip_calls).to be(:include?, ["ip", "route", "flush", "table", "159"])
      [15800, 15850, 15870, 15875, 15880, 15900].each do |pref|
        expect(rule_writes).to be(:include?, ["ip", "-4", "rule", "del", "pref", pref.to_s])
      end
      expect(@links.include?(EXIT_IF)).to be == false
    end

    it "installs proxy uidrange rules from exit.proxy and does not churn them" do
      @all_addr_show = addr_line_on("eth0", "203.0.113.5/24")
      proxy = {"uid" => 123, "locals" => ["127.0.0.0/8", "10.8.0.0/24"]}
      expect(handle(apply_line(exit: exit_payload("proxy" => proxy)))).to be == {ok: true}
      expect(rule_writes).to be(:include?,
        ["ip", "-4", "rule", "add", "uidrange", "123-123", "to", "127.0.0.0/8", "lookup", "main", "pref", "15870"])
      expect(rule_writes).to be(:include?,
        ["ip", "-4", "rule", "add", "uidrange", "123-123", "to", "10.8.0.0/24", "lookup", "main", "pref", "15875"])
      expect(rule_writes).to be(:include?,
        ["ip", "-4", "rule", "add", "uidrange", "123-123", "lookup", "159", "pref", "15880"])

      @run_calls = []
      @rules = "15800:\tfrom all fwmark 0x9f lookup main\n" \
        "15850:\tfrom all to 10.8.0.0/24 iif #{WG_IF} lookup main\n" \
        "15870:\tfrom all to 127.0.0.0/8 uidrange 123-123 lookup main\n" \
        "15875:\tfrom all to 10.8.0.0/24 uidrange 123-123 lookup main\n" \
        "15880:\tfrom all uidrange 123-123 lookup 159\n" \
        "15900:\tfrom all iif #{WG_IF} lookup 159\n"
      expect(handle(apply_line(exit: exit_payload("proxy" => proxy)))).to be == {ok: true}
      expect(rule_writes.any? { |a| a.include?("del") }).to be == false
    end

    it "deletes leftover proxy prefs when exit.proxy is omitted" do
      @all_addr_show = addr_line_on("eth0", "203.0.113.5/24")
      @rules = "15800:\tfrom all fwmark 0x9f lookup main\n" \
        "15850:\tfrom all iif #{WG_IF} to 10.8.0.0/24 lookup main\n" \
        "15870:\tfrom all uidrange 123-123 to 127.0.0.0/8 lookup main\n" \
        "15875:\tfrom all uidrange 123-123 to 10.8.0.0/24 lookup main\n" \
        "15880:\tfrom all uidrange 123-123 lookup 159\n" \
        "15900:\tfrom all iif #{WG_IF} lookup 159\n"
      expect(handle(apply_line(exit: exit_payload))).to be == {ok: true}
      expect(rule_writes).to be(:include?, ["ip", "-4", "rule", "del", "pref", "15870"])
      expect(rule_writes).to be(:include?, ["ip", "-4", "rule", "del", "pref", "15875"])
      expect(rule_writes).to be(:include?, ["ip", "-4", "rule", "del", "pref", "15880"])
      expect(rule_writes.any? { |a| a.include?("15800") && a.include?("del") }).to be == false
    end

    it "refuses a /0 proxy local and a uid of 0" do
      @all_addr_show = addr_line_on("eth0", "203.0.113.5/24")
      bad = exit_payload("proxy" => {"uid" => 123, "locals" => ["0.0.0.0/0", "10.8.0.0/24"]})
      expect(handle(apply_line(exit: bad))[:error]).to be == "invalid exit proxy local"
      root = exit_payload("proxy" => {"uid" => 0, "locals" => ["127.0.0.0/8", "10.8.0.0/24"]})
      expect(handle(apply_line(exit: root))[:error]).to be == "invalid exit proxy uid"
    end

    it "still brings the exit up when table 159 has never been created" do
      @all_addr_show = addr_line_on("eth0", "203.0.113.5/24")
      @missing_table159 = true
      expect(handle(apply_line(exit: exit_payload))).to be == {ok: true}
      expect(ip_calls).to be(:include?,
        ["ip", "route", "replace", "default", "dev", EXIT_IF, "table", "159"])
    end

    it "still tears the exit down when flushing a table that does not exist" do
      @links << EXIT_IF
      @missing_table159 = true
      expect(handle(apply_line(exit: nil))).to be == {ok: true}
      expect(ip_calls).to be(:include?, ["ip", "link", "del", EXIT_IF])
    end

    it "omits exit_dump when the iface is absent and includes it when present" do
      expect(handle(%({"cmd":"dump"}))).to be == {dump: "DUMP\n"}
      @links << EXIT_IF
      @exit_dump = "EXITPRIV\tEXITPUB\n"
      expect(handle(%({"cmd":"dump"}))).to be == {dump: "DUMP\n", exit_dump: "EXITPRIV\tEXITPUB\n"}
    end

    it "refuses an MTU line in the exit conf rather than feeding it to wg syncconf" do
      bad = exit_payload("conf" => "[Interface]\nPrivateKey = X\nMTU = 1280\n")
      expect(handle(apply_line(exit: bad))[:error]).to be == "exit conf is not wg-setconf grammar"
      expect(@run_calls.any? { |c| c[:argv][0, 3] == ["wg", "syncconf", EXIT_IF] }).to be == false
    end
  end
end
