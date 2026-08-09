# frozen_string_literal: true

require_relative "helper"
require "naaf/dns_server"

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
end
