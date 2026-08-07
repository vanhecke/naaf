#!/usr/bin/env ruby
# frozen_string_literal: true
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "io/console"
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
pubkey = Naaf::Bootstrap.persist!(
  Naaf.db,
  keys: keys,
  password: password,
  endpoint_v4: `curl -4 -s --max-time 5 ifconfig.co`.strip,
  endpoint_v6: `curl -6 -s --max-time 5 ifconfig.co`.strip,
  wan_interface: `ip -o -4 route show to default`.split[4].to_s,
  endpoint_host: Naaf::Bootstrap.endpoint_host
)
puts "server pubkey: #{pubkey}"
