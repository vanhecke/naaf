# frozen_string_literal: true

require_relative "../config"
require_relative "num"
require_relative "series"
require_relative "proc_fs"
require_relative "hub"
require_relative "snapshot"
require_relative "peer_stats"

module Naaf
  module Metrics
    # The tick: sample everything, difference it against the previous sample,
    # append to the rings, freeze, publish.
    #
    # Nothing here calls the root helper. Peer data arrives through PeerStats,
    # published by the one existing reader in Reconciler#poll! — see the comment
    # there for why a second reader of `wg show dump` is not acceptable.
    #
    # Every database query happens here, once per tick, and the result goes into
    # the snapshot. Renderers never touch the database: the sqlite3 driver does
    # not release the GVL, so a query on the render path would freeze the whole
    # reactor — web, DNS and reconciler alike — for the duration.
    class Collector
      # Dir.glob-ing the backup directory and stat-ing the database every couple
      # of seconds is pointless work for numbers that move once an hour.
      SLOW_EVERY = 30

      # A peer's handshake has to be this recent for it to count as online. Two
      # minutes of silence is normal for an idle WireGuard peer with keepalive;
      # three means it is gone.
      ONLINE_WITHIN = 180

      # How long the "enabled peers, none connected" condition has to hold before
      # it is worth showing. Expressed in seconds rather than ticks so it does
      # not change meaning when NAAF_METRICS_INTERVAL does.
      STALLED_AFTER = 30

      def initialize(db:, settings:, dns_stats:, peers:, reconciler: nil,
        procfs: ProcFS.new, hub: Hub.new, history: 180, backup: nil,
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
        now: -> { Time.now })
        @db = db
        @settings = settings
        @dns_stats = dns_stats
        @peers = peers
        @reconciler = reconciler
        @procfs = procfs
        @hub = hub
        @backup = backup
        @clock = clock
        @now = now
        @series = SeriesStore.new(history)
        @snapshot = Snapshot.empty(at: now.call)
        @started_mono = clock.call
        @ticks = 0
        @stalled_for = 0.0
        @peer_generation = 0
      end

      attr_reader :hub, :snapshot, :series

      # The reactor loop body. Same contract as Naaf::Backup.tick!: bare rescue
      # so Async::Stop still propagates, log, return nil, never take the reactor
      # down because a counter could not be read.
      def self.tick!(collector)
        collector.tick!
      rescue => e
        Console.error(collector, "metrics collection failed", exception: e)
        nil
      end

      def tick!
        at = @now.call
        mono = @clock.call
        elapsed = @previous_mono && (mono - @previous_mono)
        @ticks += 1

        raw = sample(at, elapsed)
        @snapshot = build(at, elapsed, mono, raw).freeze
        @previous = raw
        @previous_mono = mono
        @hub.publish(@snapshot)
        @snapshot
      end

      private

      # One pass over /proc and one pass over the database. The DNS counters are
      # rotated here too — exactly once per tick, whatever else happens.
      def sample(_at, elapsed)
        # Re-read rather than holding the boot-time row: the Settings UI edits
        # these, and a stale copy would keep reporting the old DNS upstream,
        # interface names and endpoint until the service restarted.
        @settings = Naaf.settings
        rows = @db[:clients].order(:wg_ip).all
        names = rows.each_with_object({}) { |c, h| h[c[:wg_ip]] = c[:name] }
        {
          cpu: @procfs.stat,
          load: @procfs.loadavg,
          mem: @procfs.meminfo,
          uptime: @procfs.uptime,
          net: @procfs.net_dev,
          udp: @procfs.snmp_udp,
          wan: @procfs.default_interface,
          conntrack: @procfs.conntrack,
          pressure: @procfs.pressure,
          status: @procfs.self_status,
          cpu_time: process_cpu_seconds,
          clients: rows,
          counts: policy_counts,
          dns: @dns_stats.rotate!(elapsed: elapsed, names: names)
        }
      end

      def build(at, elapsed, mono, raw)
        peers, wg = peer_sections(raw)
        interfaces = interface_section(raw, elapsed)
        udp = udp_section(raw, elapsed)
        Snapshot.new(
          at: at,
          interval: elapsed,
          system: system_section(raw, elapsed),
          interfaces: interfaces,
          udp: udp,
          pipeline: pipeline_section(raw, interfaces, udp, wg, elapsed),
          peers: peers,
          wg: wg,
          dns: dns_section(raw),
          app: app_section(raw, elapsed, mono),
          policy: policy_section(raw)
        )
      end

      # --- sections ----------------------------------------------------------

      def system_section(raw, _elapsed)
        cpu = Num.cpu_busy(@previous&.dig(:cpu), raw[:cpu])
        mem = raw[:mem]
        used = mem && mem[:available_kb] && (mem[:total_kb] - mem[:available_kb]) * 1024
        mem_pct = mem && Num.pct(used, mem[:total_kb] * 1024)
        ct = raw[:conntrack]
        ct_pct = ct && Num.pct(ct[:count], ct[:max])

        push(:cpu, cpu)
        push(:mem, mem_pct)
        push(:conntrack, ct_pct)

        {
          cpu_pct: cpu,
          iowait_pct: delta_pct(raw, :iowait),
          steal_pct: delta_pct(raw, :steal),
          cpu_series: tail(:cpu),
          load1: raw.dig(:load, :one), load5: raw.dig(:load, :five),
          load15: raw.dig(:load, :fifteen), ncpu: raw.dig(:cpu, :ncpu),
          procs_running: raw.dig(:cpu, :procs_running),
          procs_blocked: raw.dig(:cpu, :procs_blocked),
          mem_total: mem && mem[:total_kb] * 1024,
          mem_used: used, mem_pct: mem_pct, mem_series: tail(:mem),
          swap_total: mem && mem[:swap_total_kb] * 1024,
          swap_used: mem && (mem[:swap_total_kb] - mem[:swap_free_kb]) * 1024,
          uptime: raw.dig(:uptime, :seconds),
          conntrack_count: ct && ct[:count], conntrack_max: ct && ct[:max],
          conntrack_pct: ct_pct, conntrack_series: tail(:conntrack),
          pressure: freeze_deep(raw[:pressure])
        }.freeze
      end

      # iowait and steal are shares of the same jiffy total as busy, so they use
      # the same denominator. steal is the number that matters on a VPS: it is
      # time the hypervisor gave to somebody else.
      def delta_pct(raw, key)
        prev = @previous&.dig(:cpu)
        cur = raw[:cpu]
        return nil unless prev && cur
        total = cur[:total] - prev[:total]
        Num.pct(cur[key] - prev[key], total)
      end

      def interface_section(raw, elapsed)
        devs = raw[:net] or return [].freeze
        wan = raw[:wan] || @settings[:wan_interface]
        wg = @settings[:wg_interface]
        devs.except("lo").map { |name, cur|
          prev = @previous&.dig(:net, name)
          rx = Num.rate(prev&.dig(:rx_bytes), cur[:rx_bytes], elapsed)
          tx = Num.rate(prev&.dig(:tx_bytes), cur[:tx_bytes], elapsed)
          push(:"if.#{name}.rx", rx)
          push(:"if.#{name}.tx", tx)
          {
            name: name,
            role: role_of(name, wan, wg),
            rx_bps: rx, tx_bps: tx,
            rx_pps: Num.rate(prev&.dig(:rx_packets), cur[:rx_packets], elapsed),
            tx_pps: Num.rate(prev&.dig(:tx_packets), cur[:tx_packets], elapsed),
            rx_errs: cur[:rx_errs], tx_errs: cur[:tx_errs],
            rx_drop: cur[:rx_drop], tx_drop: cur[:tx_drop],
            rx_series: tail(:"if.#{name}.rx"), tx_series: tail(:"if.#{name}.tx")
          }.freeze
        }.sort_by { |i| [i[:role] ? 0 : 1, i[:name]] }.freeze
      end

      # The two interfaces the operator actually cares about get named roles and
      # sort to the top; everything else keeps its place below them.
      def role_of(name, wan, wg)
        return :wan if name == wan
        return :wg if name == wg
        nil
      end

      def udp_section(raw, elapsed)
        cur = raw[:udp] or return EMPTY_UDP
        prev = @previous&.dig(:udp)
        dps = Num.rate(prev&.dig(:in_datagrams), cur[:in_datagrams], elapsed)
        push(:udp, dps)
        {
          in_datagrams: cur[:in_datagrams], in_dps: dps,
          no_ports: cur[:no_ports],
          no_ports_ps: Num.rate(prev&.dig(:no_ports), cur[:no_ports], elapsed),
          in_errors: cur[:in_errors], rcvbuf_errors: cur[:rcvbuf_errors],
          series: tail(:udp)
        }.freeze
      end

      # docs/TROUBLESHOOTING.md step 3, rendered as a row instead of a shell
      # session: packets arriving at the NIC, datagrams delivered to a socket,
      # and packets coming out of the tunnel. tcpdump sees traffic before
      # netfilter, so a firewall silently eating WireGuard shows up as a healthy
      # first number and a flat second one.
      def pipeline_section(raw, interfaces, udp, wg, elapsed)
        wan = interfaces.find { |i| i[:role] == :wan }
        tunnel = interfaces.find { |i| i[:role] == :wg }
        wan_pps = wan&.dig(:rx_pps)

        verdict, message = judge(wan_pps, wg, elapsed)
        {
          wan: wan&.dig(:name) || raw[:wan], wan_pps: wan_pps,
          udp_dps: udp[:in_dps], wg: tunnel&.dig(:name), wg_pps: tunnel&.dig(:rx_pps),
          verdict: verdict, message: message
        }.freeze
      end

      # Deliberately NOT "UDP is not reaching the socket".
      #
      # `Udp: InDatagrams` in /proc/net/snmp is host-wide and IPv4-wide: this
      # box's own upstream DNS replies and timesyncd keep it moving, so the
      # obvious rule ("packets at the NIC but no datagrams delivered") stays
      # green through the exact ufw outage docs/TROUBLESHOOTING.md is written
      # for, while firing red on an idle box that is merely being port-scanned.
      # A detector that is green during the outage is worse than none.
      #
      # So the claim is narrowed to something the data actually supports and
      # that needs no per-port counters: peers are configured and enabled, the
      # box is receiving traffic, and yet not one peer has completed a handshake
      # recently. That is a fact, it is worth surfacing, and where to look next
      # is left to the operator rather than asserted.
      def judge(wan_pps, wg, elapsed)
        return [:unknown, nil] if wan_pps.nil?
        return [:idle, nil] if wg[:enabled].zero?
        if wg[:online].positive?
          @stalled_for = 0.0
          return [:ok, nil]
        end

        @stalled_for = (wan_pps >= 1) ? @stalled_for + (elapsed || 0) : 0.0
        return [:ok, nil] if @stalled_for < STALLED_AFTER

        [:stalled,
          "#{wg[:enabled]} peers are enabled and traffic is arriving, but none has " \
          "completed a handshake in the last #{ONLINE_WITHIN / 60} minutes. If clients " \
          "are trying to connect, work through docs/TROUBLESHOOTING.md §1 — the usual " \
          "cause is a second firewall (`sudo nft list tables` should show only " \
          "inet filter and inet naaf)."]
      end

      # Peer rates come from PeerStats, published by the reconciler. A new
      # generation means a fresh measurement, so the sparklines advance once per
      # reconcile rather than gaining a duplicate point on every metrics tick.
      def peer_sections(raw)
        sample = @peers ? @peers.sample : {}
        fresh = @peers && @peers.generation != @peer_generation
        @peer_generation = @peers&.generation || 0
        now = @now.call

        # nil until something is actually measured. Seeding these at 0 would put
        # "0 B/s" in the hero tile for a tunnel nobody has measured yet — for a
        # whole reconcile interval after boot, and indefinitely while the
        # reconciler is failing — which is exactly the unknown-rendered-as-zero
        # lie the rest of this file goes out of its way to avoid.
        total_rx = nil
        total_tx = nil
        online = 0

        peers = raw[:clients].map { |c|
          m = sample[c[:pubkey]]
          rx = m&.dig(:rx_bps)
          tx = m&.dig(:tx_bps)
          if fresh
            push(:"peer.#{c[:pubkey]}.rx", rx)
            push(:"peer.#{c[:pubkey]}.tx", tx)
          end
          handshake = c[:last_handshake_at]
          up = c[:enabled] && handshake && (now - handshake.to_time) <= ONLINE_WITHIN
          online += 1 if up
          total_rx = total_rx.to_f + rx if rx
          total_tx = total_tx.to_f + tx if tx
          {
            id: c[:id], name: c[:name], hostname: c[:hostname], wg_ip: c[:wg_ip],
            enabled: c[:enabled], online: up,
            last_handshake_at: handshake,
            # The sink carries the kernel's view from the poll that measured
            # the rate; the row is the same value once it has been written.
            # Preferring the sink keeps the two columns consistent with each
            # other even on the tick where a peer first appears.
            endpoint: m&.dig(:endpoint) || c[:endpoint],
            rx_bytes: c[:rx_bytes], tx_bytes: c[:tx_bytes],
            rx_bps: rx, tx_bps: tx,
            rx_series: tail(:"peer.#{c[:pubkey]}.rx"),
            tx_series: tail(:"peer.#{c[:pubkey]}.tx")
          }.freeze
        }.freeze

        # Busiest first, then offline/idle, then by address. The operator's
        # first question is "what is moving traffic", and a table ordered by IP
        # answers it only by accident.
        peers = peers.sort_by { |p|
          [-(p[:rx_bps].to_f + p[:tx_bps].to_f), p[:online] ? 0 : 1, p[:wg_ip].to_s]
        }.freeze

        if fresh
          push(:"wg.rx", total_rx)
          push(:"wg.tx", total_tx)
        end
        retain_series!(raw)

        wg = {
          total: peers.size,
          enabled: peers.count { |p| p[:enabled] },
          online: online,
          listen_port: @settings[:listen_port],
          rx_bps: total_rx, tx_bps: total_tx,
          rx_series: tail(:"wg.rx"), tx_series: tail(:"wg.tx"),
          rx_bytes: peers.sum { |p| p[:rx_bytes].to_i },
          tx_bytes: peers.sum { |p| p[:tx_bytes].to_i },
          measured_at: @peers&.at, interval: @peers&.interval
        }.freeze

        [peers, wg]
      end

      def dns_section(raw)
        dns = raw[:dns]
        push(:dns, dns[:qps])
        dns.merge(series: tail(:dns)).freeze
      end

      def app_section(raw, elapsed, mono)
        cpu = Num.rate(@previous&.dig(:cpu_time), raw[:cpu_time], elapsed)
        slow = slow_facts
        {
          uptime: mono - @started_mono,
          rss: raw.dig(:status, :vm_rss_kb)&.*(1024),
          cpu_pct: cpu && (cpu * 100),
          threads: raw.dig(:status, :threads),
          gc_count: GC.count,
          gc_major: GC.stat(:major_gc_count),
          heap_live: GC.stat(:heap_live_slots),
          yjit: yjit?,
          ruby: RUBY_VERSION,
          drift: Config.drift(@settings).size,
          reconcile_at: @reconciler&.last_poll_at,
          # A FLAG, never the text. bin/naaf-helper folds the child's stderr into
          # the exception it raises and `wg` echoes an offending key verbatim, so
          # carrying the message here would put key material one template away
          # from the browser and every open SSE stream. The message stays in the
          # journal, which is where AGENTS.md expects it to stop.
          reconcile_failing: !@reconciler&.last_error.nil?,
          apply_at: @reconciler&.last_apply_at
        }.merge(slow).freeze
      end

      def policy_section(raw)
        raw[:counts].merge(
          subnet: @settings[:wg_subnet], server_ip: @settings[:server_ip],
          listen_port: @settings[:listen_port], wg_interface: @settings[:wg_interface],
          wan_interface: @settings[:wan_interface], dns_domain: @settings[:dns_domain],
          dns_upstream: @settings[:dns_upstream],
          endpoint: @settings[:endpoint_host] || @settings[:endpoint_v4]
        ).freeze
      end

      def policy_counts
        clients = @db[:clients]
        {
          clients: clients.count,
          enabled: clients.where(enabled: true).count,
          exposed_ports: @db[:exposed_ports].count,
          port_forwards: @db[:port_forwards].count,
          port_forwards_enabled: @db[:port_forwards].where(enabled: true).count,
          dns_records: @db[:dns_records].count,
          extra_routes: @db[:extra_routes].count,
          sites: @db[:sites].count
        }
      end

      # --- helpers -----------------------------------------------------------

      def freeze_deep(hash)
        return nil unless hash
        hash.each_value(&:freeze)
        hash.freeze
      end

      def push(key, value) = @series.for(key) << value

      def tail(key) = (@series[key]&.last || []).freeze

      # A client that no longer exists, or an interface that has gone away, must
      # not keep a full-length ring alive for the life of the process.
      def retain_series!(raw)
        # One unreadable /proc/net/dev would otherwise present as "no interfaces
        # exist" and throw away every interface's history — six minutes of chart
        # lost to a transient EACCES, with no way to rebuild it. Remember the
        # last set we actually saw and keep those alive across a failed read.
        @interface_keys = raw[:net].keys if raw[:net]
        live = [:cpu, :mem, :conntrack, :udp, :dns, :"wg.rx", :"wg.tx"]
        raw[:clients].each do |c|
          live << :"peer.#{c[:pubkey]}.rx" << :"peer.#{c[:pubkey]}.tx"
        end
        (@interface_keys || []).each { |n| live << :"if.#{n}.rx" << :"if.#{n}.tx" }
        @series.retain!(live)
      end

      # CLOCK_PROCESS_CPUTIME_ID rather than /proc/self/stat: no USER_HZ to
      # convert, no comm-parsing hazard, and it returns a real number on the
      # macOS dev box too.
      def process_cpu_seconds
        Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
      rescue NameError, Errno::EINVAL
        nil
      end

      def yjit?
        defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
      end

      # Facts that move on the order of an hour, refreshed on the order of a
      # minute. Cached in between so the tick stays a handful of file reads.
      def slow_facts
        return @slow if @slow && (@ticks % SLOW_EVERY) != 1
        db_path = Config["NAAF_DB"]
        latest = @backup&.latest
        @slow = {
          db_bytes: size_of(db_path),
          wal_bytes: size_of("#{db_path}-wal"),
          backups_enabled: !@backup.nil?,
          backup_name: latest && latest[:name],
          backup_at: latest && latest[:mtime],
          backup_bytes: latest && latest[:bytes]
        }.freeze
      end

      def size_of(path)
        File.size(path)
      rescue SystemCallError
        nil
      end
    end
  end
end
