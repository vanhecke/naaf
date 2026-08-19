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

  it "falls back to a dash range when the merged span is not a single prefix" do
    # Two /25s and a /26 touch end to end, so they collapse into one span of 320
    # addresses — a width no prefix can express, so nft takes the dash form.
    expect(Naaf::IPAM.merge_v4_cidrs(["10.0.0.0/25", "10.0.0.128/25", "10.0.1.0/26"]))
      .to be == ["10.0.0.0-10.0.1.63"]
    # A /24 touching a /25 is the same story with rounder numbers: 384 wide.
    expect(Naaf::IPAM.merge_v4_cidrs(["10.0.0.0/24", "10.0.1.0/25"]))
      .to be == ["10.0.0.0-10.0.1.127"]
  end

  it "falls back to a dash range for a span sized like a prefix but not aligned like one" do
    # 10.0.0.128 through 10.0.1.127 is exactly 256 addresses, so the
    # power-of-two test alone would happily call it a /24 — but it starts
    # mid-block and straddles the boundary, so "10.0.0.128/24" would be a lie
    # covering .0 through .255. nft would accept that silently and route a
    # quarter of the traffic to the wrong site.
    expect(Naaf::IPAM.merge_v4_cidrs(["10.0.0.128/25", "10.0.1.0/25"]))
      .to be == ["10.0.0.128-10.0.1.127"]
  end

  it "emits dash ranges nft can read: two bare dotted quads, low end first" do
    # The element is interpolated straight into an `flags interval` set and into
    # `ip daddr` in the NAT chain. A prefix suffix on either end, a third
    # hyphen, or an inverted pair is a parse error, and one unparseable element
    # fails the entire `nft -f` transaction — every rule, not just this row.
    # Driven from a span no other test pins by value, so this fails on a
    # malformed endpoint rather than only when an exact-equality test already has.
    element = Naaf::IPAM.merge_v4_cidrs(["10.0.0.0/24", "10.0.1.0/25", "10.0.1.128/26"]).first
    lo, hi, extra = element.split("-")
    expect(extra).to be_nil
    [lo, hi].each do |endpoint|
      expect(endpoint).not.to be(:include?, "/")
      # Round-tripping through IPAddr is what rejects a plausible-looking
      # non-address; a digit-counting regex accepts 999.999.999.999.
      expect(IPAddr.new(endpoint).to_s).to be == endpoint
    end
    expect(IPAddr.new(lo).to_i).to be < IPAddr.new(hi).to_i
  end

  it "merges the same way however the site's networks happen to be ordered" do
    # site_networks comes back ordered by the CIDR string, which sorts
    # "10.0.10.0/24" ahead of "10.0.9.0/24". If the merge leaned on arrival
    # order, adding one network to a site could silently split an interval in
    # two and start emitting overlapping elements.
    shuffled = ["10.0.9.0/24", "10.0.1.0/26", "10.0.0.128/25", "10.0.0.0/25"]
    expect(Naaf::IPAM.merge_v4_cidrs(shuffled))
      .to be == ["10.0.0.0-10.0.1.63", "10.0.9.0/24"]
    expect(Naaf::IPAM.merge_v4_cidrs(shuffled.reverse))
      .to be == ["10.0.0.0-10.0.1.63", "10.0.9.0/24"]
  end
end
