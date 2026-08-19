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

  it "never hands out the network address, the broadcast, or the server IP" do
    # /29: .0 net, .1 server, .2–.6 hosts, .7 broadcast.
    reset_db!(wg_subnet: "10.8.0.0/29", server_ip: "10.8.0.1")
    allocated = []
    5.times do |i|
      ip = Naaf::IPAM.allocate(@db)
      allocated << ip
      make_client(@db, name: "c#{i}", wg_ip: ip)
    end
    expect(allocated).to be == %w[10.8.0.2 10.8.0.3 10.8.0.4 10.8.0.5 10.8.0.6]
    expect { Naaf::IPAM.allocate(@db) }.to raise_exception(RuntimeError, message: be =~ /exhausted/)
  end

  it "detects overlapping IPv4 CIDRs and not merely adjacent ones" do
    expect(Naaf::IPAM.overlap?("192.168.1.0/24", "192.168.1.0/25")).to be == true
    expect(Naaf::IPAM.overlap?("10.8.0.0/24", "10.8.0.0/24")).to be == true
    expect(Naaf::IPAM.overlap?("192.168.1.0/24", "192.168.2.0/24")).to be == false
    expect(Naaf::IPAM.overlap?("not-a-net", "192.168.1.0/24")).to be == false
  end

  it "merges overlapping and touching IPv4 CIDRs into one interval element" do
    expect(Naaf::IPAM.merge_v4_cidrs(["192.168.1.0/24", "192.168.1.0/25"]))
      .to be == ["192.168.1.0/24"]
    expect(Naaf::IPAM.merge_v4_cidrs(["10.0.0.0/24", "10.0.1.0/24"]))
      .to be == ["10.0.0.0/23"]
    expect(Naaf::IPAM.merge_v4_cidrs(["10.0.0.5/32"])).to be == ["10.0.0.5"]
  end
end
