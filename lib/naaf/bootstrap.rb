# frozen_string_literal: true

require "bcrypt"
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
      h = ENV["NAAF_ENDPOINT_HOST"].to_s.strip
      h.empty? ? nil : h
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
