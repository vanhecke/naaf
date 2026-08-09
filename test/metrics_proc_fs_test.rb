# frozen_string_literal: true

require_relative "helper"
require "naaf/metrics/proc_fs"
require "naaf/metrics/num"

# Every parser is driven from captured /proc text under test/fixtures/proc, so
# these run identically on the maintainer's macOS box (no /proc at all) and on
# ubuntu-latest (a /proc with no wg0 and possibly no netfilter sysctls).
#
# t0 and t1 are one snapshot pair taken exactly 5.00 s apart. The derived
# numbers below are pinned deliberately: a field-order mistake in these files
# produces a dashboard that looks entirely plausible and is wrong.
describe Naaf::Metrics::ProcFS do
  # t0 and t1 are exactly this far apart.
  def dt = 5.0

  def fixtures(name) = File.expand_path("fixtures/proc/#{name}", __dir__)
  def procfs(name) = Naaf::Metrics::ProcFS.new(root: fixtures(name))
  def t0 = procfs("t0")
  def t1 = procfs("t1")
  def num = Naaf::Metrics::Num

  describe "#stat" do
    it "sums only user..steal, so guest time is not counted twice" do
      s = t0.stat
      # user 1000 + nice 0 + system 500 + idle 8000 + iowait 100 + steal 400
      expect(s[:total]).to be == 10_000
      expect(s[:idle]).to be == 8100 # idle + iowait: iowait is an idle state
      expect(s[:busy]).to be == 1900
    end

    it "counts the per-core lines without mistaking them for the aggregate" do
      expect(t0.stat[:ncpu]).to be == 2
    end

    it "yields the busy percentage the interval actually spent working" do
      expect(decimals(num.cpu_busy(t0.stat, t1.stat), 1)).to be == "25.0"
    end

    it "reads the process queue counters" do
      expect(t0.stat[:procs_running]).to be == 2
      expect(t0.stat[:procs_blocked]).to be == 0
    end
  end

  describe "#meminfo" do
    # MemFree alone would call this box 93.8% used while it is in fact fine —
    # the difference is reclaimable page cache, which MemAvailable accounts for.
    it "computes used memory from MemAvailable, not MemFree" do
      m = t0.meminfo
      used = m[:total_kb] - m[:available_kb]
      expect(decimals(num.pct(used, m[:total_kb]), 1)).to be == "36.3"

      wrong = m[:total_kb] - m[:free_kb]
      expect(decimals(num.pct(wrong, m[:total_kb]), 1)).to be == "93.8"
    end

    it "reads swap as configured but unused" do
      m = t0.meminfo
      expect(m[:swap_total_kb]).to be == 2_097_148
      expect(m[:swap_total_kb] - m[:swap_free_kb]).to be == 0
    end

    it "reports a box with no swap as zero rather than dividing by it" do
      m = procfs("edge/no-swap").meminfo
      expect(m[:swap_total_kb]).to be == 0
      expect(num.pct(0, m[:swap_total_kb])).to be_nil
    end

    it "survives a kernel that does not publish MemAvailable" do
      m = procfs("edge/no-memavailable").meminfo
      expect(m[:total_kb]).to be == 2_000_000
      expect(m[:available_kb]).to be_nil
    end
  end

  describe "#net_dev" do
    it "reads the receive and transmit columns from the right offsets" do
      eth = t0.net_dev["eth0"]
      expect(eth[:rx_bytes]).to be == 1_000_000
      expect(eth[:rx_packets]).to be == 5000
      expect(eth[:rx_drop]).to be == 7
      expect(eth[:tx_bytes]).to be == 2_000_000
      expect(eth[:tx_packets]).to be == 9000
    end

    it "handles an interface name padded with leading spaces" do
      expect(t0.net_dev.keys).to be(:include?, "lo")
    end

    # An older kernel prints "eth0:12345678901" with no space after the colon.
    # Splitting the whole line on whitespace shifts every field by one and
    # reports the packet count as the byte count.
    it "splits on the first colon, not on whitespace" do
      eth = procfs("edge/old-netdev").net_dev["eth0"]
      expect(eth[:rx_bytes]).to be == 12_345_678_901
      expect(eth[:rx_packets]).to be == 4321
    end

    it "computes throughput and packet rate across the pair" do
      a = t0.net_dev["eth0"]
      b = t1.net_dev["eth0"]
      expect(decimals(num.rate(a[:rx_bytes], b[:rx_bytes], dt), 0)).to be == "52000"
      expect(decimals(num.rate(a[:rx_packets], b[:rx_packets], dt), 0)).to be == "380"
    end

    # naaf.service is ordered After= wg-quick@ but does not Require= it, so the
    # app can legitimately be up before wg0 exists. Absent is not zero.
    it "omits an interface that does not exist yet rather than inventing zeros" do
      expect(procfs("edge/no-wg").net_dev["wg0"]).to be_nil
      expect(t0.net_dev["wg0"].nil?).to be == false
    end
  end

  describe "#snmp_udp" do
    # docs/TROUBLESHOOTING.md leans on InDatagrams staying flat while packets
    # keep arriving as the signature of a firewall silently eating WireGuard.
    it "zips the header with the values instead of indexing by position" do
      u = t0.snmp_udp
      expect(u[:in_datagrams]).to be == 100_000
      expect(u[:no_ports]).to be == 12
      expect(u[:out_datagrams]).to be == 90_000
    end

    # "Udp" is a prefix of "UdpLite", so matching without the colon would pick
    # up four lines and zip the wrong pair.
    it "does not confuse the UdpLite block for the Udp block" do
      expect(t1.snmp_udp[:in_datagrams]).to be == 101_900
    end

    it "yields the delivered-datagram rate" do
      a = t0.snmp_udp
      b = t1.snmp_udp
      expect(decimals(num.rate(a[:in_datagrams], b[:in_datagrams], dt), 0)).to be == "380"
    end

    # The whole point of the pipeline panel: WAN packets arriving while
    # InDatagrams is frozen and wg0 has not moved means something between the
    # NIC and the socket is dropping them.
    it "shows the firewall-drop signature as arriving packets with a flat socket counter" do
      drop = procfs("edge/firewall-drop")
      wan = num.rate(t0.net_dev["eth0"][:rx_packets], drop.net_dev["eth0"][:rx_packets], dt)
      udp = num.rate(t0.snmp_udp[:in_datagrams], drop.snmp_udp[:in_datagrams], dt)
      expect(wan > 0).to be == true
      expect(decimals(udp, 0)).to be == "0"
    end
  end

  describe "#default_interface" do
    # AGENTS.md: the WAN interface is discovered, never hardcoded to eth0/ens3.
    it "finds the gateway route and ignores the on-link ones" do
      expect(t0.default_interface).to be == "eth0"
    end
  end

  describe "#self_stat and #self_status" do
    it "reads the process CPU jiffies" do
      expect(t0.self_stat[:utime]).to be == 300
      expect(t0.self_stat[:stime]).to be == 100
      expect(t0.self_stat[:num_threads]).to be == 5
    end

    # comm can contain spaces AND parentheses. Splitting the line on whitespace
    # shifts every later field; the fix is to seek to the LAST ")".
    it "parses a process whose name contains spaces and parentheses" do
      s = procfs("edge/weird-comm").self_stat
      expect(s[:utime]).to be == 300
      expect(s[:stime]).to be == 100
    end

    it "reads RSS rather than virtual size" do
      expect(t0.self_status[:vm_rss_kb]).to be == 78_000
      expect(t0.self_status[:threads]).to be == 5
    end
  end

  describe "#conntrack" do
    it "reads the table level and its ceiling" do
      c = t1.conntrack
      expect(c[:count]).to be == 192
      expect(c[:max]).to be == 262_144
    end

    it "reports nothing when the module is not loaded" do
      expect(procfs("edge/absent").conntrack).to be_nil
    end
  end

  describe "#pressure" do
    it "reads the already-averaged PSI percentages" do
      p = t0.pressure("cpu")
      expect(decimals(p[:some][:avg10], 2)).to be == "0.12"
    end
  end

  # The maintainer develops on macOS, where none of these files exist. A sampler
  # that raised would make bin/ci red on the machine it is run from most.
  describe "an absent /proc" do
    it "returns nothing from every sampler instead of raising" do
      p = procfs("edge/absent")
      expect(p.stat).to be_nil
      expect(p.loadavg).to be_nil
      expect(p.meminfo).to be_nil
      expect(p.uptime).to be_nil
      expect(p.net_dev).to be_nil
      expect(p.snmp_udp).to be_nil
      expect(p.default_interface).to be_nil
      expect(p.self_status).to be_nil
      expect(p.self_stat).to be_nil
      expect(p.pressure).to be_nil
      expect(p.conntrack).to be_nil
    end

    it "treats a directory that does not exist at all the same way" do
      p = Naaf::Metrics::ProcFS.new(root: "/nonexistent-proc-#{Process.pid}")
      expect(p.stat).to be_nil
      expect(p.net_dev).to be_nil
    end
  end

  # A seq_file caught mid-unload, or a kernel that publishes fewer fields than
  # we expect. Parse to nothing; never raise, never half-report.
  describe "truncated and empty bodies" do
    it "parses a short cpu line to nothing rather than a wrong total" do
      expect(procfs("edge/truncated").stat).to be_nil
    end

    it "parses truncated and empty files to nothing" do
      t = procfs("edge/truncated")
      expect(t.meminfo).to be_nil
      expect(t.net_dev).to be == {}
      expect(t.snmp_udp).to be_nil
      expect(t.self_stat).to be_nil

      e = procfs("edge/empty")
      expect(e.stat).to be_nil
      expect(e.meminfo).to be_nil
      expect(e.net_dev).to be == {}
    end
  end
end
