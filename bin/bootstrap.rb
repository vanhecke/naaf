#!/usr/bin/env ruby
# frozen_string_literal: true
#
#   bootstrap.rb                      first boot: server keys, admin password,
#                                     network facts, and naaf.conf seeds
#   bootstrap.rb --refresh-network    update ONLY the box-specific facts
#                                     (endpoint_v4/v6, wan_interface). Used after
#                                     restoring a database onto a new box, where
#                                     those three travel across but are wrong.
#                                     Never touches keys or the admin password.
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "io/console"
require "naaf/config"
require "naaf/db"
require "naaf/helper_client"
require "naaf/bootstrap"

def detect_wan
  iface = `ip -o -4 route show to default`.split[4].to_s
  iface.empty? ? Naaf::Config["NAAF_WAN_INTERFACE"].to_s : iface
end

def detect_endpoints
  v4 = Naaf::Config["NAAF_ENDPOINT_V4"].to_s.strip
  v6 = Naaf::Config["NAAF_ENDPOINT_V6"].to_s.strip
  v4 = Naaf::Bootstrap.detect_public_ip(4) if v4.empty?
  v6 = Naaf::Bootstrap.detect_public_ip(6) if v6.empty?
  warn "WARNING: could not determine a public IPv4 address." if v4.empty?
  [v4, v6]
end

if ARGV.include?("--refresh-network")
  Naaf.settings # ensure the row exists
  v4, v6 = detect_endpoints
  updated = Naaf::Bootstrap.refresh_network!(
    Naaf.db, endpoint_v4: v4, endpoint_v6: v6, wan_interface: detect_wan
  )
  if updated.empty?
    warn "nothing detected — leaving every stored value alone"
  else
    puts "refreshed: #{updated.map { |k, v| "#{k}=#{v}" }.join(" ")}"
  end
  exit 0
end

keys = Naaf::HelperClient.new.genkeys

password = Naaf::Bootstrap.admin_password(prompt: lambda {
  print "Admin password: "
  pw = $stdin.noecho(&:gets)
  puts
  pw
})

Naaf.settings # ensure the row exists

# Seed from naaf.conf before persisting the identity, so a non-default subnet or
# port is in place before anything reads it. First boot only — 50-bringup.sh will
# not re-run this once server_pubkey is set.
seeded = Naaf::Bootstrap.seed_settings!(Naaf.db)
puts "seeded from naaf.conf: #{seeded.keys.join(", ")}" unless seeded.empty?

v4, v6 = detect_endpoints
pubkey = Naaf::Bootstrap.persist!(
  Naaf.db,
  keys: keys,
  password: password,
  endpoint_v4: v4,
  endpoint_v6: v6,
  wan_interface: detect_wan,
  endpoint_host: Naaf::Bootstrap.endpoint_host
)
puts "server pubkey: #{pubkey}"
