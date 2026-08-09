# frozen_string_literal: true

require_relative "helper_client"
require_relative "renderers/wireguard"
require_relative "renderers/nftables"

module Naaf
  class Reconciler
    attr_reader :helper

    def initialize(db, zone, helper: HelperClient.new)
      @db = db
      @zone = zone
      @helper = helper
    end

    def apply!
      wg = Renderers::WireGuard.render(@db)
      nft = Renderers::Nftables.render(@db)
      @helper.apply(wg_conf: wg, nft_ruleset: nft)
      @zone.reload!
      Console.info(self, "applied", peers: @db[:clients].where(enabled: true).count)
      true
    end

    # Refresh handshake/traffic stats and re-apply if the kernel has drifted
    # from the DB. The DB is always the source of truth.
    def poll!
      live = parse_dump(@helper.dump)

      # Materialize before writing. Updating the clients table while streaming a
      # cursor over that same table is exactly the shape SQLite leaves
      # undefined, and one transaction around the whole batch means one fsync
      # instead of one per client — this runs on the shared reactor, and the
      # sqlite3 driver never releases the GVL, so every commit here freezes the
      # web server and the DNS server along with it.
      rows = @db[:clients].all
      @db.transaction do
        rows.each do |c|
          peer = live[c[:pubkey]] or next
          attrs = {
            last_handshake_at: (peer[:handshake].zero? ? nil : Time.at(peer[:handshake])),
            endpoint: peer[:endpoint],
            rx_bytes: peer[:rx],
            tx_bytes: peer[:tx]
          }
          next if unchanged?(c, attrs, peer[:handshake])
          @db[:clients].where(id: c[:id]).update(attrs)
        end
      end

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
