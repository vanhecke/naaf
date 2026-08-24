# frozen_string_literal: true

require_relative "helper"
require "naaf/renderers/exit"

describe Naaf::Renderers::Exit do
  before { @db = reset_db!(wg_interface: "wg0", wg_subnet: "10.8.0.0/24") }

  def desired = Naaf::Renderers::Exit.desired(@db)

  it "returns nil when there is no row" do
    expect(desired).to be_nil
  end

  it "returns nil when the row is disabled" do
    make_exit(@db, enabled: false)
    expect(desired).to be_nil
  end

  it "emits wg-setconf grammar: their pubkey, our privkey, /0, no ListenPort or Table" do
    make_exit(@db, privkey: "EXITPRIV", pubkey: "EXITPUB", psk: "EXITPSK",
      endpoint: "engage.cloudflareclient.com:2408", keepalive: 25)
    conf = desired[:conf]
    expect(conf).to be(:include?, "PrivateKey = EXITPRIV")
    expect(conf).to be(:include?, "PublicKey = EXITPUB")
    expect(conf).to be(:include?, "PresharedKey = EXITPSK")
    expect(conf).to be(:include?, "AllowedIPs = 0.0.0.0/0")
    expect(conf).to be(:include?, "Endpoint = engage.cloudflareclient.com:2408")
    expect(conf).to be(:include?, "PersistentKeepalive = 25")
    expect(conf.include?("ListenPort")).to be == false
    expect(conf.include?("Table")).to be == false
    %w[MTU Address DNS PreUp PostUp].each do |banned|
      expect(conf.match?(/^\s*#{banned}\s*=/)).to be == false
    end
  end

  it "omits PresharedKey when the row has none" do
    make_exit(@db, psk: nil)
    expect(desired[:conf].include?("PresharedKey")).to be == false
  end

  it "points table 159 site CIDRs and site /32s at wg0, and default at wg-exit" do
    make_exit(@db)
    make_site(@db, name: "unifi", address: "192.168.2.2",
      networks: ["192.168.1.0/24", "10.0.0.0/16"])
    make_site(@db, name: "off", enabled: false, address: "10.20.0.1",
      networks: ["10.20.0.0/16"])
    expect(desired[:routes]).to be == [
      {dst: "10.0.0.0/16", dev: "wg0"},
      {dst: "192.168.1.0/24", dev: "wg0"},
      {dst: "192.168.2.2/32", dev: "wg0"},
      {dst: "default", dev: "wg-exit"}
    ]
    expect(desired[:dev]).to be == "wg-exit"
    expect(desired[:address]).to be == "172.16.0.2"
    expect(desired[:mtu]).to be == 1280
    expect(desired[:table]).to be == 159
    expect(desired[:mark]).to be == 159
  end

  it "emits the three policy-routing prefs" do
    make_exit(@db)
    expect(desired[:rules]).to be == [
      {pref: 15800, spec: ["fwmark", "159", "lookup", "main"]},
      {pref: 15850, spec: ["iif", "wg0", "to", "10.8.0.0/24", "lookup", "main"]},
      {pref: 15900, spec: ["iif", "wg0", "lookup", "159"]}
    ]
  end

  it "still emits default via wg-exit when there are no sites" do
    make_exit(@db)
    expect(desired[:routes]).to be == [{dst: "default", dev: "wg-exit"}]
  end
end
