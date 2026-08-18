# frozen_string_literal: true

require_relative "helper"
require "naaf/renderers/wireguard"

describe Naaf::Renderers::WireGuard do
  before do
    @db = reset_db!(
      server_privkey: "SRVPRIV", server_ip: "10.8.0.1",
      wg_subnet: "10.8.0.0/24", mtu: 1420, listen_port: 51820
    )
  end

  it "renders the [Interface] with server address, port, key and mtu" do
    out = Naaf::Renderers::WireGuard.render(@db)
    expect(out).to be(:include?, "Address = 10.8.0.1/24")
    expect(out).to be(:include?, "ListenPort = 51820")
    expect(out).to be(:include?, "PrivateKey = SRVPRIV")
    expect(out).to be(:include?, "MTU = 1420")
  end

  it "emits one [Peer] per enabled client, ordered by wg_ip" do
    make_client(@db, name: "nas", wg_ip: "10.8.0.3", pubkey: "NASPUB", psk: "NASPSK")
    make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "LAPPUB", psk: "LAPPSK")
    out = Naaf::Renderers::WireGuard.render(@db)
    expect(out).to be(:include?, "PublicKey = LAPPUB")
    expect(out).to be(:include?, "PresharedKey = LAPPSK")
    expect(out).to be(:include?, "AllowedIPs = 10.8.0.2/32")
    expect(out).to be(:include?, "AllowedIPs = 10.8.0.3/32")
    expect(out.index("LAPPUB") < out.index("NASPUB")).to be == true
  end

  it "omits disabled clients" do
    make_client(@db, name: "off", wg_ip: "10.8.0.5", pubkey: "OFFPUB", enabled: false)
    out = Naaf::Renderers::WireGuard.render(@db)
    expect(out.include?("OFFPUB")).to be == false
  end

  it "never emits PostUp/PostDown — the firewall is owned by the nftables renderer" do
    out = Naaf::Renderers::WireGuard.render(@db)
    expect(out.include?("PostUp")).to be == false
    expect(out.include?("PostDown")).to be == false
  end

  it "emits an enabled site as a peer with wide AllowedIPs, Endpoint and keepalive" do
    make_site(@db, name: "unifi", pubkey: "UNIFIPUB", endpoint: "203.0.113.9:51820",
      keepalive: 25, networks: ["192.168.1.0/24", "10.0.0.0/16"])
    out = Naaf::Renderers::WireGuard.render(@db)
    expect(out).to be(:include?, "PublicKey = UNIFIPUB")
    expect(out).to be(:include?, "AllowedIPs = 10.0.0.0/16, 192.168.1.0/24")
    expect(out).to be(:include?, "Endpoint = 203.0.113.9:51820")
    expect(out).to be(:include?, "PersistentKeepalive = 25")
    expect(out).to be(:include?, "# unifi (site)")
    expect(out.include?("PresharedKey = ")).to be == false
  end

  it "emits PresharedKey only when the site has one" do
    make_site(@db, name: "unifi", pubkey: "UNIFIPUB", psk: "SITEPSK",
      networks: ["192.168.1.0/24"])
    out = Naaf::Renderers::WireGuard.render(@db)
    expect(out).to be(:include?, "PresharedKey = SITEPSK")
  end

  it "omits a disabled site and a site with no networks" do
    make_site(@db, name: "off", pubkey: "OFFPUB", enabled: false,
      networks: ["192.168.1.0/24"])
    make_site(@db, name: "empty", pubkey: "EMPTYPUB", networks: [])
    out = Naaf::Renderers::WireGuard.render(@db)
    expect(out.include?("OFFPUB")).to be == false
    expect(out.include?("EMPTYPUB")).to be == false
  end

  it "keeps client AllowedIPs as /32 when a site is also present" do
    make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "LAPPUB", psk: "LAPPSK")
    make_site(@db, name: "unifi", pubkey: "UNIFIPUB", networks: ["192.168.1.0/24"])
    out = Naaf::Renderers::WireGuard.render(@db)
    expect(out).to be(:include?, "AllowedIPs = 10.8.0.2/32")
    expect(out).to be(:include?, "AllowedIPs = 192.168.1.0/24")
  end
end
