# frozen_string_literal: true

require_relative "helper"
require "naaf/zone"

describe Naaf::Zone do
  before do
    @db = reset_db!(server_ip: "10.8.0.1", dns_domain: "vpn")
    make_client(@db, name: "nas", hostname: "nas", wg_ip: "10.8.0.3")
    @db[:dns_records].insert(name: "wiki.vpn", rtype: "A", value: "10.8.0.3", managed: false)
    @db[:dns_records].insert(name: "alias.vpn", rtype: "CNAME", value: "nas.vpn", managed: false)
    @zone = Naaf::Zone.new(@db)
  end

  it "resolves a client fqdn and its bare hostname to the wg ip" do
    expect(@zone.lookup_a("nas.vpn")).to be == "10.8.0.3"
    expect(@zone.lookup_a("nas")).to be == "10.8.0.3"
  end

  it "resolves gateway and the domain apex to the server ip" do
    expect(@zone.lookup_a("gateway.vpn")).to be == "10.8.0.1"
    expect(@zone.lookup_a("vpn")).to be == "10.8.0.1"
  end

  it "answers PTR for client addresses" do
    expect(@zone.lookup_ptr("3.0.8.10.in-addr.arpa")).to be == "nas.vpn."
  end

  it "serves manual A records but ignores non-A record types" do
    expect(@zone.lookup_a("wiki.vpn")).to be == "10.8.0.3"
    expect(@zone.lookup_a("alias.vpn")).to be_nil
  end

  it "normalizes case and a trailing dot on lookups" do
    expect(@zone.lookup_a("NAS.VPN.")).to be == "10.8.0.3"
  end

  it "derives the ordered auto records for clients, gateway and apex" do
    expect(Naaf::Zone.auto_records(@db)).to be == [
      {name: "vpn", rtype: "A", value: "10.8.0.1", source: :apex},
      {name: "nas.vpn", rtype: "A", value: "10.8.0.3", source: :client},
      {name: "nas", rtype: "A", value: "10.8.0.3", source: :client_bare},
      {name: "3.0.8.10.in-addr.arpa", rtype: "PTR", value: "nas.vpn.", source: :ptr},
      {name: "gateway.vpn", rtype: "A", value: "10.8.0.1", source: :gateway}
    ]
  end

  # apply! ends in Zone#reload!; a lookup against a Zone that was built before
  # the write would otherwise keep serving the old hash until restart.
  it "reload! picks up a client added after initialize" do
    make_client(@db, name: "phone", hostname: "phone", wg_ip: "10.8.0.9")
    expect(@zone.lookup_a("phone.vpn")).to be_nil
    @zone.reload!
    expect(@zone.lookup_a("phone.vpn")).to be == "10.8.0.9"
    expect(@zone.lookup_a("phone")).to be == "10.8.0.9"
  end

  it "lets a static A override an auto record of the same name on reload" do
    @db[:dns_records].insert(name: "nas.vpn", rtype: "A", value: "10.8.0.99", managed: false)
    expect(@zone.lookup_a("nas.vpn")).to be == "10.8.0.3" # still the auto record
    @zone.reload!
    expect(@zone.lookup_a("nas.vpn")).to be == "10.8.0.99"
  end

  it "lets the gateway auto record win a colliding client hostname" do
    make_client(@db, name: "gw", hostname: "gateway", wg_ip: "10.8.0.8")
    @zone.reload!
    expect(@zone.lookup_a("gateway.vpn")).to be == "10.8.0.1"
  end

  describe "#upstream_for" do
    def forward(suffix, server, port: 53, site_id: nil)
      @db[:dns_forwarders].insert(site_id: site_id, suffix: suffix, server: server, port: port)
    end

    # The empty case is the one every box that never configures this runs on
    # every query, so it must not walk anything at all.
    it "is nil with no forwarders configured" do
      expect(@zone.upstream_for("example.com")).to be_nil
    end

    it "matches the apex and every name under it" do
      forward("example.com", "9.9.9.9")
      @zone.reload!
      expect(@zone.upstream_for("example.com")).to be == ["9.9.9.9", 53]
      expect(@zone.upstream_for("foo.bar.example.com")).to be == ["9.9.9.9", 53]
    end

    it "prefers the longest matching suffix" do
      forward("example.com", "1.2.3.4")
      forward("foo.example.com", "9.9.9.9")
      @zone.reload!
      expect(@zone.upstream_for("host.foo.example.com")).to be == ["9.9.9.9", 53]
      expect(@zone.upstream_for("host.bar.example.com")).to be == ["1.2.3.4", 53]
    end

    it "does not match a suffix that is only a substring of a label" do
      forward("example.com", "9.9.9.9")
      @zone.reload!
      expect(@zone.upstream_for("notexample.com")).to be_nil
    end

    it "normalizes the queried name" do
      forward("example.com", "9.9.9.9")
      @zone.reload!
      expect(@zone.upstream_for("HOST.Example.COM.")).to be == ["9.9.9.9", 53]
    end

    it "carries the port a forwarder was given" do
      forward("corp.example", "10.20.0.53", port: 5353)
      @zone.reload!
      expect(@zone.upstream_for("corp.example")).to be == ["10.20.0.53", 5353]
    end

    it "matches a reverse zone, which is ordinary DNS text here" do
      forward("1.168.192.in-addr.arpa", "192.168.1.1")
      @zone.reload!
      expect(@zone.upstream_for("85.1.168.192.in-addr.arpa")).to be == ["192.168.1.1", 53]
    end

    # A disabled site is not a kernel peer and its route is not installed, so
    # its resolver is unreachable. Dropping the rule turns a guaranteed timeout
    # into an ordinary upstream answer.
    it "drops a disabled site's rule but keeps an enabled one's" do
      on = make_site(@db, name: "on", pubkey: "SITE-ON", networks: ["192.168.1.0/24"])
      off = make_site(@db, name: "off", pubkey: "SITE-OFF", enabled: false,
        networks: ["192.168.9.0/24"])
      forward("on.example", "192.168.1.53", site_id: on)
      forward("off.example", "192.168.9.53", site_id: off)
      @zone.reload!

      expect(@zone.upstream_for("host.on.example")).to be == ["192.168.1.53", 53]
      expect(@zone.upstream_for("host.off.example")).to be_nil
    end

    it "keeps a manual rule when a site is disabled" do
      forward("example.com", "9.9.9.9")
      make_site(@db, name: "off", pubkey: "SITE-OFF", enabled: false)
      @zone.reload!
      expect(@zone.upstream_for("example.com")).to be == ["9.9.9.9", 53]
    end

    # DNSServer memoizes one Resolver per endpoint and throws the memo away when
    # this number moves, so it has to move on every reload -- including one that
    # rebuilds an identical hash.
    it "advances the generation on every reload" do
      before = @zone.generation
      @zone.reload!
      expect(@zone.generation).to be == before + 1
      @zone.reload!
      expect(@zone.generation).to be == before + 2
    end

    it "publishes the forwarder map frozen" do
      forward("example.com", "9.9.9.9")
      @zone.reload!
      expect(@zone.forwarders.frozen?).to be == true
      expect(@zone.forwarders["example.com"].frozen?).to be == true
    end
  end
end
