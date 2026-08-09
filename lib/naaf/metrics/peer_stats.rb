# frozen_string_literal: true

require_relative "num"

module Naaf
  module Metrics
    # Per-peer WireGuard telemetry, published by Reconciler#poll!.
    #
    # The collector deliberately does NOT read `wg show dump` itself, for two
    # reasons. First, there is no second source to read: WireGuard exposes peer
    # state only through admin-gated generic netlink — there is no
    # /proc/net/wireguard, no sysfs, no debugfs — so any peer data has to come
    # through the root helper. Second, and decisively, line 1 field 0 of that
    # dump IS the server private key and every peer line's field 1 is that
    # peer's preshared key. A second parser feeding a structure that gets
    # rendered into a browser is one careless change away from leaking both.
    #
    # So the one existing reader stays the only reader. poll! already holds the
    # previous counters (from the database row) and the new ones (from the dump)
    # at the same moment, which is exactly what a rate needs, and it publishes
    # the result here as a frozen snapshot.
    #
    # The consequence is that peer throughput is only as fresh as
    # NAAF_RECONCILE_INTERVAL, which is coarser than the metrics tick. The
    # dashboard says so rather than pretending otherwise, and `generation` lets
    # the collector append one sparkline point per reconcile instead of fifteen
    # identical ones.
    class PeerStats
      EMPTY = {}.freeze

      def initialize
        @generation = 0
        @sample = EMPTY
        @at = nil
        @interval = nil
      end

      attr_reader :generation, :sample, :at, :interval

      # Reconciler fiber only. A whole-object swap with no yield in it, so the
      # collector can never observe a half-written sample.
      def publish(sample, at:, interval:)
        @sample = sample.freeze
        @at = at
        @interval = interval
        @generation += 1
        self
      end

      # Build one peer's entry. `previous` is the counter stored in the database
      # from the last poll; `current` is what the kernel reports now.
      def self.entry(previous_rx:, previous_tx:, rx:, tx:, handshake:, endpoint:, interval:)
        {
          rx_bytes: rx,
          tx_bytes: tx,
          rx_bps: Num.rate(previous_rx, rx, interval),
          tx_bps: Num.rate(previous_tx, tx, interval),
          handshake: handshake,
          endpoint: endpoint
        }.freeze
      end
    end
  end
end
