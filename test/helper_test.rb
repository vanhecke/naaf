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
    ""
  end

  def steal_targets = @steal_targets || []

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
