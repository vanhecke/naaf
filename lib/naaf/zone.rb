# frozen_string_literal: true

module Naaf
  class Zone
    # The DNS upstream is carried here rather than read per query. Every settings
    # save goes submit -> Reconciler#apply! -> Zone#reload!, so this is already
    # the exact invalidation point, and the resolver gets the new value without a
    # blocking SELECT on the passthrough path (the hot path for a full-tunnel
    # client).
    attr_reader :upstream, :forwarders, :generation

    def initialize(db)
      @db = db
      reload!
    end

    # The one definition of the records the resolver synthesizes from the DB.
    # Returned in ascending precedence order ([apex, *clients, gateway]) so a
    # last-wins fold in #reload! reproduces the resolver's semantics: a client
    # whose bare hostname equals the domain wins the apex, and the gateway wins
    # any colliding client. PTR rows are carried alongside the A rows and split
    # apart by the caller. Static dns_records are NOT included here — #reload!
    # overlays them last so they override an auto record of the same name.
    def self.auto_records(db)
      s = Naaf.settings
      domain = s[:dns_domain]
      recs = []
      recs << {name: domain, rtype: "A", value: s[:server_ip], source: :apex}
      db[:clients].order(:wg_ip).each do |c|
        fqdn = "#{c[:hostname]}.#{domain}"
        recs << {name: fqdn, rtype: "A", value: c[:wg_ip], source: :client}
        recs << {name: c[:hostname], rtype: "A", value: c[:wg_ip], source: :client_bare}
        recs << {name: reverse_name(c[:wg_ip]), rtype: "PTR", value: "#{fqdn}.", source: :ptr}
      end
      recs << {name: "gateway.#{domain}", rtype: "A", value: s[:server_ip], source: :gateway}
      recs
    end

    def self.normalize(n) = n.to_s.downcase.chomp(".")

    def self.reverse_name(ip)
      "#{ip.split(".").reverse.join(".")}.in-addr.arpa"
    end

    def reload!
      a = {}
      ptr = {}
      self.class.auto_records(@db).each do |rec|
        if rec[:rtype] == "PTR"
          ptr[rec[:name]] = rec[:value]
        else
          a[rec[:name]] = rec[:value]
        end
      end
      @db[:dns_records].each { |r| a[r[:name]] = r[:value] if r[:rtype] == "A" }
      @a = a
      @ptr = ptr
      # A disabled site contributes no forwarder. It is not a kernel peer and its
      # route is not installed, so its resolver is unreachable — dropping the
      # rule turns a guaranteed timeout into an ordinary upstream answer.
      disabled = @db[:sites].where(enabled: false).select_map(:id).to_set
      fwd = {}
      @db[:dns_forwarders].order(:suffix).each do |row|
        next if row[:site_id] && disabled.include?(row[:site_id])
        fwd[row[:suffix]] = [row[:server], row[:port]].freeze
      end
      # Whole-object swap, the same discipline as @a and @ptr: one fiber per
      # datagram means a half-rebuilt hash must never be visible.
      @forwarders = fwd.freeze
      # DNSServer memoizes a Resolver per [ip, port] and keys that memo on this
      # counter, so a reload that happens to produce an identical hash still
      # invalidates it.
      @generation = @generation.to_i + 1
      @upstream = Naaf.settings[:dns_upstream]
      self
    end

    def lookup_a(name) = @a[self.class.normalize(name)]
    def lookup_ptr(name) = @ptr[self.class.normalize(name)]

    # dnsmasq-style suffix match, longest wins: the stored suffix `example.com`
    # matches `example.com` and `foo.bar.example.com`. nil means "use the default
    # upstream", so a box with no forwarders keeps exactly the code path it had
    # before this existed, at the cost of one Hash#empty?.
    def upstream_for(name)
      return nil if @forwarders.empty?
      n = self.class.normalize(name)
      loop do
        hit = @forwarders[n]
        return hit if hit
        i = n.index(".") or return nil
        n = n[(i + 1)..]
      end
    end
  end
end
