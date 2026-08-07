# frozen_string_literal: true

require_relative "helper"
require "wgcp/renderers/wireguard"

describe WGCP::Renderers::WireGuard do
  before do
    @db = reset_db!(
      server_privkey: "SRVPRIV", server_ip: "10.8.0.1",
      wg_subnet: "10.8.0.0/24", mtu: 1420, listen_port: 51820
    )
  end

  it "renders the [Interface] with server address, port, key and mtu" do
    out = WGCP::Renderers::WireGuard.render(@db)
    expect(out).to be(:include?, "Address = 10.8.0.1/24")
    expect(out).to be(:include?, "ListenPort = 51820")
    expect(out).to be(:include?, "PrivateKey = SRVPRIV")
    expect(out).to be(:include?, "MTU = 1420")
  end

  it "emits one [Peer] per enabled client, ordered by wg_ip" do
    make_client(@db, name: "nas", wg_ip: "10.8.0.3", pubkey: "NASPUB", psk: "NASPSK")
    make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "LAPPUB", psk: "LAPPSK")
    out = WGCP::Renderers::WireGuard.render(@db)
    expect(out).to be(:include?, "PublicKey = LAPPUB")
    expect(out).to be(:include?, "PresharedKey = LAPPSK")
    expect(out).to be(:include?, "AllowedIPs = 10.8.0.2/32")
    expect(out).to be(:include?, "AllowedIPs = 10.8.0.3/32")
    expect(out.index("LAPPUB") < out.index("NASPUB")).to be == true
  end

  it "omits disabled clients" do
    make_client(@db, name: "off", wg_ip: "10.8.0.5", pubkey: "OFFPUB", enabled: false)
    out = WGCP::Renderers::WireGuard.render(@db)
    expect(out.include?("OFFPUB")).to be == false
  end

  it "never emits PostUp/PostDown — the firewall is owned by the nftables renderer" do
    out = WGCP::Renderers::WireGuard.render(@db)
    expect(out.include?("PostUp")).to be == false
    expect(out.include?("PostDown")).to be == false
  end
end
