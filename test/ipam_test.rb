# frozen_string_literal: true

require_relative "helper"
require "naaf/ipam"

describe Naaf::IPAM do
  before { @db = reset_db! } # default subnet 10.8.0.0/24, server_ip 10.8.0.1

  it "allocates the lowest free host, skipping the network address and the server IP" do
    expect(Naaf::IPAM.allocate(@db)).to be == "10.8.0.2"
  end

  it "skips addresses already taken by clients" do
    make_client(@db, name: "a", wg_ip: "10.8.0.2")
    make_client(@db, name: "b", wg_ip: "10.8.0.3")
    expect(Naaf::IPAM.allocate(@db)).to be == "10.8.0.4"
  end

  it "reuses the lowest freed address rather than always appending" do
    make_client(@db, name: "a", wg_ip: "10.8.0.2")
    make_client(@db, name: "c", wg_ip: "10.8.0.4") # .3 left as a gap
    expect(Naaf::IPAM.allocate(@db)).to be == "10.8.0.3"
  end

  it "raises when the subnet is exhausted" do
    # /30 -> usable .1 and .2; .0 network, .3 broadcast. server = .1, client takes .2.
    reset_db!(wg_subnet: "10.8.0.0/30", server_ip: "10.8.0.1")
    make_client(@db, name: "only", wg_ip: "10.8.0.2")
    expect { Naaf::IPAM.allocate(@db) }.to raise_exception(RuntimeError, message: be =~ /exhausted/)
  end
end
