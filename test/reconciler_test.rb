# frozen_string_literal: true

require_relative "helper"
require "naaf/reconciler"
require "naaf/metrics/peer_stats"
require "naaf/renderers/routes"

# Minimal stand-ins so we can drive the reconciler without a live helper/kernel.
class FakeHelper
  attr_reader :applies, :last_apply
  attr_accessor :dump_text

  def initialize(dump_text)
    @dump_text = dump_text
    @applies = 0
    @last_apply = nil
  end

  def dump = @dump_text

  def apply(**kwargs)
    @applies += 1
    @last_apply = kwargs
    {ok: true}
  end
end

# Sequel writes every statement to any object in db.loggers, so this is the
# cheapest way to assert "no write happened" without reaching into the adapter.
class SQLSpy
  attr_reader :statements

  def initialize = @statements = []

  def info(msg) = @statements << msg.to_s
  def error(msg) = @statements << msg.to_s
  def warn(msg) = @statements << msg.to_s
  def debug(msg) = @statements << msg.to_s
end

class FakeZone
  attr_reader :reloads

  def initialize
    @reloads = 0
  end

  def reload!
    @reloads += 1
    self
  end
end

describe Naaf::Reconciler do
  before { @db = reset_db!(server_privkey: "x", server_pubkey: "y") }

  # `wg show wg0 dump`: first line = interface, then per-peer tab-separated:
  # pubkey psk endpoint allowed-ips latest-handshake rx tx keepalive
  def dump_for(pubkey, handshake:, endpoint: "1.2.3.4:51820", rx: 100, tx: 200)
    "SRVPRIV\tSRVPUB\t51820\toff\n" \
      "#{pubkey}\t(none)\t#{endpoint}\t10.8.0.2/32\t#{handshake}\t#{rx}\t#{tx}\t25\n"
  end

  def reconciler(dump_text)
    Naaf::Reconciler.new(@db, FakeZone.new, helper: FakeHelper.new(dump_text))
  end

  def sql_during
    spy = SQLSpy.new
    @db.loggers << spy
    yield
    spy.statements
  ensure
    @db.loggers.delete(spy)
  end

  it "parses a peer line into endpoint/handshake/rx/tx" do
    parsed = reconciler("").send(:parse_dump, dump_for("PEERPUB", handshake: 1_700_000_000))
    peer = parsed["PEERPUB"]
    expect(peer[:handshake]).to be == 1_700_000_000
    expect(peer[:endpoint]).to be == "1.2.3.4:51820"
    expect(peer[:rx]).to be == 100
    expect(peer[:tx]).to be == 200
  end

  it "maps a (none) endpoint to nil" do
    parsed = reconciler("").send(:parse_dump, dump_for("P", handshake: 0, endpoint: "(none)"))
    expect(parsed["P"][:endpoint]).to be_nil
  end

  it "skips the interface line and malformed short lines" do
    parsed = reconciler("").send(:parse_dump, "interface-line\nshort\tline\n")
    expect(parsed).to be(:empty?)
  end

  it "poll! writes handshake and traffic stats back to the matching client" do
    make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "PEERPUB")
    helper = FakeHelper.new(dump_for("PEERPUB", handshake: 1_700_000_000, rx: 42, tx: 99))
    r = Naaf::Reconciler.new(@db, FakeZone.new, helper: helper)
    r.poll!
    c = @db[:clients][pubkey: "PEERPUB"]
    expect(c[:rx_bytes]).to be == 42
    expect(c[:tx_bytes]).to be == 99
    expect(c[:last_handshake_at].nil?).to be == false
    expect(helper.applies).to be == 0 # peer set matches DB -> no re-apply
  end

  # An idle VPN reports identical counters every 30s forever. Rewriting the row
  # anyway costs a WAL frame per client per poll, which Litestream then ships to
  # the object store — for no new information.
  it "poll! issues no UPDATE when a peer's counters have not moved" do
    make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "PEERPUB")
    helper = FakeHelper.new(dump_for("PEERPUB", handshake: 1_700_000_000, rx: 42, tx: 99))
    r = Naaf::Reconciler.new(@db, FakeZone.new, helper: helper)
    r.poll!

    expect(sql_during { r.poll! }.grep(/UPDATE/)).to be(:empty?)
  end

  # `wg` reports handshake 0 for a peer that has never connected and the column
  # stores NULL. If those two are not normalized to the same thing, every
  # never-connected peer is rewritten on every poll — the exact churn the skip
  # exists to avoid, on the rows least likely to ever change.
  it "poll! issues no UPDATE for a peer that has never handshaked" do
    make_client(@db, name: "spare", wg_ip: "10.8.0.3", pubkey: "NEVER")
    helper = FakeHelper.new(dump_for("NEVER", handshake: 0, endpoint: "(none)", rx: 0, tx: 0))
    r = Naaf::Reconciler.new(@db, FakeZone.new, helper: helper)
    r.poll!

    expect(@db[:clients][pubkey: "NEVER"][:last_handshake_at]).to be_nil
    expect(sql_during { r.poll! }.grep(/UPDATE/)).to be(:empty?)
  end

  it "poll! still writes once a counter actually moves" do
    make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "PEERPUB")
    helper = FakeHelper.new(dump_for("PEERPUB", handshake: 1_700_000_000, rx: 42, tx: 99))
    r = Naaf::Reconciler.new(@db, FakeZone.new, helper: helper)
    r.poll!

    helper.dump_text = dump_for("PEERPUB", handshake: 1_700_000_000, rx: 43, tx: 99)
    expect(sql_during { r.poll! }.grep(/UPDATE/)).not.to be(:empty?)
    expect(@db[:clients][pubkey: "PEERPUB"][:rx_bytes]).to be == 43
  end

  # poll! is the ONLY reader of kernel peer state in the process, deliberately:
  # `wg show dump` line 1 field 0 is the server private key and every peer
  # line's field 1 is that peer's PSK, so a second parser feeding the dashboard
  # would put both one bug away from a browser. It is also the only place that
  # holds the previous counters (from the row) and the new ones (from the dump)
  # at the same instant, which is exactly what a rate needs.
  it "poll! publishes per-peer rates to the metrics sink" do
    make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "PEERPUB")
    peers = Naaf::Metrics::PeerStats.new
    helper = FakeHelper.new(dump_for("PEERPUB", handshake: 1_700_000_000, rx: 1000, tx: 2000))
    mono = 100.0
    r = Naaf::Reconciler.new(@db, FakeZone.new, helper: helper, peers: peers,
      clock: -> { mono })

    r.poll! # first poll has no previous instant, so no rate yet
    expect(peers.generation).to be == 1
    expect(peers.sample["PEERPUB"][:rx_bps]).to be_nil
    expect(peers.sample["PEERPUB"][:rx_bytes]).to be == 1000

    helper.dump_text = dump_for("PEERPUB", handshake: 1_700_000_100, rx: 3000, tx: 2000)
    mono += 30.0
    r.poll!
    expect(peers.generation).to be == 2
    # 2000 bytes over 30 seconds, measured against the real elapsed time rather
    # than the nominal reconcile interval.
    expect(decimals(peers.sample["PEERPUB"][:rx_bps], 2)).to be == "66.67"
  end

  it "poll! publishes a frozen sample so it can cross a fiber boundary" do
    make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "PEERPUB")
    peers = Naaf::Metrics::PeerStats.new
    r = Naaf::Reconciler.new(@db, FakeZone.new, peers: peers,
      helper: FakeHelper.new(dump_for("PEERPUB", handshake: 0)))
    r.poll!

    expect(peers.sample).to be(:frozen?)
    expect(peers.sample["PEERPUB"]).to be(:frozen?)
  end

  it "records when it last polled, so a stall is visible" do
    make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "PEERPUB")
    r = reconciler(dump_for("PEERPUB", handshake: 0))
    expect(r.last_poll_at).to be_nil
    r.poll!
    expect(r.last_poll_at.nil?).to be == false
    expect(r.last_error).to be_nil
  end

  # The mutation path: DB is already written; apply! is what projects it. poll!
  # calls this on peer-set drift, and every form's submit does too.
  it "apply! pushes renderer output through the helper, then reloads the zone" do
    make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "PEERPUB")
    make_site(@db, name: "unifi", address: "192.168.2.2", networks: ["192.168.1.0/24"])
    helper = FakeHelper.new("")
    zone = FakeZone.new
    r = Naaf::Reconciler.new(@db, zone, helper: helper)

    expect(r.last_apply_at).to be_nil
    expect(r.apply!).to be == true

    extra = Naaf::Renderers::Routes.desired(@db)
    expect(helper.applies).to be == 1
    expect(helper.last_apply[:wg_conf]).to be(:include?, "[Interface]")
    expect(helper.last_apply[:wg_conf]).to be(:include?, "PublicKey = PEERPUB")
    expect(helper.last_apply[:nft_ruleset]).to be(:include?, "table inet naaf")
    expect(helper.last_apply[:nft_ruleset]).to be(:include?, "192.168.1.0/24")
    expect(helper.last_apply[:routes]).to be == extra[:routes]
    expect(helper.last_apply[:addresses]).to be == extra[:addresses]
    expect(zone.reloads).to be == 1
    expect(r.last_apply_at.nil?).to be == false
  end

  # Same contract as Naaf::Backup.tick!: the reactor task must survive a helper
  # that has gone away, and the failure has to be visible without reading logs.
  #
  # The CLASS is recorded, never the message. bin/naaf-helper folds the child's
  # stderr into the exception it raises, and the command it runs parses a conf
  # containing `PrivateKey = <server key>` — wireguard-tools echoes an offending
  # value verbatim, so the message can carry key material, and this field is
  # rendered into the admin's browser and pushed down every SSE stream.
  it "tick! swallows a failed poll and records its class, never its message" do
    r = reconciler("")
    def r.poll! = raise("Key is not the correct length or format: `SUPERSECRETKEY='")

    expect(Naaf::Reconciler.tick!(r)).to be_nil
    expect(r.last_error).to be == "RuntimeError"
    expect(r.last_error.include?("SUPERSECRET")).to be == false
  end

  it "poll! re-applies when the kernel peer set has drifted from the DB" do
    make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "INDB")
    helper = FakeHelper.new(dump_for("OTHER", handshake: 0)) # DB has INDB, kernel has OTHER
    r = Naaf::Reconciler.new(@db, FakeZone.new, helper: helper)
    r.poll!
    expect(helper.applies).to be == 1
  end

  it "poll! treats an enabled site pubkey as expected and does not re-apply" do
    make_site(@db, name: "unifi", pubkey: "SITEPUB", networks: ["192.168.1.0/24"])
    helper = FakeHelper.new(dump_for("SITEPUB", handshake: 1_700_000_000, rx: 7, tx: 9))
    r = Naaf::Reconciler.new(@db, FakeZone.new, helper: helper)
    r.poll!
    site = @db[:sites][pubkey: "SITEPUB"]
    expect(site[:rx_bytes]).to be == 7
    expect(site[:tx_bytes]).to be == 9
    expect(site[:last_handshake_at].nil?).to be == false
    expect(site[:observed_endpoint]).to be == "1.2.3.4:51820"
    expect(site[:endpoint]).to be == "203.0.113.9:51820" # configured dest stays
    expect(helper.applies).to be == 0
  end

  it "poll! issues no UPDATE when a site's counters have not moved" do
    make_site(@db, name: "unifi", pubkey: "SITEPUB", networks: ["192.168.1.0/24"])
    helper = FakeHelper.new(dump_for("SITEPUB", handshake: 1_700_000_000, rx: 7, tx: 9))
    r = Naaf::Reconciler.new(@db, FakeZone.new, helper: helper)
    r.poll!
    expect(sql_during { r.poll! }.grep(/UPDATE/)).to be(:empty?)
  end

  it "poll! does not treat an enabled site with no networks as a missing peer" do
    make_site(@db, name: "empty", pubkey: "SITEPUB", networks: [])
    helper = FakeHelper.new("SRVPRIV\tSRVPUB\t51820\toff\n")
    r = Naaf::Reconciler.new(@db, FakeZone.new, helper: helper)
    r.poll!
    expect(helper.applies).to be == 0
  end

  it "poll! re-applies when a site peer is missing from the kernel" do
    make_site(@db, name: "unifi", pubkey: "SITEPUB", networks: ["192.168.1.0/24"])
    helper = FakeHelper.new(dump_for("OTHER", handshake: 0))
    r = Naaf::Reconciler.new(@db, FakeZone.new, helper: helper)
    r.poll!
    expect(helper.applies).to be == 1
  end

  it "poll! publishes site rates alongside client rates" do
    make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "PEERPUB")
    make_site(@db, name: "unifi", pubkey: "SITEPUB", networks: ["192.168.1.0/24"])
    dump = dump_for("PEERPUB", handshake: 1, rx: 10, tx: 10) +
      dump_for("SITEPUB", handshake: 1, rx: 20, tx: 20).lines.drop(1).join
    peers = Naaf::Metrics::PeerStats.new
    r = Naaf::Reconciler.new(@db, FakeZone.new, helper: FakeHelper.new(dump), peers: peers)
    r.poll!
    expect(peers.sample.keys.to_set).to be == %w[PEERPUB SITEPUB].to_set
  end
end
