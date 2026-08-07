# frozen_string_literal: true

module Naaf
  class Zone
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
      self
    end

    def lookup_a(name) = @a[self.class.normalize(name)]
    def lookup_ptr(name) = @ptr[self.class.normalize(name)]
  end
end
