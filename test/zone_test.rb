# frozen_string_literal: true

require_relative "helper"
require "wgcp/zone"

describe WGCP::Zone do
  before do
    @db = reset_db!(server_ip: "10.8.0.1", dns_domain: "vpn")
    make_client(@db, name: "nas", hostname: "nas", wg_ip: "10.8.0.3")
    @db[:dns_records].insert(name: "wiki.vpn", rtype: "A", value: "10.8.0.3", managed: false)
    @db[:dns_records].insert(name: "alias.vpn", rtype: "CNAME", value: "nas.vpn", managed: false)
    @zone = WGCP::Zone.new(@db)
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
    expect(WGCP::Zone.auto_records(@db)).to be == [
      {name: "vpn", rtype: "A", value: "10.8.0.1", source: :apex},
      {name: "nas.vpn", rtype: "A", value: "10.8.0.3", source: :client},
      {name: "nas", rtype: "A", value: "10.8.0.3", source: :client_bare},
      {name: "3.0.8.10.in-addr.arpa", rtype: "PTR", value: "nas.vpn.", source: :ptr},
      {name: "gateway.vpn", rtype: "A", value: "10.8.0.1", source: :gateway}
    ]
  end
end
