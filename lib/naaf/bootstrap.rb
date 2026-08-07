# frozen_string_literal: true

require "bcrypt"
require "ipaddr"
require_relative "config"
require_relative "db"

module Naaf
  # First-boot provisioning helpers, split out of bin/bootstrap.rb so the
  # environment-driven paths (unattended cloud-init) are testable without a live
  # helper socket or network. The script gathers side-effectful inputs (helper
  # genkeys, curl/ip detection, the password prompt) and hands them here.
  module Bootstrap
    # The admin password: prefer NAAF_ADMIN_PASSWORD (unattended provisioning),
    # otherwise fall back to the interactive prompt block.
    def self.admin_password(prompt: nil)
      env = ENV["NAAF_ADMIN_PASSWORD"].to_s
      return env.strip unless env.strip.empty?
      raise "NAAF_ADMIN_PASSWORD is unset and no interactive prompt is available" unless prompt
      prompt.call.to_s.strip
    end

    # The client-config Endpoint host from NAAF_ENDPOINT_HOST, or nil to leave the
    # stored value untouched (raw-IP endpoint).
    def self.endpoint_host
      h = Config["NAAF_ENDPOINT_HOST"].to_s.strip
      h.empty? ? nil : h
    end

    # Seed the settings row from naaf.conf. First boot only — the caller guards on
    # server_pubkey being unset, and after that the database is authoritative and
    # the admin UI is what edits these. Columns are written only when the config
    # value differs from Config::DEFAULTS, so an operator who never touched
    # naaf.conf gets exactly the schema defaults and there is no second source of
    # truth for them.
    def self.seed_settings!(db)
      row = Config::SEEDS.filter_map { |col, key|
        v = Config[key]
        next if v.nil? || v.to_s.empty? || v == Config::DEFAULTS.fetch(key)
        [col, (col == :listen_port || col == :mtu) ? Integer(v, 10) : v]
      }.to_h
      db[:settings].update(row) unless row.empty?
      row
    end

    # Persist the server identity, admin credential, and detected network facts.
    # endpoint_host is written only when provided, so an unset env var never
    # clobbers a host configured later via the settings UI.
    def self.persist!(db, keys:, password:, endpoint_v4:, endpoint_v6:, wan_interface:, endpoint_host: nil)
      raise ArgumentError, "password is required" if password.to_s.empty?
      row = {
        server_privkey: keys[:private_key],
        server_pubkey: keys[:public_key],
        endpoint_v4: endpoint_v4,
        endpoint_v6: endpoint_v6,
        wan_interface: wan_interface,
        admin_pw_hash: BCrypt::Password.create(password)
      }
      row[:endpoint_host] = endpoint_host unless endpoint_host.nil?
      db[:settings].update(row)
      keys[:public_key]
    end

    # Update only the facts that describe THIS box. These three travel with a
    # restored database and are wrong on the new machine, so a
    # restore-onto-a-new-box migration has to refresh them — see docs/BACKUP.md.
    # Deliberately touches neither the keys nor the admin password: the whole
    # value of that migration is that the server identity survives.
    #
    # Blank values are skipped rather than written, so a failed IP lookup leaves
    # the previous value alone instead of clobbering it with "".
    def self.refresh_network!(db, endpoint_v4:, endpoint_v6:, wan_interface:)
      row = {
        endpoint_v4: endpoint_v4,
        endpoint_v6: endpoint_v6,
        wan_interface: wan_interface
      }.reject { |_, v| v.to_s.strip.empty? }
      db[:settings].update(row) unless row.empty?
      row
    end

    # Public IP discovery. Tries several independent services because the first
    # boot of a brand-new box is exactly when one of them is having a bad day,
    # and a blank endpoint_v4 produces client configs that cannot connect.
    # Returns "" if every attempt fails; callers must treat that as "leave the
    # stored value alone", never as a value to write.
    RESOLVERS = [
      "https://ifconfig.co",
      "https://api.ipify.org",
      "https://icanhazip.com"
    ].freeze

    def self.detect_public_ip(version, resolvers: RESOLVERS, runner: nil)
      runner ||= ->(url) { `curl -#{version} -s --max-time 5 #{url} 2>/dev/null` }
      resolvers.each do |url|
        2.times do
          ip = runner.call(url).to_s.strip
          return ip unless ip.empty? || !valid_ip?(ip, version)
        end
      end
      ""
    end

    def self.valid_ip?(str, version)
      addr = IPAddr.new(str)
      (version == 4) ? addr.ipv4? : addr.ipv6?
    rescue IPAddr::Error
      false
    end
  end
end
