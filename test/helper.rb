# frozen_string_literal: true

# Shared test setup. Required (idempotently) at the top of every test file.
# The renderers, IPAM, Zone and ConfigBuilder all read Naaf.settings from the
# memoized Naaf.db singleton, so tests share one SQLite file and reset it
# between examples. sus runs sequentially in one process, so this is race-free.

require "securerandom"
require "tmpdir"
require "console"

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
  [:extra_routes, :dns_records, :port_forwards, :exposed_ports, :clients, :settings].each do |t|
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
def make_client(db, name:, wg_ip:, hostname: name, pubkey: "PUB-#{name}", psk: "PSK-#{name}", enabled: true, **extra)
  db[:clients].insert(
    name: name, hostname: hostname, wg_ip: wg_ip,
    pubkey: pubkey, psk: psk, enabled: enabled, created_at: Time.now, **extra
  )
end
