# frozen_string_literal: true

require "ipaddr"
require "socket"

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

    # nil rather than an exception: callers decide what an unparseable value
    # means (a form refusal, a skipped renderer row).
    def self.parse_v4(cidr)
      ip = IPAddr.new(cidr.to_s)
      ip.ipv4? ? ip : nil
    rescue IPAddr::Error
      nil
    end

    # Two IPv4 CIDRs overlap when either network address sits inside the other.
    # Adjacent prefixes (10.0.0.0/24 and 10.0.1.0/24) do not.
    def self.overlap?(a, b)
      na = parse_v4(a)
      nb = parse_v4(b)
      return false unless na && nb
      na.include?(nb.to_range.first) || nb.include?(na.to_range.first)
    end

    # Collapse IPv4 CIDRs into non-overlapping nft interval elements. An
    # `flags interval` set rejects overlaps outright, and the ruleset is one
    # `nft -f` transaction — so a single overlapping pair would fail every
    # apply. The UI refuses overlaps; the renderer stays total.
    def self.merge_v4_cidrs(cidrs)
      ranges = cidrs.filter_map { |c|
        ip = parse_v4(c)
        next unless ip
        r = ip.to_range
        [r.first.to_i, r.last.to_i]
      }.sort
      merged = ranges.each_with_object([]) { |(first, last), acc|
        if acc.any? && first <= acc.last[1] + 1
          acc.last[1] = last if last > acc.last[1]
        else
          acc << [first, last]
        end
      }
      merged.map { |first, last| v4_element(first, last) }
    end

    def self.v4_element(first, last)
      lo = IPAddr.new(first, Socket::AF_INET)
      return lo.to_s if first == last
      prefix = exact_v4_prefix(first, last)
      prefix ? "#{lo}/#{prefix}" : "#{lo}-#{IPAddr.new(last, Socket::AF_INET)}"
    end
    private_class_method :v4_element

    def self.exact_v4_prefix(first, last)
      size = last - first + 1
      return unless size.positive? && (size & (size - 1)).zero?
      prefix = 32 - Math.log2(size).to_i
      net = IPAddr.new(first, Socket::AF_INET).mask(prefix)
      prefix if net.to_i == first && net.to_range.last.to_i == last
    end
    private_class_method :exact_v4_prefix
  end
end
