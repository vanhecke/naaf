# frozen_string_literal: true

module Naaf
  module Metrics
    # One immutable value object per tick. Every renderer — ERB fragment and SVG
    # alike — is a pure function of one of these, which is what lets the same
    # template serve the SSE stream and the plain GET fallback, and what lets
    # every panel be tested without a reactor.
    #
    # It is frozen because it crosses a fiber boundary: the collector builds it
    # and any number of SSE fibers read it. Nothing mutable may cross that line
    # (see DNSStats for what happens when something does).
    Snapshot = Data.define(:at, :interval, :system, :interfaces, :udp,
      :pipeline, :peers, :wg, :dns, :app, :policy) do
      # The state the page is in before the collector has ever ticked, and the
      # state every panel falls back to on a machine with no /proc.
      #
      # Every key a template touches exists here with a nil or empty value, so
      # no fragment ever needs a nil guard around a container — the formatters
      # turn a nil into an em dash and the job is done.
      def self.empty(at: Time.now)
        new(
          at: at,
          interval: nil,
          system: EMPTY_SYSTEM,
          interfaces: [].freeze,
          udp: EMPTY_UDP,
          pipeline: EMPTY_PIPELINE,
          peers: [].freeze,
          wg: EMPTY_WG,
          dns: EMPTY_DNS,
          app: EMPTY_APP,
          policy: EMPTY_POLICY
        ).freeze
      end

      def age(now = Time.now) = now - at
    end

    EMPTY_SYSTEM = {
      cpu_pct: nil, iowait_pct: nil, steal_pct: nil, cpu_series: [].freeze,
      load1: nil, load5: nil, load15: nil, ncpu: nil,
      procs_running: nil, procs_blocked: nil,
      mem_total: nil, mem_used: nil, mem_pct: nil, mem_series: [].freeze,
      swap_total: nil, swap_used: nil,
      uptime: nil,
      conntrack_count: nil, conntrack_max: nil, conntrack_pct: nil,
      conntrack_series: [].freeze,
      pressure: nil
    }.freeze

    EMPTY_UDP = {
      in_datagrams: nil, in_dps: nil, no_ports: nil, no_ports_ps: nil,
      in_errors: nil, rcvbuf_errors: nil, series: [].freeze
    }.freeze

    EMPTY_PIPELINE = {
      wan: nil, wan_pps: nil, udp_dps: nil, wg: nil, wg_pps: nil,
      verdict: :unknown, message: nil
    }.freeze

    EMPTY_WG = {
      total: 0, enabled: 0, online: 0, listen_port: nil,
      rx_bps: nil, tx_bps: nil, rx_series: [].freeze, tx_series: [].freeze,
      rx_bytes: 0, tx_bytes: 0, measured_at: nil, interval: nil
    }.freeze

    EMPTY_DNS = {
      qps: nil, total: 0, outcomes: {}.freeze, local: 0, upstream: 0,
      local_pct: nil, p50_ms: nil, p95_ms: nil, slowest_ms: nil, mean_ms: nil,
      top_domains: [].freeze, top_clients: [].freeze, names: true,
      approximate: false, series: [].freeze
    }.freeze

    EMPTY_APP = {
      uptime: nil, rss: nil, cpu_pct: nil, threads: nil,
      gc_count: nil, gc_major: nil, heap_live: nil, yjit: nil,
      db_bytes: nil, wal_bytes: nil,
      backup_name: nil, backup_at: nil, backup_bytes: nil, backups_enabled: false,
      drift: 0, reconcile_at: nil, reconcile_failing: false, apply_at: nil,
      ruby: RUBY_VERSION
    }.freeze

    EMPTY_POLICY = {
      clients: 0, enabled: 0, exposed_ports: 0, port_forwards: 0,
      port_forwards_enabled: 0, dns_records: 0, extra_routes: 0, sites: 0,
      subnet: nil, server_ip: nil, listen_port: nil, wg_interface: nil,
      wan_interface: nil, dns_domain: nil, dns_upstream: nil, endpoint: nil
    }.freeze
  end
end
