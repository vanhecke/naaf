# frozen_string_literal: true

require_relative "helper"
require "naaf/renderers/routes"

describe Naaf::Renderers::Routes do
  before { @db = reset_db!(wg_interface: "wg0") }

  it "lists enabled site CIDRs as proto-158 routes on the wg interface" do
    make_site(@db, name: "unifi", address: "192.168.2.2",
      networks: ["192.168.1.0/24", "10.0.0.0/16"])
    extra = Naaf::Renderers::Routes.desired(@db)
    expect(extra[:routes]).to be == [
      {dst: "10.0.0.0/16", dev: "wg0"},
      {dst: "192.168.1.0/24", dev: "wg0"}
    ]
    expect(extra[:addresses]).to be == [{addr: "192.168.2.2", dev: "wg0"}]
  end

  it "omits disabled sites and sites with no address" do
    make_site(@db, name: "off", enabled: false, address: "192.168.2.2",
      networks: ["192.168.1.0/24"])
    make_site(@db, name: "plain", networks: ["10.0.0.0/8"])
    extra = Naaf::Renderers::Routes.desired(@db)
    expect(extra[:routes]).to be == [{dst: "10.0.0.0/8", dev: "wg0"}]
    expect(extra[:addresses]).to be == []
  end

  it "never emits a prefix-0 dest — that would steal the default route" do
    make_site(@db, name: "unifi", networks: ["192.168.1.0/24"])
    extra = Naaf::Renderers::Routes.desired(@db)
    extra[:routes].each do |r|
      prefix = r[:dst].split("/", 2).last.to_i
      expect(prefix > 0).to be == true
    end
  end
end
