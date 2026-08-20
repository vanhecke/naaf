# frozen_string_literal: true

# Shared test setup. Required (idempotently) at the top of every test file.
# The renderers, IPAM, Zone and ConfigBuilder all read Naaf.settings from the
# memoized Naaf.db singleton, so tests share one SQLite file and reset it
# between examples. sus runs sequentially in one process, so this is race-free.

require "securerandom"
require "tmpdir"
# Production logs every expected failure as JSON on stderr (a 500 the error
# handler swallowed, a tick! that rescued, apply! succeeding). That is noise
# in the suite. CONSOLE_OUTPUT=Null is the console gem's own sink; override
# with CONSOLE_OUTPUT=Serialized (or Terminal) to see the records again.
# Must be set before the first Console.logger is built.
ENV["CONSOLE_OUTPUT"] ||= "Null"
require "console"
require "bcrypt"

# Default bcrypt cost is tens of milliseconds per hash AND per verify. Almost
# every app example logs in; without this the suite spends most of its wall
# time stretching a password nobody is attacking.
BCrypt::Engine.cost = 4

# Hermetic on purpose. NAAF_DB is forced, never ||=: now that naaf.conf is
# shell-sourceable it is easy to have NAAF_DB exported in a working shell, and
# reset_db! DELETEs every row of whatever it points at.
ENV["NAAF_CONF"] = File::NULL # readable, parses to {} — also exercises the no-file path
ENV["NAAF_DB"] = File.join(Dir.mktmpdir("naaf-test-"), "test.db")
ENV["NAAF_BACKUP_ENABLED"] = "0"
ENV["NAAF_SESSION_SECRET"] ||= SecureRandom.hex(32)

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "naaf/db"

# Wipe every table, insert a fresh default settings row, then apply overrides.
# Returns the shared Naaf.db handle.
def reset_db!(**settings)
  db = Naaf.db
  [:dns_forwarders, :site_networks, :sites, :extra_routes, :dns_records, :port_forwards, :exposed_ports, :clients, :settings].each do |t|
    db[t].delete
  end
  # clients.id is AUTOINCREMENT, whose counter survives a plain delete via
  # sqlite_sequence — reset it so ids are deterministic (start at 1) per test.
  db.run("DELETE FROM sqlite_sequence") if db.table_exists?(:sqlite_sequence)
  db[:settings].insert
  db[:settings].update(settings) unless settings.empty?
  db
end

# Insert a client with sensible defaults; returns the new row id.
# standardrb's Lint/FloatComparison rejects `expect(x).to be == 1.5`, and in
# general it is right to. Round to a fixed number of decimals and compare the
# resulting string: exact, lint-clean, and a failure still prints the number.
def decimals(value, places = 3)
  value.nil? ? nil : format("%.#{places}f", value)
end

def make_client(db, name:, wg_ip:, hostname: name, pubkey: "PUB-#{name}", psk: "PSK-#{name}", enabled: true, **extra)
  db[:clients].insert(
    name: name, hostname: hostname, wg_ip: wg_ip,
    pubkey: pubkey, psk: psk, enabled: enabled, created_at: Time.now, **extra
  )
end

# A site is a remote WireGuard server, not an IPAM client. `networks` is the
# list of CIDRs installed as that peer's AllowedIPs.
def make_site(db, name:, pubkey: "SITE-#{name}", endpoint: "203.0.113.9:51820",
  psk: nil, keepalive: 25, address: nil, masquerade: false, enabled: true,
  networks: [], dns_server: nil, dns_port: 53, domains: [])
  id = db[:sites].insert(
    name: name, pubkey: pubkey, psk: psk, endpoint: endpoint,
    keepalive: keepalive, address: address, masquerade: masquerade,
    enabled: enabled, created_at: Time.now
  )
  networks.each { |cidr| db[:site_networks].insert(site_id: id, cidr: cidr) }
  if dns_server
    domains.each do |suffix|
      db[:dns_forwarders].insert(site_id: id, suffix: suffix, server: dns_server, port: dns_port)
    end
  end
  id
end

# Run the block with wstunnel switched on. Naaf::Config re-reads ENV on every
# call and NAAF_CONF already points at File::NULL, so assigning ENV is the whole
# seam — there is nothing memoized to reset. That is also precisely why
# ConfigBuilder.wstunnel?/available_flavors are methods and never constants
# frozen at load time.
#
# Any key may be overridden, not just the wstunnel ones (the TLS matrix needs
# NAAF_ACME_ENABLED too); a nil value unsets the variable for the duration.
# NAAF_WSTUNNEL_PATH_PREFIX has no DEFAULTS entry by design and is read straight
# from ENV, so it must be supplied here rather than through a naaf.conf.
def with_wstunnel(overrides = {})
  vars = {
    "NAAF_WSTUNNEL_ENABLED" => "1",
    "NAAF_WSTUNNEL_PATH_PREFIX" => "t35tpr3f1x"
  }.merge(overrides)
  saved = vars.keys.to_h { |k| [k, ENV[k]] }
  vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  yield
ensure
  saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end
