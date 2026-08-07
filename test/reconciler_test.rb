# frozen_string_literal: true

require_relative "helper"
require "naaf/reconciler"

# Minimal stand-ins so we can drive the reconciler without a live helper/kernel.
class FakeHelper
  attr_reader :applies

  def initialize(dump_text)
    @dump_text = dump_text
    @applies = 0
  end

  def dump = @dump_text
  def apply(**) = (@applies += 1) && {ok: true}
end

class FakeZone
  def reload! = self
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

  it "poll! re-applies when the kernel peer set has drifted from the DB" do
    make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "INDB")
    helper = FakeHelper.new(dump_for("OTHER", handshake: 0)) # DB has INDB, kernel has OTHER
    r = Naaf::Reconciler.new(@db, FakeZone.new, helper: helper)
    r.poll!
    expect(helper.applies).to be == 1
  end
end
