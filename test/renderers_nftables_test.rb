# frozen_string_literal: true

require_relative "helper"
require "naaf/renderers/nftables"

describe Naaf::Renderers::Nftables do
  before { @db = reset_db!(wg_interface: "wg0", wan_interface: "eth0", wg_subnet: "10.8.0.0/24") }

  it "renders both allow sets with no elements when nothing is exposed" do
    out = Naaf::Renderers::Nftables.render(@db)
    expect(out).to be(:include?, "set vpn_tcp_allow")
    expect(out).to be(:include?, "set vpn_udp_allow")
    expect(out.include?("elements = {")).to be == false
  end

  it "deletes and recreates table inet naaf wholesale on every apply" do
    out = Naaf::Renderers::Nftables.render(@db)
    expect(out).to be(:include?, "table inet naaf {}")
    expect(out).to be(:include?, "delete table inet naaf")
  end

  it "enforces spoke-to-spoke policy with an explicit trailing drop, never policy drop" do
    out = Naaf::Renderers::Nftables.render(@db)
    expect(out).to be(:include?, "policy accept;")
    expect(out).to be(:include?, %(iifname "wg0" oifname "wg0" counter drop))
    expect(out.include?("policy drop")).to be == false
  end

  it "adds exposed tcp and udp ports to the correct set, keyed on ip . port" do
    nas = make_client(@db, name: "nas", wg_ip: "10.8.0.3")
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 22, port_end: 22)
    @db[:exposed_ports].insert(client_id: nas, proto: "udp", port: 5353, port_end: 5353)
    out = Naaf::Renderers::Nftables.render(@db)
    tcp = out[/set vpn_tcp_allow.*?\}/m]
    udp = out[/set vpn_udp_allow.*?\}/m]
    expect(tcp).to be(:include?, "10.8.0.3 . 22")
    expect(udp).to be(:include?, "10.8.0.3 . 5353")
  end

  # Ranges are stored as an interval, so both sets must carry `flags interval`.
  it "declares both allow sets as interval sets" do
    out = Naaf::Renderers::Nftables.render(@db)
    expect(out[/set vpn_tcp_allow.*?\}/m]).to be(:include?, "flags interval")
    expect(out[/set vpn_udp_allow.*?\}/m]).to be(:include?, "flags interval")
  end

  it "emits a port range as an interval and a single port as a bare element" do
    nas = make_client(@db, name: "nas", wg_ip: "10.8.0.3")
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 8000, port_end: 8100)
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 22, port_end: 22)
    tcp = Naaf::Renderers::Nftables.render(@db)[/set vpn_tcp_allow.*?\}/m]
    expect(tcp).to be(:include?, "10.8.0.3 . 8000-8100")
    expect(tcp).to be(:include?, "10.8.0.3 . 22")
    expect(tcp.include?("22-22")).to be == false
  end

  # A row predating the port_end column reads as NULL and must stay a single port.
  it "treats a NULL port_end as a single port" do
    nas = make_client(@db, name: "nas", wg_ip: "10.8.0.3")
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 22, port_end: nil)
    tcp = Naaf::Renderers::Nftables.render(@db)[/set vpn_tcp_allow.*?\}/m]
    expect(tcp).to be(:include?, "10.8.0.3 . 22")
  end

  # nft rejects overlapping elements in an interval set, and the ruleset is applied
  # as ONE transaction — an unmerged overlap would break every apply, not one rule.
  it "merges overlapping and touching ranges so nft never sees a conflict" do
    nas = make_client(@db, name: "nas", wg_ip: "10.8.0.3")
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 8000, port_end: 8100)
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 8050, port_end: 8200) # overlaps
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 8201, port_end: 8300) # touches
    tcp = Naaf::Renderers::Nftables.render(@db)[/set vpn_tcp_allow.*?\}/m]
    expect(tcp).to be(:include?, "10.8.0.3 . 8000-8300")
    expect(tcp.scan("10.8.0.3").length).to be == 1
  end

  it "never merges ranges belonging to different clients" do
    nas = make_client(@db, name: "nas", wg_ip: "10.8.0.3")
    pi = make_client(@db, name: "pi", wg_ip: "10.8.0.4")
    @db[:exposed_ports].insert(client_id: nas, proto: "tcp", port: 8000, port_end: 8100)
    @db[:exposed_ports].insert(client_id: pi, proto: "tcp", port: 8050, port_end: 8200)
    tcp = Naaf::Renderers::Nftables.render(@db)[/set vpn_tcp_allow.*?\}/m]
    expect(tcp).to be(:include?, "10.8.0.3 . 8000-8100")
    expect(tcp).to be(:include?, "10.8.0.4 . 8050-8200")
  end

  it "drops a disabled client's ranges out of the ruleset without deleting the rows" do
    off = make_client(@db, name: "off", wg_ip: "10.8.0.9", enabled: false)
    @db[:exposed_ports].insert(client_id: off, proto: "tcp", port: 8000, port_end: 8100)
    out = Naaf::Renderers::Nftables.render(@db)
    expect(out.include?("10.8.0.9")).to be == false
    expect(@db[:exposed_ports].count).to be == 1
  end

  it "declares site_nets as an interval set and accepts those addrs before the spoke drop" do
    make_site(@db, name: "unifi", networks: ["192.168.1.0/24"])
    out = Naaf::Renderers::Nftables.render(@db)
    set = out[/set site_nets.*?\}/m]
    expect(set).to be(:include?, "flags interval")
    expect(set).to be(:include?, "192.168.1.0/24")
    daddr = %(iifname "wg0" oifname "wg0" ip daddr @site_nets accept)
    saddr = %(iifname "wg0" oifname "wg0" ip saddr @site_nets accept)
    drop = %(iifname "wg0" oifname "wg0" counter drop)
    expect(out).to be(:include?, daddr)
    expect(out).to be(:include?, saddr)
    expect(out.index(daddr) < out.index(drop)).to be == true
    expect(out.index(saddr) < out.index(drop)).to be == true
    expect(out).to be(:include?, "policy accept;")
    expect(out.include?("policy drop")).to be == false
  end

  it "omits site_nets elements when there are no sites" do
    out = Naaf::Renderers::Nftables.render(@db)
    set = out[/set site_nets.*?\}/m]
    expect(set.include?("elements = {")).to be == false
    expect(out.include?("snat to")).to be == false
  end

  it "emits snat to the site address only when masquerade is on" do
    make_site(@db, name: "unifi", address: "192.168.2.2", masquerade: true,
      networks: ["192.168.1.0/24"])
    out = Naaf::Renderers::Nftables.render(@db)
    expect(out).to be(:include?,
      %(ip saddr 10.8.0.0/24 ip daddr 192.168.1.0/24 oifname "wg0" snat to 192.168.2.2))
  end

  it "masquerades without snat when masquerade is on and no address is set" do
    make_site(@db, name: "unifi", masquerade: true, networks: ["192.168.1.0/24"])
    out = Naaf::Renderers::Nftables.render(@db)
    expect(out).to be(:include?,
      %(ip saddr 10.8.0.0/24 ip daddr 192.168.1.0/24 oifname "wg0" masquerade))
    expect(out.include?("snat to")).to be == false
  end

  it "does not NAT a site that has masquerade off" do
    make_site(@db, name: "unifi", address: "192.168.2.2", masquerade: false,
      networks: ["192.168.1.0/24"])
    out = Naaf::Renderers::Nftables.render(@db)
    expect(out.include?("snat to")).to be == false
    expect(out.scan("masquerade").length).to be == 2 # WAN + hairpin only
  end

  it "merges overlapping site CIDRs so the interval set cannot reject them" do
    make_site(@db, name: "a", networks: ["192.168.1.0/24"])
    # UI refuses this; the renderer must still emit a valid set.
    @db[:site_networks].insert(site_id: @db[:sites].where(name: "a").get(:id),
      cidr: "192.168.1.0/25")
    set = Naaf::Renderers::Nftables.render(@db)[/set site_nets.*?\}/m]
    expect(set).to be(:include?, "192.168.1.0/24")
    expect(set.include?("192.168.1.0/25")).to be == false
  end

  it "merges overlapping masquerade dests so the anonymous set cannot reject them" do
    make_site(@db, name: "a", masquerade: true, networks: ["192.168.1.0/24"])
    @db[:site_networks].insert(site_id: @db[:sites].where(name: "a").get(:id),
      cidr: "192.168.1.0/25")
    out = Naaf::Renderers::Nftables.render(@db)
    expect(out).to be(:include?,
      %(ip saddr 10.8.0.0/24 ip daddr 192.168.1.0/24 oifname "wg0" masquerade))
    expect(out.include?("192.168.1.0/25")).to be == false
  end

  it "emits DNAT only for enabled forwards, plus the hairpin masquerade" do
    nas = make_client(@db, name: "nas", wg_ip: "10.8.0.3")
    @db[:port_forwards].insert(client_id: nas, public_port: 2222, proto: "tcp", target_port: 22, enabled: true)
    @db[:port_forwards].insert(client_id: nas, public_port: 9999, proto: "tcp", target_port: 80, enabled: false)
    out = Naaf::Renderers::Nftables.render(@db)
    expect(out).to be(:include?, "dnat ip to 10.8.0.3:22")
    expect(out.include?("9999")).to be == false
    expect(out).to be(:include?, %(oifname "wg0" ct status dnat masquerade))
    expect(out).to be(:include?, "ip saddr 10.8.0.0/24 oifname \"eth0\" masquerade")
  end
end
