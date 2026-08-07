# frozen_string_literal: true

require "resolv"
require "async/dns"

module Naaf
  class DNSServer < Async::DNS::Server
    IN = Resolv::DNS::Resource::IN

    # NOTE: async-dns 1.4 takes `endpoint` as a POSITIONAL argument to
    # Server#initialize (verified against the installed 1.4.1 source), so we
    # pass it positionally with `super(endpoint)`, not `super(endpoint:)`.
    # `Server.default_endpoint` binds localhost only; the caller constructs an
    # endpoint bound to the WireGuard IP and hands it in here.
    # `upstream` is a String or a callable. Passing a callable (bin/naaf passes
    # `-> { zone.upstream }`) makes an edit in the Settings UI take effect on the
    # next query instead of the next restart.
    def initialize(zone:, upstream:, endpoint:)
      @zone = zone
      @upstream = upstream
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
      case resource_class.to_s
      when /IN::A\z/
        if (ip = @zone.lookup_a(name))
          return transaction.respond!(ip, ttl: 60)
        end
      when /IN::PTR\z/
        if (host = @zone.lookup_ptr(name))
          return transaction.respond!(Resolv::DNS::Name.create(host))
        end
      when /IN::AAAA\z/
        # Internal network is IPv4-only. Return an empty NOERROR for internal
        # names so clients fall back to A instead of waiting for a timeout.
        return transaction.fail!(:NoError) if @zone.lookup_a(name)
      end

      transaction.passthrough!(resolver)
    rescue => e
      Console.error(self, "resolution failed", name: name.to_s, exception: e)
      transaction.fail!(:ServFail)
    end
  end
end
