# frozen_string_literal: true

module Naaf
  module Renderers
    # Desired extra addresses and proto-158 routes on the WireGuard interface.
    # Pure: the helper is what actually runs `ip`. proto 158 is how apply
    # recognizes site routes without reading kernel state back into the DB.
    module Routes
      PROTO = 158

      def self.desired(db)
        s = Naaf.settings
        wg = s[:wg_interface]
        routes = []
        addresses = []
        db[:sites].where(enabled: true).order(:name).each do |site|
          addresses << {addr: site[:address], dev: wg} if site[:address]
          db[:site_networks].where(site_id: site[:id]).order(:cidr).each do |n|
            routes << {dst: n[:cidr], dev: wg}
          end
        end
        {routes: routes, addresses: addresses}
      end
    end
  end
end
