# frozen_string_literal: true

require_relative "helper"
require "naaf/dns_server"
require "naaf/metrics/dns_stats"

# Stand-ins for async-dns's Transaction and for Naaf::Zone, so every branch of
# the query path can be driven without a reactor, a socket, or an upstream.
class StubTransaction
  attr_reader :responded, :failed, :response

  Response = Struct.new(:rcode)

  def initialize(remote: "10.8.0.2", rcode: 0, raise_with: nil)
    @addr = remote && Addrinfo.udp(remote, 53)
    @response = Response.new(rcode)
    @raise_with = raise_with
    @passed = false
  end

  def passed? = @passed

  def [](key) = (key == :remote_address) ? @addr : nil

  def respond!(*args, **opts)
    @responded = args
    :responded
  end

  def fail!(code)
    @failed = code
    :failed
  end

  def passthrough!(_resolver)
    raise @raise_with if @raise_with
    @passed = true
    :passed
  end
end

class StubZone
  def initialize(a: {}, ptr: {})
    @a = a
    @ptr = ptr
  end

  def lookup_a(name) = @a[name.to_s]
  def lookup_ptr(name) = @ptr[name.to_s]
end

describe Naaf::DNSServer do
  def in_class(type) = Resolv::DNS::Resource::IN.const_get(type)

  before do
    @zone = StubZone.new(a: {"nas.vpn" => "10.8.0.5"}, ptr: {"5.0.8.10.in-addr.arpa" => "nas.vpn"})
    @server = Naaf::DNSServer.new(zone: @zone, upstream: "1.1.1.1", endpoint: nil)
  end

  it "answers an internal A record from the zone" do
    tx = StubTransaction.new
    @server.process("nas.vpn", in_class(:A), tx)

    expect(tx.responded).to be == ["10.8.0.5"]
    expect(tx.passed?).to be == false
  end

  # Only A and AAAA are statically defined under Resolv::DNS::Resource::IN. PTR
  # is generated at load time and its class is really named
  # "Resolv::DNS::Resource::Type12_Class1", so the /IN::PTR\z/ name match this
  # replaced could never fire and every reverse lookup for a .vpn host was
  # forwarded to an upstream that has never heard of it.
  it "answers a reverse lookup from the zone instead of forwarding it upstream" do
    tx = StubTransaction.new
    @server.process("5.0.8.10.in-addr.arpa", in_class(:PTR), tx)

    expect(tx.responded.first.to_s).to be == "nas.vpn"
    expect(tx.passed?).to be == false
  end

  it "matches the resource classes a decoded query actually carries" do
    # What arrives off the wire is the decoded class, not the constant the
    # caller wrote — this is exactly where the name-matching went wrong.
    message = Resolv::DNS::Message.new(1)
    message.add_question("5.0.8.10.in-addr.arpa", in_class(:PTR))
    decoded = Resolv::DNS::Message.decode(message.encode)

    decoded.each_question do |name, resource_class|
      tx = StubTransaction.new
      @server.process(name.to_s.chomp("."), resource_class, tx)
      expect(tx.responded.first.to_s).to be == "nas.vpn"
    end
  end

  # The internal network is IPv4-only, so an internal AAAA gets an empty NOERROR
  # and the client falls back to A instead of waiting for a timeout.
  it "suppresses AAAA for an internal name" do
    tx = StubTransaction.new
    @server.process("nas.vpn", in_class(:AAAA), tx)

    expect(tx.failed).to be == :NoError
  end

  it "forwards an AAAA for a name it does not host" do
    tx = StubTransaction.new
    @server.process("example.com", in_class(:AAAA), tx)

    expect(tx.passed?).to be == true
  end

  it "passes an unknown name upstream" do
    tx = StubTransaction.new
    @server.process("example.com", in_class(:A), tx)

    expect(tx.passed?).to be == true
  end

  it "forwards a record type it does not serve rather than failing it" do
    tx = StubTransaction.new
    @server.process("example.com", in_class(:MX), tx)

    expect(tx.passed?).to be == true
  end

  it "answers ServFail when resolution raises" do
    tx = StubTransaction.new(raise_with: IOError.new("upstream gone"))
    @server.process("example.com", in_class(:A), tx)

    expect(tx.failed).to be == :ServFail
  end

  describe "with metrics attached" do
    before do
      @stats = Naaf::Metrics::DNSStats.new
      @server = Naaf::DNSServer.new(zone: @zone, upstream: "1.1.1.1",
        endpoint: nil, stats: @stats)
    end

    def outcomes = @stats.rotate!(elapsed: 1.0)[:outcomes]

    it "counts each branch of the query path separately" do
      @server.process("nas.vpn", in_class(:A), StubTransaction.new)
      @server.process("5.0.8.10.in-addr.arpa", in_class(:PTR), StubTransaction.new)
      @server.process("nas.vpn", in_class(:AAAA), StubTransaction.new)
      @server.process("example.com", in_class(:A), StubTransaction.new)

      out = outcomes
      expect(out[:local_a]).to be == 1
      expect(out[:local_ptr]).to be == 1
      expect(out[:aaaa_suppressed]).to be == 1
      expect(out[:upstream_ok]).to be == 1
    end

    it "times the upstream round trip" do
      @server.process("example.com", in_class(:A), StubTransaction.new)
      expect(@stats.rotate!(elapsed: 1.0)[:p50_ms].nil?).to be == false
    end

    it "counts a ServFail answer as an upstream failure, not a success" do
      @server.process("example.com", in_class(:A),
        StubTransaction.new(rcode: Resolv::DNS::RCode::ServFail))

      expect(outcomes[:upstream_fail]).to be == 1
    end

    it "counts a raised failure and still answers ServFail" do
      tx = StubTransaction.new(raise_with: IOError.new("upstream gone"))
      @server.process("example.com", in_class(:A), tx)

      expect(tx.failed).to be == :ServFail
      expect(outcomes[:servfail]).to be == 1
    end

    it "attributes a query to the client that asked" do
      @server.process("example.com", in_class(:A), StubTransaction.new(remote: "10.8.0.7"))
      out = @stats.rotate!(elapsed: 1.0, names: {"10.8.0.7" => "phone"})

      expect(out[:top_clients].first).to be == ["phone", 1]
    end

    # Attribution is a nice-to-have; answering the query is not.
    it "still answers when the transaction carries no remote address" do
      tx = StubTransaction.new(remote: nil)
      @server.process("nas.vpn", in_class(:A), tx)

      expect(tx.responded).to be == ["10.8.0.5"]
      expect(outcomes[:local_a]).to be == 1
    end
  end
end
