# frozen_string_literal: true

require_relative "../config"

module Naaf
  module Renderers
    # Desired state of the internet-exit interface, routing table 159, and the
    # three policy rules that send full-tunnel client traffic into it.
    #
    # Pure: the helper is what creates the iface, runs `wg syncconf`, and
    # installs the rules. Returns nil when there is no enabled row — that is
    # the disable path.
    #
    # The conf is `wg setconf` grammar, not wg-quick grammar. `wg(8)` accepts
    # only PrivateKey / ListenPort / FwMark in [Interface] and PublicKey /
    # PresharedKey / AllowedIPs / Endpoint / PersistentKeepalive in [Peer];
    # an `MTU =` line is a hard parse failure. MTU is a top-level field and
    # is applied with `ip link`.
    module Exit
      TABLE = 159
      MARK = 159
      PREF_MARK = 15800
      PREF_SUBNET = 15850
      PREF_EXIT = 15900

      def self.desired(db)
        row = db[:exits].where(enabled: true).first
        return if row.nil?

        s = Naaf.settings
        wg = s[:wg_interface]
        exit_if = Config["NAAF_EXIT_INTERFACE"]
        {
          conf: conf(row),
          dev: exit_if,
          address: row[:address],
          mtu: row[:mtu],
          table: TABLE,
          mark: MARK,
          routes: routes(db, wg, exit_if),
          rules: rules(s[:wg_subnet], wg)
        }
      end

      def self.conf(row)
        out = +"[Interface]\n"
        out << "PrivateKey = #{row[:privkey]}\n"
        out << "\n[Peer]\n"
        out << "PublicKey = #{row[:pubkey]}\n"
        out << "PresharedKey = #{row[:psk]}\n" if row[:psk] && !row[:psk].empty?
        out << "AllowedIPs = 0.0.0.0/0\n"
        out << "Endpoint = #{row[:endpoint]}\n"
        out << "PersistentKeepalive = #{row[:keepalive]}\n"
        out
      end
      private_class_method :conf

      def self.routes(db, wg, exit_if)
        cidrs = []
        addrs = []
        db[:sites].where(enabled: true).order(:name).each do |site|
          addrs << {dst: "#{site[:address]}/32", dev: wg} if site[:address]
          db[:site_networks].where(site_id: site[:id]).order(:cidr).each do |n|
            cidrs << {dst: n[:cidr], dev: wg}
          end
        end
        cidrs + addrs + [{dst: "default", dev: exit_if}]
      end
      private_class_method :routes

      def self.rules(wg_subnet, wg)
        [
          {pref: PREF_MARK, spec: ["fwmark", MARK.to_s, "lookup", "main"]},
          {pref: PREF_SUBNET, spec: ["iif", wg, "to", wg_subnet, "lookup", "main"]},
          {pref: PREF_EXIT, spec: ["iif", wg, "lookup", TABLE.to_s]}
        ]
      end
      private_class_method :rules
    end
  end
end
