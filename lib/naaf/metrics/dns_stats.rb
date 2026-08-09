# frozen_string_literal: true

require_relative "num"

module Naaf
  module Metrics
    # DNS telemetry, held in memory and nowhere else.
    #
    # A resolver log is the most sensitive thing this box could keep — it is a
    # record of what everyone on the tunnel looked at — so it is never written
    # to the database, never written to a file, never logged, and dies with the
    # process. NAAF_METRICS_DNS_NAMES=0 turns the name-level detail off entirely
    # and leaves only the aggregate rates.
    #
    # FIBER SAFETY IS THE WHOLE DESIGN HERE. async-dns spawns a task per
    # datagram, so many #process calls are in flight at once, and the dashboard
    # renders on yet another fiber. If a render iterated one of these hashes and
    # yielded on a socket write, a DNS fiber adding a key would raise
    # "can't add a new key into hash during iteration" *inside the DNS fiber*,
    # where DNSServer#process turns it into a ServFail. One slow dashboard tab
    # would break name resolution for the whole tunnel.
    #
    # The fix is that nothing mutable ever leaves this object. #record mutates
    # the live hash and is called only from the DNS path; #rotate! swaps the
    # whole hash out for a fresh one — two assignments with no yield between
    # them, so it cannot interleave — and everything after that point works on
    # an object no other fiber can still reach.
    class DNSStats
      OUTCOMES = %i[local_a local_ptr aaaa_suppressed upstream_ok upstream_fail servfail].freeze
      LOCAL = %i[local_a local_ptr aaaa_suppressed].freeze

      # Upper bounds in milliseconds; anything slower lands in the overflow slot.
      # Fixed buckets rather than a growing array of samples: the array would be
      # unbounded memory on the hot path, and percentiles off buckets are plenty
      # to answer "is the upstream slow".
      BUCKETS_MS = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000].freeze

      # Hard ceilings, so a query flood costs bounded memory. At the cap the maps
      # stop accepting NEW keys — existing ones keep counting — and the rollup is
      # trimmed back to KEEP on the next tick. A name evicted that way can
      # re-enter at 1, which is why the panel calls this an approximate table.
      DOMAIN_CAP = 2000
      DOMAIN_KEEP = 200
      CLIENT_CAP = 512
      TOP = 10

      # A query name arrives from the network and ends up rendered into the
      # admin's browser. Validate it at the boundary the way App#param_* does,
      # rather than trusting it here and hoping the template escapes it.
      NAME = /\A[a-z0-9](?:[a-z0-9._-]{0,251}[a-z0-9.])?\z/
      INVALID = "(invalid)"

      def initialize(names: true)
        @names = names
        @live = blank
        @totals = blank
      end

      def names? = @names

      # --- the DNS hot path --------------------------------------------------
      # Straight-line arithmetic with no IO and no yield point. Do not add
      # either: this runs per question, and anything that parks here parks the
      # resolver. Cost is a few hash increments and, on the upstream path only,
      # two monotonic clock reads taken by the caller.
      def record(outcome, name: nil, remote: nil, ms: nil)
        live = @live
        live[:total] += 1
        live[:outcomes][outcome] += 1
        observe(live, ms) if ms
        # Both are gated. A per-client query count is still a profile of a
        # person's activity, so NAAF_METRICS_DNS_NAMES=0 has to stop collecting
        # it rather than merely stop rendering it.
        bump(live, :domains, normalize(name), DOMAIN_CAP) if @names && name
        bump(live, :clients, remote, CLIENT_CAP) if @names && remote
        nil
      end

      # --- collector only ----------------------------------------------------
      # Swap the live counters for a fresh set and fold the delta into the
      # rollup. Everything below this line runs on the collector fiber and
      # touches objects the DNS path can no longer reach.
      def rotate!(elapsed: nil, names: {})
        delta = @live
        @live = blank
        merge!(delta)
        trim!
        sample(delta, elapsed, names)
      end

      private

      def blank
        {
          total: 0,
          outcomes: Hash.new(0),
          latency: Array.new(BUCKETS_MS.size + 1, 0),
          latency_ms: 0.0,
          slowest_ms: 0.0,
          domains: Hash.new(0),
          clients: Hash.new(0),
          dropped: Hash.new(0)
        }
      end

      def observe(live, ms)
        live[:latency_ms] += ms
        live[:slowest_ms] = ms if ms > live[:slowest_ms]
        live[:latency][BUCKETS_MS.index { |b| ms <= b } || BUCKETS_MS.size] += 1
      end

      # O(1), and it refuses a new key at the cap rather than growing.
      def bump(live, kind, key, cap)
        return if key.nil?
        map = live[kind]
        if map.key?(key)
          map[key] += 1
        elsif map.size < cap
          map[key] = 1
        else
          live[:dropped][kind] += 1
        end
      end

      def normalize(name)
        s = name.to_s.downcase.chomp(".")
        return nil if s.empty?
        NAME.match?(s) ? s : INVALID
      end

      def merge!(delta)
        @totals[:total] += delta[:total]
        delta[:outcomes].each { |k, v| @totals[:outcomes][k] += v }
        delta[:latency].each_with_index { |v, i| @totals[:latency][i] += v }
        @totals[:latency_ms] += delta[:latency_ms]
        @totals[:slowest_ms] = delta[:slowest_ms] if delta[:slowest_ms] > @totals[:slowest_ms]
        delta[:domains].each { |k, v| bump_total(:domains, k, v, DOMAIN_CAP) }
        delta[:clients].each { |k, v| bump_total(:clients, k, v, CLIENT_CAP) }
        delta[:dropped].each { |k, v| @totals[:dropped][k] += v }
      end

      def bump_total(kind, key, by, cap)
        map = @totals[kind]
        if map.key?(key)
          map[key] += by
        elsif map.size < cap
          map[key] = by
        else
          @totals[:dropped][kind] += by
        end
      end

      # One sort of at most DOMAIN_CAP entries per tick, on the collector fiber,
      # never on the query path.
      def trim!
        return if @totals[:domains].size <= DOMAIN_KEEP
        @totals[:domains] = @totals[:domains].sort_by { |_, v| -v }.first(DOMAIN_KEEP).to_h
      end

      # A deeply frozen value object. `names` maps a VPN IP to a client name and
      # is supplied by the collector from its one per-tick query, so the DNS path
      # never does a lookup of its own.
      def sample(delta, elapsed, names)
        outcomes = @totals[:outcomes]
        local = LOCAL.sum { |k| outcomes[k] }
        upstream = outcomes[:upstream_ok] + outcomes[:upstream_fail]
        answered = @totals[:latency].sum
        {
          qps: Num.rate(0, delta[:total], elapsed),
          total: @totals[:total],
          outcomes: outcomes.dup.freeze,
          local: local,
          upstream: upstream,
          local_pct: Num.pct(local, local + upstream),
          p50_ms: percentile(50, answered),
          p95_ms: percentile(95, answered),
          slowest_ms: (@totals[:slowest_ms].positive? ? @totals[:slowest_ms] : nil),
          mean_ms: (answered.positive? ? @totals[:latency_ms] / answered : nil),
          top_domains: top(@totals[:domains]),
          # .map would hand back a fresh unfrozen array, which is exactly the
          # kind of mutable thing that must not cross the publish boundary.
          top_clients: top(@totals[:clients]).map { |ip, n| [names[ip] || ip, n].freeze }.freeze,
          servfails: outcomes[:servfail] + outcomes[:upstream_fail],
          names: @names,
          approximate: @totals[:dropped].values.sum.positive?
        }.freeze
      end

      def top(map)
        map.sort_by { |k, v| [-v, k.to_s] }.first(TOP).map { |k, v| [k, v].freeze }.freeze
      end

      # The bucket's upper bound, which is an over-estimate by construction.
      # Reporting the bound is honest; interpolating inside a bucket would invent
      # precision the histogram does not have.
      def percentile(p, answered)
        return nil if answered.zero?
        want = answered * p / 100.0
        seen = 0
        @totals[:latency].each_with_index do |count, i|
          seen += count
          return BUCKETS_MS[i] || BUCKETS_MS.last if seen >= want
        end
        nil
      end
    end
  end
end
