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
    return "DUMP\n" if cmd == ["wg", "show"]
    return @addr_show.to_s if argv == ["ip", "-4", "-o", "addr", "show", "dev", WG_IF]
    return @route_show.to_s if argv == ["ip", "-4", "route", "show", "proto", SITE_ROUTE_PROTO, "dev", WG_IF]
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

  before { @run_calls = [] }

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
end
