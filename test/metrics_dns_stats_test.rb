# frozen_string_literal: true

require_relative "helper"
require "naaf/metrics/dns_stats"

describe Naaf::Metrics::DNSStats do
  def stats(names: true) = Naaf::Metrics::DNSStats.new(names: names)

  def record_many(s, n, outcome: :upstream_ok, name: "example.com", remote: "10.8.0.2")
    n.times { s.record(outcome, name: name, remote: remote) }
    s
  end

  describe "counting" do
    it "totals every outcome and keeps them apart" do
      s = stats
      s.record(:local_a, name: "nas.vpn", remote: "10.8.0.2")
      s.record(:local_ptr, name: "2.0.8.10.in-addr.arpa", remote: "10.8.0.2")
      s.record(:upstream_ok, name: "example.com", remote: "10.8.0.3", ms: 12)
      out = s.rotate!(elapsed: 1.0)

      expect(out[:total]).to be == 3
      expect(out[:outcomes][:local_a]).to be == 1
      expect(out[:outcomes][:local_ptr]).to be == 1
      expect(out[:outcomes][:upstream_ok]).to be == 1
    end

    it "splits locally answered queries from ones that went upstream" do
      s = stats
      3.times { s.record(:local_a, name: "nas.vpn", remote: "10.8.0.2") }
      s.record(:upstream_ok, name: "example.com", remote: "10.8.0.2", ms: 5)
      out = s.rotate!(elapsed: 1.0)

      expect(out[:local]).to be == 3
      expect(out[:upstream]).to be == 1
      expect(decimals(out[:local_pct], 0)).to be == "75"
    end

    it "reports a query rate over the elapsed interval, not a raw count" do
      out = record_many(stats, 20).rotate!(elapsed: 4.0)
      expect(decimals(out[:qps], 1)).to be == "5.0"
    end

    it "accumulates across ticks while the rate covers only the last one" do
      s = record_many(stats, 10)
      s.rotate!(elapsed: 1.0)
      out = record_many(s, 2).rotate!(elapsed: 1.0)

      expect(out[:total]).to be == 12
      expect(decimals(out[:qps], 1)).to be == "2.0"
    end
  end

  describe "latency" do
    it "buckets a measurement at its upper bound" do
      s = stats
      s.record(:upstream_ok, name: "a.com", remote: "10.8.0.2", ms: 7)
      out = s.rotate!(elapsed: 1.0)
      expect(out[:p50_ms]).to be == 10 # 7ms lands in the "<= 10" bucket
    end

    it "reports percentiles that do not go backwards" do
      s = stats
      [1, 3, 8, 40, 900].each { |ms| s.record(:upstream_ok, name: "a.com", remote: "x", ms: ms) }
      out = s.rotate!(elapsed: 1.0)
      expect(out[:p50_ms] <= out[:p95_ms]).to be == true
      expect(decimals(out[:slowest_ms], 0)).to be == "900"
    end

    it "reports nothing rather than zero when nothing has been timed" do
      out = stats.rotate!(elapsed: 1.0)
      expect(out[:p50_ms]).to be_nil
      expect(out[:p95_ms]).to be_nil
      expect(out[:mean_ms]).to be_nil
      expect(out[:slowest_ms]).to be_nil
    end
  end

  describe "bounded memory" do
    # A client asking for a fresh random name every query must not be able to
    # grow this process without limit. At the cap the map stops taking new keys;
    # existing ones keep counting.
    it "stops accepting new names at the cap and says the table is approximate" do
      s = stats
      5000.times { |i| s.record(:upstream_ok, name: "host#{i}.example.com", remote: "10.8.0.2") }
      out = s.rotate!(elapsed: 1.0)

      expect(out[:approximate]).to be == true
      expect(out[:top_domains].length).to be == 10
      expect(out[:total]).to be == 5000
    end

    it "keeps the heaviest hitters when it trims the rollup" do
      s = stats
      300.times { |i| s.record(:upstream_ok, name: "filler#{i}.com", remote: "10.8.0.2") }
      50.times { s.record(:upstream_ok, name: "busy.example.com", remote: "10.8.0.2") }
      out = s.rotate!(elapsed: 1.0)

      expect(out[:top_domains].first).to be == ["busy.example.com", 50]
    end

    it "caps the per-client map the same way" do
      s = stats
      1000.times { |i| s.record(:upstream_ok, name: "a.com", remote: "10.9.#{i / 256}.#{i % 256}") }
      out = s.rotate!(elapsed: 1.0)
      expect(out[:top_clients].length).to be == 10
    end
  end

  describe "what reaches the page" do
    # Roda's render plugin is not in escaping mode here, and the existing views
    # emit values raw. A query name arrives straight off the network, so it is
    # validated at this boundary rather than trusted and escaped later.
    it "refuses a name that is not a DNS name" do
      s = stats
      s.record(:upstream_ok, name: "<script>alert(1)</script>.evil.com", remote: "10.8.0.2")
      out = s.rotate!(elapsed: 1.0)

      expect(out[:top_domains].first.first).to be == "(invalid)"
      expect(out.inspect.include?("<script>")).to be == false
    end

    it "normalizes case and the trailing root dot so one name is one row" do
      s = stats
      s.record(:upstream_ok, name: "Example.COM.", remote: "10.8.0.2")
      s.record(:upstream_ok, name: "example.com", remote: "10.8.0.2")
      out = s.rotate!(elapsed: 1.0)

      expect(out[:top_domains]).to be == [["example.com", 2]]
    end

    it "resolves a querying IP to its client name at render time" do
      s = stats
      s.record(:upstream_ok, name: "a.com", remote: "10.8.0.2")
      out = s.rotate!(elapsed: 1.0, names: {"10.8.0.2" => "laptop"})
      expect(out[:top_clients].first.first).to be == "laptop"
    end

    it "leaves an unknown IP as an IP" do
      s = stats
      s.record(:upstream_ok, name: "a.com", remote: "10.8.0.9")
      out = s.rotate!(elapsed: 1.0, names: {"10.8.0.2" => "laptop"})
      expect(out[:top_clients].first.first).to be == "10.8.0.9"
    end

    # A per-client query count is a profile of a person's activity just as much
    # as a domain list is, so the switch has to stop COLLECTING both — not merely
    # stop rendering them while the process quietly keeps the profile in memory.
    it "collects neither names nor per-client counts when name detail is off" do
      s = stats(names: false)
      s.record(:upstream_ok, name: "secret.example.com", remote: "10.8.0.2")
      out = s.rotate!(elapsed: 1.0, names: {"10.8.0.2" => "alice-laptop"})

      expect(out[:top_domains]).to be(:empty?)
      expect(out[:top_clients]).to be(:empty?)
      expect(out[:names]).to be == false
      expect(out[:total]).to be == 1 # the aggregate rate still works
      expect(out.inspect.include?("secret")).to be == false
      expect(out.inspect.include?("alice-laptop")).to be == false
    end
  end

  # async-dns runs a fiber per datagram and the dashboard renders on another, so
  # a live counter hash is genuinely shared. Rotating by whole-object swap is
  # what keeps a render from iterating a hash that a DNS fiber is still adding
  # keys to — which would raise inside the DNS fiber and turn into a ServFail.
  describe "rotation by whole-object swap" do
    it "hands out a sample that later queries cannot mutate" do
      s = stats
      s.record(:upstream_ok, name: "a.com", remote: "10.8.0.2")
      out = s.rotate!(elapsed: 1.0)

      expect(out).to be(:frozen?)
      expect(out[:outcomes]).to be(:frozen?)
      expect(out[:top_domains]).to be(:frozen?)
      expect(out[:top_clients]).to be(:frozen?)
      expect(out[:top_domains].first).to be(:frozen?)
    end

    it "keeps iterating a sample safe while new queries are still arriving" do
      s = stats
      s.record(:upstream_ok, name: "a.com", remote: "10.8.0.2")
      out = s.rotate!(elapsed: 1.0)

      # Exactly the interleaving that used to raise: walk the published sample
      # while the DNS path records new names.
      out[:top_domains].each_with_index do |_, i|
        s.record(:upstream_ok, name: "new#{i}.com", remote: "10.8.0.3")
      end
      expect(s.rotate!(elapsed: 1.0)[:total]).to be == 2
    end

    it "documents the shape it replaced: mutating a hash under iteration raises" do
      live = {"a.com" => 1}
      expect {
        live.each { |_, _| live["b.com"] = 1 }
      }.to raise_exception(RuntimeError)
    end
  end
end
