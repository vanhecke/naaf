# frozen_string_literal: true

require "resolv"
require "async/dns"

module Naaf
  class DNSServer < Async::DNS::Server
    IN = Resolv::DNS::Resource::IN

    # Dispatch on the numeric type, never on the class name.
    #
    # Only A and AAAA are statically defined under Resolv::DNS::Resource::IN.
    # The class-insensitive types — PTR, CNAME, MX, TXT — are generated at load
    # time, so Resolv::DNS::Resource::IN::PTR is really a class called
    # "Resolv::DNS::Resource::Type12_Class1". Matching the name with /IN::PTR\z/
    # therefore never fires, and every reverse lookup for a .vpn host silently
    # fell through to the upstream resolver, which has never heard of it. The
    # type value is stable across Ruby versions; the generated name is not.
    TYPE_A = IN::A::TypeValue
    TYPE_AAAA = IN::AAAA::TypeValue
    TYPE_PTR = IN::PTR::TypeValue

    # NOTE: async-dns 1.4 takes `endpoint` as a POSITIONAL argument to
    # Server#initialize (verified against the installed 1.4.1 source), so we
    # pass it positionally with `super(endpoint)`, not `super(endpoint:)`.
    # `Server.default_endpoint` binds localhost only; the caller constructs an
    # endpoint bound to the WireGuard IP and hands it in here.
    # `upstream` is a String or a callable. Passing a callable (bin/naaf passes
    # `-> { zone.upstream }`) makes an edit in the Settings UI take effect on the
    # next query instead of the next restart.
    # Named by number rather than reached for through Resolv::DNS::RCode on the
    # hot path. Only the codes an upstream realistically returns are listed.
    RCODES = {0 => :NoError, 1 => :FormErr, 2 => :ServFail,
              3 => :NXDomain, 4 => :NotImp, 5 => :Refused}.freeze

    # `stats` is optional and every call to it is guarded, because answering
    # queries must never depend on the dashboard existing.
    def initialize(zone:, upstream:, endpoint:, stats: nil)
      @zone = zone
      @upstream = upstream
      @stats = stats
      super(endpoint)
    end

    def current_upstream = @upstream.respond_to?(:call) ? @upstream.call : @upstream

    # Rebuilt only when the value actually changes, so the common case is a hash
    # comparison rather than an allocation. Constructing a Resolver opens no
    # sockets — the endpoint is dialled per query — so the rebuild is cheap.
    def resolver
      up = current_upstream
      if @resolver.nil? || @resolver_for != up
        @resolver_for = up
        @resolver = Async::DNS::Resolver.new(Async::DNS::Endpoint.for(up))
      end
      @resolver
    end

    def process(name, resource_class, transaction)
      remote = remote_ip(transaction)

      case type_of(resource_class)
      when TYPE_A
        if (ip = @zone.lookup_a(name))
          @stats&.record(:local_a, name: name, remote: remote)
          return transaction.respond!(ip, ttl: 60)
        end
      when TYPE_PTR
        if (host = @zone.lookup_ptr(name))
          @stats&.record(:local_ptr, name: name, remote: remote)
          return transaction.respond!(Resolv::DNS::Name.create(host))
        end
      when TYPE_AAAA
        # Internal network is IPv4-only. Return an empty NOERROR for internal
        # names so clients fall back to A instead of waiting for a timeout.
        if @zone.lookup_a(name)
          @stats&.record(:aaaa_suppressed, name: name, remote: remote)
          return transaction.fail!(:NoError)
        end
      end

      # Only the upstream round trip is timed. The branches above are hash reads
      # against an in-memory zone, so timing them would add two clock reads to
      # the fastest path in the server to measure a number that is always ~0.
      began = @stats && Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = transaction.passthrough!(resolver)
      if @stats
        ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - began) * 1000
        # passthrough! turns "the resolver returned nothing" into ServFail
        # itself, so a ServFail here is either the upstream's own answer or an
        # upstream we could not reach. Telling those apart would mean reaching
        # into async-dns; the panel labels the bucket for both rather than
        # claiming to know which one it was.
        code = RCODES[transaction.response&.rcode] || :NoError
        @stats.record((code == :ServFail) ? :upstream_fail : :upstream_ok,
          name: name, remote: remote, ms: ms)
      end
      result
    rescue => e
      @stats&.record(:servfail, name: name, remote: remote)
      # No query name in the journal. A resolver log is a record of what
      # everyone on the tunnel looked at, and the whole point of keeping the
      # counters in memory is that it never lands on disk — writing the name
      # here on the failure path would undo that one ServFail at a time.
      Console.error(self, "resolution failed", exception: e)
      transaction.fail!(:ServFail)
    end

    private

    # Set by async-dns's datagram and stream handlers. Guarded because a
    # transaction built without one, or over a non-IP socket, must not take
    # resolution down for the sake of attributing a query.
    def remote_ip(transaction)
      addr = transaction[:remote_address]
      addr.ip_address if addr.respond_to?(:ip_address)
    rescue SocketError
      nil
    end

    # Every Resolv resource class carries TypeValue, but a caller could hand us
    # something else; an unknown type just falls through to the upstream.
    def type_of(resource_class)
      resource_class::TypeValue
    rescue NameError
      nil
    end
  end
end
