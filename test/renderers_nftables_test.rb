# frozen_string_literal: true

require_relative "helper"
require "wgcp/renderers/nftables"

describe WGCP::Renderers::Nftables do
  before { @db = reset_db!(wg_interface: "wg0", wan_interface: "eth0", wg_subnet: "10.8.0.0/24") }

  it "renders both allow sets with no elements when nothing is exposed" do
    out = WGCP::Renderers::Nftables.render(@db)
    expect(out).to be(:include?, "set vpn_tcp_allow")
    expect(out).to be(:include?, "set vpn_udp_allow")
    expect(out.include?("elements = {")).to be == false
  end

  it "deletes and recreates table inet wgcp wholesale on every apply" do
    out = WGCP::Renderers::Nftables.render(@db)
    expect(out).to be(:include?, "table inet wgcp {}")
    expect(out).to be(:include?, "delete table inet wgcp")
  end

  it "enforces spoke-to-spoke policy with an explicit trailing drop, never policy drop" do
    out = WGCP::Renderers::Nftables.render(@db)
    expect(out).to be(:include?, "policy accept;")
    expect(out).to be(:include?, %(iifname "wg0" oifname "wg0" counter drop))
    expect(out.include?("policy drop")).to be == false
  end

  it "adds exposed tcp and udp ports to the correct set, keyed on ip . port" do
    nas = make_client(@db, name: "nas", wg_ip: "10.8.0.3")
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 22, port_end: 22)
    @db[:exposed_ports].insert(client_id: nas, proto: "udp", port: 5353, port_end: 5353)
    out = WGCP::Renderers::Nftables.render(@db)
    tcp = out[/set vpn_tcp_allow.*?\}/m]
    udp = out[/set vpn_udp_allow.*?\}/m]
    expect(tcp).to be(:include?, "10.8.0.3 . 22")
    expect(udp).to be(:include?, "10.8.0.3 . 5353")
  end

  # Ranges are stored as an interval, so both sets must carry `flags interval`.
  it "declares both allow sets as interval sets" do
    out = WGCP::Renderers::Nftables.render(@db)
    expect(out[/set vpn_tcp_allow.*?\}/m]).to be(:include?, "flags interval")
    expect(out[/set vpn_udp_allow.*?\}/m]).to be(:include?, "flags interval")
  end

  it "emits a port range as an interval and a single port as a bare element" do
    nas = make_client(@db, name: "nas", wg_ip: "10.8.0.3")
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 8000, port_end: 8100)
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 22, port_end: 22)
    tcp = WGCP::Renderers::Nftables.render(@db)[/set vpn_tcp_allow.*?\}/m]
    expect(tcp).to be(:include?, "10.8.0.3 . 8000-8100")
    expect(tcp).to be(:include?, "10.8.0.3 . 22")
    expect(tcp.include?("22-22")).to be == false
  end

  # A row predating the port_end column reads as NULL and must stay a single port.
  it "treats a NULL port_end as a single port" do
    nas = make_client(@db, name: "nas", wg_ip: "10.8.0.3")
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 22, port_end: nil)
    tcp = WGCP::Renderers::Nftables.render(@db)[/set vpn_tcp_allow.*?\}/m]
    expect(tcp).to be(:include?, "10.8.0.3 . 22")
  end

  # nft rejects overlapping elements in an interval set, and the ruleset is applied
  # as ONE transaction — an unmerged overlap would break every apply, not one rule.
  it "merges overlapping and touching ranges so nft never sees a conflict" do
    nas = make_client(@db, name: "nas", wg_ip: "10.8.0.3")
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 8000, port_end: 8100)
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 8050, port_end: 8200) # overlaps
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 8201, port_end: 8300) # touches
    tcp = WGCP::Renderers::Nftables.render(@db)[/set vpn_tcp_allow.*?\}/m]
    expect(tcp).to be(:include?, "10.8.0.3 . 8000-8300")
    expect(tcp.scan("10.8.0.3").length).to be == 1
  end

  it "never merges ranges belonging to different clients" do
    nas = make_client(@db, name: "nas", wg_ip: "10.8.0.3")
    pi = make_client(@db, name: "pi", wg_ip: "10.8.0.4")
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 8000, port_end: 8100)
    @db[:exposed_ports].insert(client_id: pi, proto: "tcp", port: 8050, port_end: 8200)
    tcp = WGCP::Renderers::Nftables.render(@db)[/set vpn_tcp_allow.*?\}/m]
    expect(tcp).to be(:include?, "10.8.0.3 . 8000-8100")
    expect(tcp).to be(:include?, "10.8.0.4 . 8050-8200")
  end

  it "drops a disabled client's ranges out of the ruleset without deleting the rows" do
    off = make_client(@db, name: "off", wg_ip: "10.8.0.9", enabled: false)
    @db[:exposed_ports].insert(client_id: off, proto: "tcp", port: 8000, port_end: 8100)
    out = WGCP::Renderers::Nftables.render(@db)
    expect(out.include?("10.8.0.9")).to be == false
    expect(@db[:exposed_ports].count).to be == 1
  end

  it "emits DNAT only for enabled forwards, plus the hairpin masquerade" do
    nas = make_client(@db, name: "nas", wg_ip: "10.8.0.3")
    @db[:port_forwards].insert(client_id: nas, public_port: 2222, proto: "tcp", target_port: 22, enabled: true)
    @db[:port_forwards].insert(client_id: nas, public_port: 9999, proto: "tcp", target_port: 80, enabled: false)
    out = WGCP::Renderers::Nftables.render(@db)
    expect(out).to be(:include?, "dnat ip to 10.8.0.3:22")
    expect(out.include?("9999")).to be == false
    expect(out).to be(:include?, %(oifname "wg0" ct status dnat masquerade))
    expect(out).to be(:include?, "ip saddr 10.8.0.0/24 oifname \"eth0\" masquerade")
  end
end
