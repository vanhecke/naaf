# frozen_string_literal: true

require_relative "helper"
require "naaf/metrics"

# A /proc that can be stepped from one captured snapshot to the next, so rate
# maths can be driven deterministically with no real kernel involved.
class MovingProcFS
  SAMPLERS = %i[stat loadavg meminfo uptime net_dev snmp_udp
    default_interface conntrack pressure self_status self_stat].freeze

  def initialize(dir) = move_to(dir)

  def move_to(dir)
    @fs = Naaf::Metrics::ProcFS.new(root: dir)
    self
  end

  SAMPLERS.each do |name|
    define_method(name) { |*args| @fs.public_send(name, *args) }
  end
end

# A /proc whose WAN packet counters keep climbing, so "traffic is arriving" can
# be held true across as many ticks as a test needs. Everything else comes from
# a real fixture, so only the one variable under test moves.
class AdvancingProcFS
  def initialize(dir)
    @fs = Naaf::Metrics::ProcFS.new(root: dir)
    @packets = 0
  end

  def advance!(by = 1900) = (@packets += by)

  def net_dev
    devs = @fs.net_dev
    return devs unless devs&.key?("eth0")
    devs.merge("eth0" => devs["eth0"].merge(
      rx_packets: devs["eth0"][:rx_packets] + @packets,
      rx_bytes: devs["eth0"][:rx_bytes] + (@packets * 137)
    ))
  end

  %i[stat loadavg meminfo uptime snmp_udp default_interface
    conntrack pressure self_status self_stat].each do |name|
    define_method(name) { |*args| @fs.public_send(name, *args) }
  end
end

class StubReconciler
  attr_reader :last_poll_at, :last_apply_at, :last_error

  def initialize(poll_at: Time.now, error: nil)
    @last_poll_at = poll_at
    @last_apply_at = poll_at
    @last_error = error
  end

  # The collector must never reach for the helper. If it ever does, this fails
  # loudly rather than quietly parsing a dump whose first field is the server
  # private key.
  def helper = raise("the collector must not call the helper")
end

describe Naaf::Metrics::Collector do
  def fixtures(name) = File.expand_path("fixtures/proc/#{name}", __dir__)

  before do
    @db = reset_db!(server_ip: "10.8.0.1", wan_interface: "eth0", wg_interface: "wg0",
      wg_subnet: "10.8.0.0/24", listen_port: 51_820,
      server_privkey: "SRVPRIVSRVPRIVSRVPRIVSRVPRIVSRVPRIVSRVPRIV0=")
    @settings = Naaf.settings
    @procfs = MovingProcFS.new(fixtures("t0"))
    @peers = Naaf::Metrics::PeerStats.new
    @dns = Naaf::Metrics::DNSStats.new
    @mono = 1000.0
  end

  def collector(**overrides)
    Naaf::Metrics::Collector.new(
      db: @db, settings: @settings, dns_stats: @dns, peers: @peers,
      reconciler: StubReconciler.new, procfs: @procfs, history: 10,
      clock: -> { @mono }, **overrides
    )
  end

  def advance(seconds) = (@mono += seconds)

  # One interval in which packets kept arriving at the WAN interface.
  def traffic!(c, fs, seconds: 5.0)
    fs.advance!
    advance(seconds)
    c.tick!
  end

  # Step the fake /proc forward and tick, which is what a real interval does.
  def step!(c, to: "t1", seconds: 5.0)
    @procfs.move_to(fixtures(to))
    advance(seconds)
    c.tick!
  end

  describe "the first tick" do
    # A counter needs two samples before it means anything. Reporting 0% here
    # would be indistinguishable from a genuinely idle box, which is exactly the
    # confusion an operator does not need while debugging.
    it "reports rates as unknown rather than zero" do
      s = collector.tick!
      expect(s.system[:cpu_pct]).to be_nil
      expect(s.interfaces.find { |i| i[:name] == "eth0" }[:rx_bps]).to be_nil
      expect(s.udp[:in_dps]).to be_nil
    end

    it "still reports the gauges, which are meaningful immediately" do
      s = collector.tick!
      expect(decimals(s.system[:mem_pct], 1)).to be == "36.3"
      expect(s.system[:conntrack_count]).to be == 137
      expect(decimals(s.system[:load1], 2)).to be == "0.42"
    end
  end

  describe "rates across two samples" do
    it "computes CPU, memory, interface and UDP rates" do
      c = collector
      c.tick!
      s = step!(c)

      expect(decimals(s.system[:cpu_pct], 1)).to be == "25.0"
      eth = s.interfaces.find { |i| i[:name] == "eth0" }
      expect(decimals(eth[:rx_bps], 0)).to be == "52000"
      expect(decimals(eth[:rx_pps], 0)).to be == "380"
      expect(decimals(s.udp[:in_dps], 0)).to be == "380"
    end

    it "labels the WAN and tunnel interfaces and puts them first" do
      c = collector
      c.tick!
      s = step!(c)

      expect(s.interfaces.map { |i| i[:role] }.first(2).sort_by(&:to_s)).to be == [:wan, :wg]
      expect(s.interfaces.map { |i| i[:name] }).not.to be(:include?, "lo")
    end

    it "appends each sample to its series so a sparkline has a shape" do
      c = collector
      c.tick!
      step!(c)
      s = step!(c, to: "t0") # counters go backwards: an interface reset

      expect(s.system[:cpu_series].length).to be == 3
      # The reset interval is unknown, not a negative spike.
      expect(s.interfaces.find { |i| i[:name] == "eth0" }[:rx_bps]).to be_nil
    end
  end

  # docs/TROUBLESHOOTING.md step 3, as a row instead of a shell session.
  describe "the packet pipeline" do
    it "says nothing until it has a reading" do
      expect(collector.tick!.pipeline[:verdict]).to be == :unknown
    end

    it "reports no peers configured rather than a fault" do
      c = collector
      c.tick!
      expect(step!(c).pipeline[:verdict]).to be == :idle
    end

    it "reports the pipeline as healthy while a peer is connected" do
      make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "PEERPUB",
        last_handshake_at: Time.now)
      c = collector
      c.tick!
      expect(step!(c).pipeline[:verdict]).to be == :ok
    end

    # The obvious rule — packets at the NIC but no UDP datagrams delivered —
    # cannot work here: Udp: InDatagrams is host-wide, so this box's own DNS
    # replies keep it moving straight through the ufw outage the panel exists
    # for. The claim is narrowed to something the data supports.
    it "does not claim a fault merely because host-wide UDP is quiet" do
      make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "PEERPUB",
        last_handshake_at: Time.now)
      c = collector
      c.tick!
      s = step!(c, to: "edge/firewall-drop")
      expect(s.pipeline[:verdict]).to be == :ok
      expect(s.pipeline[:message]).to be_nil
    end

    it "flags enabled peers that have all stopped handshaking while traffic arrives" do
      make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "PEERPUB",
        last_handshake_at: Time.now - 7200)
      fs = AdvancingProcFS.new(fixtures("t0"))
      c = collector(procfs: fs)
      c.tick!

      first = traffic!(c, fs) # 5s of the condition is not yet a finding
      expect(first.pipeline[:verdict]).to be == :ok

      # STALLED_AFTER is 30 seconds, so hold the condition well past it.
      7.times { traffic!(c, fs) }
      expect(c.snapshot.pipeline[:verdict]).to be == :stalled
      expect(c.snapshot.pipeline[:message]).to be(:include?, "nft list tables")
    end

    it "clears the flag as soon as a peer connects again" do
      make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "PEERPUB",
        last_handshake_at: Time.now - 7200)
      fs = AdvancingProcFS.new(fixtures("t0"))
      c = collector(procfs: fs)
      c.tick!
      8.times { traffic!(c, fs) }
      expect(c.snapshot.pipeline[:verdict]).to be == :stalled

      @db[:clients].update(last_handshake_at: Time.now)
      expect(traffic!(c, fs).pipeline[:verdict]).to be == :ok
    end
  end

  describe "peers" do
    before do
      make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "PEERPUB",
        last_handshake_at: Time.now, rx_bytes: 1000, tx_bytes: 2000)
    end

    it "reads throughput from the reconciler's sink, never from the helper" do
      @peers.publish({"PEERPUB" => Naaf::Metrics::PeerStats.entry(
        previous_rx: 1000, previous_tx: 2000, rx: 4000, tx: 5000,
        handshake: Time.now.to_i, endpoint: "1.2.3.4:51820", interval: 30.0
      )}, at: Time.now, interval: 30.0)

      s = collector.tick!
      peer = s.peers.first
      expect(decimals(peer[:rx_bps], 0)).to be == "100"
      expect(peer[:endpoint]).to be == "1.2.3.4:51820"
      expect(s.wg[:online]).to be == 1
    end

    it "counts a peer that has not handshaked recently as offline" do
      @db[:clients].update(last_handshake_at: Time.now - 3600)
      s = collector.tick!
      expect(s.peers.first[:online]).to be == false
      expect(s.wg[:online]).to be == 0
    end

    # The reconciler publishes once per reconcile, which is far slower than the
    # metrics tick. Appending on every tick would pad the sparkline with
    # duplicates and make a flat line look like fresh measurement.
    it "advances a peer's series once per reconcile, not once per tick" do
      sample = {"PEERPUB" => Naaf::Metrics::PeerStats.entry(
        previous_rx: 0, previous_tx: 0, rx: 100, tx: 100,
        handshake: Time.now.to_i, endpoint: nil, interval: 30.0
      )}
      c = collector
      @peers.publish(sample, at: Time.now, interval: 30.0)
      c.tick!
      advance(2)
      c.tick!
      advance(2)
      s = c.tick!

      expect(s.peers.first[:rx_series].length).to be == 1

      @peers.publish(sample, at: Time.now, interval: 30.0)
      advance(2)
      expect(c.tick!.peers.first[:rx_series].length).to be == 2
    end

    it "frees the series of a client that has been deleted" do
      @peers.publish({"PEERPUB" => Naaf::Metrics::PeerStats.entry(
        previous_rx: 0, previous_tx: 0, rx: 10, tx: 10,
        handshake: 0, endpoint: nil, interval: 30.0
      )}, at: Time.now, interval: 30.0)
      c = collector
      c.tick!
      expect(c.series.keys).to be(:include?, :"peer.PEERPUB.rx")

      @db[:clients].delete
      advance(2)
      c.tick!
      expect(c.series.keys).not.to be(:include?, :"peer.PEERPUB.rx")
    end
  end

  describe "what the snapshot carries" do
    it "counts the policy tables and names the network" do
      id = make_client(@db, name: "laptop", wg_ip: "10.8.0.2")
      @db[:exposed_ports].insert(client_id: id, proto: "tcp", port: 22, port_end: 22)
      @db[:port_forwards].insert(client_id: id, proto: "tcp", public_port: 80, target_port: 8080)

      p = collector.tick!.policy
      expect(p[:clients]).to be == 1
      expect(p[:exposed_ports]).to be == 1
      expect(p[:port_forwards]).to be == 1
      expect(p[:subnet]).to be == "10.8.0.0/24"
    end

    it "rotates the DNS counters exactly once per tick" do
      @dns.record(:local_a, name: "nas.vpn", remote: "10.8.0.2")
      c = collector
      c.tick!
      advance(2)
      s = c.tick!

      expect(s.dns[:total]).to be == 1 # accumulated, not double counted
      expect(decimals(s.dns[:qps], 1)).to be == "0.0"
    end

    it "resolves DNS client attribution against the clients table" do
      make_client(@db, name: "laptop", wg_ip: "10.8.0.2")
      @dns.record(:local_a, name: "nas.vpn", remote: "10.8.0.2")
      s = collector.tick!
      expect(s.dns[:top_clients].first.first).to be == "laptop"
    end

    it "reports the app's own health" do
      a = collector.tick!.app
      expect(a[:ruby]).to be == RUBY_VERSION
      expect(a[:reconcile_at].nil?).to be == false
      expect(a[:db_bytes].nil?).to be == false
    end

    # It crosses a fiber boundary to any number of SSE readers, so nothing in it
    # may still be mutable — that is the rule that keeps a dashboard render from
    # breaking the DNS server.
    it "publishes a deeply frozen snapshot" do
      s = collector.tick!
      expect(s).to be(:frozen?)
      expect(s.system).to be(:frozen?)
      expect(s.interfaces).to be(:frozen?)
      expect(s.policy).to be(:frozen?)
      expect(s.dns).to be(:frozen?)
    end

    it "publishes it to the hub with a fresh sequence" do
      c = collector
      c.tick!
      expect(c.hub.sequence).to be == 1
      expect(c.hub.snapshot).to be == c.snapshot
    end
  end

  describe "safety" do
    # AGENTS.md: the kernel is a projection of the database, never a source for
    # it. The collector reads for display and writes nothing.
    it "never writes the clients table" do
      make_client(@db, name: "laptop", wg_ip: "10.8.0.2")
      before_row = @db[:clients].first
      collector.tick!
      expect(@db[:clients].first).to be == before_row
    end

    # `wg show dump` line 1 field 0 is the server private key and every peer
    # line's field 1 is that peer's PSK. Nothing that shape may ever reach a
    # structure that gets rendered into a browser.
    it "carries no key material at all" do
      make_client(@db, name: "laptop", wg_ip: "10.8.0.2",
        pubkey: "PUBPUBPUBPUBPUBPUBPUBPUBPUBPUBPUBPUBPUBPUBP=",
        psk: "PSKPSKPSKPSKPSKPSKPSKPSKPSKPSKPSKPSKPSKPSKP=")
      text = collector.tick!.inspect

      expect(text.include?("SRVPRIV")).to be == false
      expect(text.include?("PSKPSK")).to be == false
      expect(text).not.to be(:match?, %r{[A-Za-z0-9+/]{43}=})
    end

    it "renders on a machine with no /proc at all" do
      c = collector(procfs: Naaf::Metrics::ProcFS.new(root: fixtures("edge/absent")))
      s = c.tick!

      expect(s.system[:cpu_pct]).to be_nil
      expect(s.interfaces).to be(:empty?)
      expect(s.pipeline[:verdict]).to be == :unknown
      expect(s.policy[:subnet]).to be == "10.8.0.0/24" # the DB half still works
    end

    # Same contract as Naaf::Backup.tick!: a failed collection logs and returns,
    # it does not take the reactor down with it.
    it "swallows a failed collection rather than killing the reactor task" do
      boom = Object.new
      def boom.tick! = raise("nope")
      expect(Naaf::Metrics::Collector.tick!(boom)).to be_nil
    end
  end
end
