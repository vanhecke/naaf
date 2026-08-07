# frozen_string_literal: true

require_relative "helper_client"
require_relative "renderers/wireguard"
require_relative "renderers/nftables"

module WGCP
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

      @db[:clients].each do |c|
        peer = live[c[:pubkey]] or next
        @db[:clients].where(id: c[:id]).update(
          last_handshake_at: (peer[:handshake].zero? ? nil : Time.at(peer[:handshake])),
          endpoint: peer[:endpoint],
          rx_bytes: peer[:rx],
          tx_bytes: peer[:tx]
        )
      end

      expected = @db[:clients].where(enabled: true).select_map(:pubkey).to_set
      apply! if expected != live.keys.to_set
    end

    private

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
