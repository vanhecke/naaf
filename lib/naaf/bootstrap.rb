# frozen_string_literal: true

require "bcrypt"
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
  end
end
