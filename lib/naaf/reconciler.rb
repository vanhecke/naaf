# frozen_string_literal: true

require_relative "helper_client"
require_relative "renderers/wireguard"
require_relative "renderers/nftables"
require_relative "metrics/peer_stats"

module Naaf
  class Reconciler
    attr_reader :helper, :last_poll_at, :last_apply_at, :last_error, :last_error_at

    # `peers` is an optional Metrics::PeerStats sink. This is the only place in
    # the process that reads kernel peer state, and it stays that way on
    # purpose — see the comment on PeerStats.
    def initialize(db, zone, helper: HelperClient.new, peers: nil,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @db = db
      @zone = zone
      @helper = helper
      @peers = peers
      @clock = clock
    end

    # The reactor loop body, with the rescue extracted so "a failed reconcile
    # never takes down the reactor" is a testable claim rather than a comment in
    # bin/naaf. Bare rescue (StandardError) so Async::Stop still propagates and
    # the task can actually be shut down. Mirrors Naaf::Backup.tick!.
    def self.tick!(reconciler)
      reconciler.poll!
    rescue => e
      reconciler.failed!(e)
      Console.error(reconciler, "reconcile failed", exception: e)
      nil
    end

    # Recorded rather than only logged, so the dashboard can show that
    # reconciling has stopped working without anyone reading the journal.
    def failed!(error)
      @last_error = error.message
      @last_error_at = Time.now
    end

    def apply!
      wg = Renderers::WireGuard.render(@db)
      nft = Renderers::Nftables.render(@db)
      @helper.apply(wg_conf: wg, nft_ruleset: nft)
      @zone.reload!
      @last_apply_at = Time.now
      Console.info(self, "applied", peers: @db[:clients].where(enabled: true).count)
      true
    end

    # Refresh handshake/traffic stats and re-apply if the kernel has drifted
    # from the DB. The DB is always the source of truth.
    def poll!
      now = Time.now
      mono = @clock.call
      # The real elapsed time between polls, not the nominal interval: a tick
      # delayed behind an apply! would otherwise inflate every rate.
      interval = @last_poll_mono && (mono - @last_poll_mono)

      live = parse_dump(@helper.dump)

      # Materialize before writing. Updating the clients table while streaming a
      # cursor over that same table is exactly the shape SQLite leaves
      # undefined, and one transaction around the whole batch means one fsync
      # instead of one per client — this runs on the shared reactor, and the
      # sqlite3 driver never releases the GVL, so every commit here freezes the
      # web server and the DNS server along with it.
      rows = @db[:clients].all
      measured = {}
      @db.transaction do
        rows.each do |c|
          peer = live[c[:pubkey]] or next
          attrs = {
            last_handshake_at: (peer[:handshake].zero? ? nil : Time.at(peer[:handshake])),
            endpoint: peer[:endpoint],
            rx_bytes: peer[:rx],
            tx_bytes: peer[:tx]
          }
          # The stored row still holds the previous counters here, which is what
          # makes this the one place a per-peer rate can be computed at all.
          measured[c[:pubkey]] = Metrics::PeerStats.entry(
            previous_rx: c[:rx_bytes], previous_tx: c[:tx_bytes],
            rx: peer[:rx], tx: peer[:tx],
            handshake: peer[:handshake], endpoint: peer[:endpoint],
            interval: interval
          )
          next if unchanged?(c, attrs, peer[:handshake])
          @db[:clients].where(id: c[:id]).update(attrs)
        end
      end

      @peers&.publish(measured, at: now, interval: interval)
      @last_poll_mono = mono
      @last_poll_at = now
      @last_error = nil

      expected = @db[:clients].where(enabled: true).select_map(:pubkey).to_set
      apply! if expected != live.keys.to_set
    end

    private

    # An idle peer reports the same counters every poll, and rewriting a row to
    # the same values still costs a WAL frame that Litestream then replicates.
    # Compare the handshake as an epoch integer rather than as a Time: the
    # column round-trips through SQLite at second precision, so the objects
    # differ even when the instant does not.
    def unchanged?(row, attrs, handshake)
      stored = row[:last_handshake_at]
      # `wg` reports 0 for a peer that has never handshaked and we store NULL,
      # so both sides normalize to 0. Written out rather than chained off a safe
      # navigation, because `nil&.to_time&.to_i` is nil and comparing that to 0
      # would rewrite every never-connected peer on every single poll.
      stored_epoch = stored ? stored.to_time.to_i : 0
      row[:rx_bytes] == attrs[:rx_bytes] &&
        row[:tx_bytes] == attrs[:tx_bytes] &&
        row[:endpoint] == attrs[:endpoint] &&
        stored_epoch == handshake
    end

    # `wg show wg0 dump`: first line is the interface, then one line per peer:
    # pubkey, psk, endpoint, allowed-ips, latest-handshake, rx, tx, keepalive
    def parse_dump(text)
      text.lines.drop(1).each_with_object({}) do |line, acc|
        f = line.chomp.split("\t")
        next if f.size < 8
        acc[f[0]] = {
          endpoint: ((f[2] == "(none)") ? nil : f[2]),
          handshake: f[4].to_i,
          rx: f[5].to_i,
          tx: f[6].to_i
        }
      end
    end
  end
end
