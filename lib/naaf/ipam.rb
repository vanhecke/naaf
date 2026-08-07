# frozen_string_literal: true

require "ipaddr"

module Naaf
  module IPAM
    def self.allocate(db)
      s = Naaf.settings
      net = IPAddr.new(s[:wg_subnet])
      taken = db[:clients].select_map(:wg_ip).to_set
      taken << s[:server_ip]

      range = net.to_range
      last = range.last
      range.each_with_index do |addr, i|
        next if i.zero?          # network address
        next if addr == last     # broadcast
        ip = addr.to_s
        return ip unless taken.include?(ip)
      end
      raise "wg subnet #{s[:wg_subnet]} exhausted"
    end
  end
end
