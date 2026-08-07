#!/usr/bin/env ruby
# frozen_string_literal: true
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "io/console"
require "naaf/config"
require "naaf/db"
require "naaf/helper_client"
require "naaf/bootstrap"

keys = Naaf::HelperClient.new.genkeys

password = Naaf::Bootstrap.admin_password(prompt: lambda {
  print "Admin password: "
  pw = $stdin.noecho(&:gets)
  puts
  pw
})

Naaf.settings # ensure the row exists

# Seed from naaf.conf before persisting the identity, so a non-default subnet or
# port set in the config file is in place before anything reads it. First boot
# only; 50-bringup.sh will not re-run this once server_pubkey is set.
seeded = Naaf::Bootstrap.seed_settings!(Naaf.db)
puts "seeded from naaf.conf: #{seeded.keys.join(", ")}" unless seeded.empty?

# The detected WAN interface overrides the seed: `ip route` knows the truth about
# this box, and NAAF_WAN_INTERFACE is only a fallback for the unusual case where
# detection cannot work.
detected_wan = `ip -o -4 route show to default`.split[4].to_s
wan = detected_wan.empty? ? Naaf::Config["NAAF_WAN_INTERFACE"] : detected_wan

pubkey = Naaf::Bootstrap.persist!(
  Naaf.db,
  keys: keys,
  password: password,
  endpoint_v4: `curl -4 -s --max-time 5 ifconfig.co`.strip,
  endpoint_v6: `curl -6 -s --max-time 5 ifconfig.co`.strip,
  wan_interface: wan,
  endpoint_host: Naaf::Bootstrap.endpoint_host
)
puts "server pubkey: #{pubkey}"
