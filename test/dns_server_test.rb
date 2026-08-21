# frozen_string_literal: true

require_relative "helper"
require "sus/fixtures/async"
require "socket"
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

  # The resolver is kept, not discarded: which endpoint a query was sent to is
  # the whole of conditional forwarding, and there is nowhere else to observe it
  # without opening a socket.
  attr_reader :resolver

  def passthrough!(resolver)
    @resolver = resolver
    raise @raise_with if @raise_with
    @passed = true
    :passed
  end
end

# Unlike StubTransaction, this one really dials. That is the only way to find
# out whether a deadline survives async-dns's own dispatch path.
class QueryingTransaction < StubTransaction
  def passthrough!(resolver)
    @resolver = resolver
    resolver.query("roomkoetje.be")
    @passed = true
    :passed
  end
end

class StubZone
  # `generation` is what DNSServer keys its resolver memo on, so it is writable
  # here: bumping it is how a test reproduces an apply! without a database.
  attr_accessor :generation

  def initialize(a: {}, ptr: {}, forwarders: {})
    @a = a
    @ptr = ptr
    @forwarders = forwarders
    @generation = 1
  end

  def lookup_a(name) = @a[name.to_s]
  def lookup_ptr(name) = @ptr[name.to_s]

  # Exact-suffix only. The real longest-suffix walk is Zone's own, and
  # test/zone_test.rb is where it is exercised against a real database.
  def upstream_for(name) = @forwarders[name.to_s]
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

  describe "conditional forwarding" do
    # Async::DNS::Endpoint.for builds a CompositeEndpoint of a datagram and a
    # stream endpoint over the same host and service, so the host:port pair the
    # resolver will dial is readable straight off its inspect output. Comparing
    # that beats reaching into async-dns internals a patch release may rename.
    def dialed(resolver) = resolver.inspect[/name="([^"]+)" service=(\d+)/, 0]

    before do
      @zone = StubZone.new(
        a: {"nas.vpn" => "10.8.0.5"},
        forwarders: {"roomkoetje.be" => ["192.168.1.85", 53].freeze,
                     "corp.example" => ["10.20.0.53", 5353].freeze}
      )
      @server = Naaf::DNSServer.new(zone: @zone, upstream: "1.1.1.1", endpoint: nil)
    end

    it "sends a matching name to that domain's resolver" do
      tx = StubTransaction.new
      @server.process("roomkoetje.be", in_class(:A), tx)

      expect(tx.passed?).to be == true
      expect(dialed(tx.resolver)).to be == %(name="192.168.1.85" service=53)
    end

    it "sends a non-matching name to the settings upstream" do
      tx = StubTransaction.new
      @server.process("example.org", in_class(:A), tx)

      expect(dialed(tx.resolver)).to be == %(name="1.1.1.1" service=53)
    end

    it "honours the port a forwarder was given" do
      tx = StubTransaction.new
      @server.process("corp.example", in_class(:A), tx)

      expect(dialed(tx.resolver)).to be == %(name="10.20.0.53" service=5353)
    end

    # The AAAA branch short-circuits only for names the local zone knows. A
    # forwarded name is not one, so it must reach the same forwarder its A
    # record does — otherwise a dual-stack client silently asks the wrong
    # resolver for half of every lookup.
    it "sends AAAA for a forwarded name to the same forwarder" do
      tx = StubTransaction.new
      @server.process("roomkoetje.be", in_class(:AAAA), tx)

      expect(tx.passed?).to be == true
      expect(dialed(tx.resolver)).to be == %(name="192.168.1.85" service=53)
    end

    it "never forwards a name the local zone answers" do
      tx = StubTransaction.new
      @zone.instance_variable_set(:@forwarders, {"nas.vpn" => ["192.168.1.85", 53]})
      @server.process("nas.vpn", in_class(:A), tx)

      expect(tx.responded).to be == ["10.8.0.5"]
      expect(tx.passed?).to be == false
    end

    it "reuses one resolver per endpoint and rebuilds when the zone reloads" do
      first = StubTransaction.new
      again = StubTransaction.new
      @server.process("roomkoetje.be", in_class(:A), first)
      @server.process("roomkoetje.be", in_class(:A), again)
      expect(again.resolver.equal?(first.resolver)).to be == true

      # What Zone#reload! does at the end of every apply!. Keying the memo on
      # the counter rather than on the hash's object identity means a reload
      # that produces an identical hash still invalidates.
      @zone.generation += 1
      after = StubTransaction.new
      @server.process("roomkoetje.be", in_class(:A), after)
      expect(after.resolver.equal?(first.resolver)).to be == false
    end

    # async-dns 1.4.1 has no timeout on the upstream path -- try_datagram_server
    # does a bare recvfrom -- so an unreachable forwarder would park this fiber
    # and its socket for good. Fiber.scheduler#with_timeout is nil outside a
    # reactor, so raising the same error the wrapper would is how this branch is
    # driven without one.
    it "answers ServFail when a forwarder times out, and files it as an upstream failure" do
      stats = Naaf::Metrics::DNSStats.new
      server = Naaf::DNSServer.new(zone: @zone, upstream: "1.1.1.1",
        endpoint: nil, stats: stats)
      tx = StubTransaction.new(raise_with: Naaf::DNSServer::UpstreamTimeout.new("timeout"))
      server.process("roomkoetje.be", in_class(:A), tx)

      expect(tx.failed).to be == :ServFail
      out = stats.rotate!(elapsed: 1.0)[:outcomes]
      expect(out[:upstream_fail]).to be == 1
      # Not :servfail -- a slow resolver is not a bug in this process, and the
      # rescue that names it must sit above the method's bare `rescue => e`.
      expect(out[:servfail].to_i).to be == 0
    end
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

  # The example that would have caught the deadline being swallowed. Every
  # example above drives the branch with a stubbed transaction, which proves the
  # rescue is wired up but says nothing about whether the deadline actually
  # FIRES through async-dns -- and it did not. Resolver#dispatch_request wraps
  # each endpoint attempt in a bare `rescue => error  # Try the next server.`,
  # so a StandardError deadline abandoned the UDP attempt and left the TCP one
  # running with no deadline at all: a 2s budget measured 8s and was still going.
  describe "a forwarder that accepts and never answers" do
    include Sus::Fixtures::Async::ReactorContext

    # UDP and TCP on the SAME port, both accepting, neither ever replying --
    # what a site resolver behind a down tunnel looks like from this box. No
    # network is involved, so this cannot flake on a runner's egress.
    def blackhole
      udp = UDPSocket.new
      udp.bind("127.0.0.1", 0)
      tcp = TCPServer.new("127.0.0.1", udp.addr[1])
      accepter = Async { loop { tcp.accept } }
      yield udp.addr[1]
    ensure
      accepter&.stop
      tcp&.close
      udp&.close
    end

    it "gives up inside NAAF_DNS_UPSTREAM_TIMEOUT instead of parking the fiber" do
      budget = Naaf::DNSServer::UPSTREAM_TIMEOUT
      blackhole do |port|
        zone = StubZone.new(forwarders: {"roomkoetje.be" => ["127.0.0.1", port].freeze})
        stats = Naaf::Metrics::DNSStats.new
        server = Naaf::DNSServer.new(zone: zone, upstream: "127.0.0.1",
          endpoint: nil, stats: stats)
        tx = QueryingTransaction.new
        began = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # An outer guard so a regression fails loudly instead of wedging bin/ci.
        Async::Task.current.with_timeout(budget * 4) do
          server.process("roomkoetje.be", in_class(:A), tx)
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - began

        expect(elapsed < budget + 1).to be == true
        expect(tx.failed).to be == :ServFail
        out = stats.rotate!(elapsed: 1.0)[:outcomes]
        expect(out[:upstream_fail]).to be == 1
        # Not a bug in this process, so not :servfail.
        expect(out[:servfail].to_i).to be == 0
      end
    end
  end
end
