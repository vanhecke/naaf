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

  # This renderer is a pure projection: it copies site CIDRs. The form and the
  # helper refuse a /0 (it would steal WAN). Pretending the renderer filters
  # one is how a hollow test stays green while the DB holds a default route.
  it "emits a prefix-0 dest if one is in the DB — the helper and the form refuse those" do
    make_site(@db, name: "unifi", networks: ["0.0.0.0/0"])
    extra = Naaf::Renderers::Routes.desired(@db)
    expect(extra[:routes]).to be == [{dst: "0.0.0.0/0", dev: "wg0"}]
  end
end
