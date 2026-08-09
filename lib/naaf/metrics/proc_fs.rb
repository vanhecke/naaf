# frozen_string_literal: true

module Naaf
  module Metrics
    # Everything the dashboard knows about the box comes from /proc. No gem, no
    # shell-out, no helper call — reading a file is cheaper than forking a
    # process and it keeps the privileged surface exactly where it is.
    #
    # `root:` is injectable and every read returns nil for a file that is
    # missing or unreadable, for three reasons that all show up in practice:
    # the maintainer develops on macOS where there is no /proc at all, CI runs
    # on a GitHub runner whose network namespace has no wg0 and may have no
    # netfilter sysctls, and /proc/net/nf_conntrack is 0440 root:root so an
    # unprivileged process gets EACCES on every real box.
    #
    # nil means "unavailable" and renders as an em dash. It never means zero:
    # a dashboard that shows 0 B/s for a link it simply could not measure is
    # lying to the operator in the exact situation they are debugging.
    class ProcFS
      # Narrow on purpose. A bare `rescue => e` here would swallow genuine bugs
      # in the parsers and present them as "this box has no CPU".
      READ_ERRORS = [
        Errno::ENOENT, Errno::EACCES, Errno::EPERM,
        Errno::EINVAL, Errno::ENODEV, Errno::ENOTDIR, Errno::EISDIR
      ].freeze

      CONNTRACK = "sys/net/netfilter"

      def initialize(root: "/proc")
        @root = root
      end

      attr_reader :root

      # One read per file per tick. procfs files are seq_files generated on
      # demand, so two reads through one descriptor can straddle a regeneration
      # and return halves of two different snapshots.
      def read(rel)
        File.binread(File.join(@root, rel)).force_encoding(Encoding::UTF_8).scrub("?")
      rescue *READ_ERRORS
        nil
      end

      def stat = parse(:stat, "stat")
      def loadavg = parse(:loadavg, "loadavg")
      def meminfo = parse(:meminfo, "meminfo")
      def uptime = parse(:uptime, "uptime")
      def net_dev = parse(:net_dev, "net/dev")
      def snmp_udp = parse(:snmp_udp, "net/snmp")
      def default_interface = parse(:default_interface, "net/route")
      def self_status = parse(:self_status, "self/status")
      def self_stat = parse(:self_stat, "self/stat")
      def pressure(kind = "cpu") = parse(:pressure, "pressure/#{kind}")

      # The "live connections" gauge. Deliberately NOT /proc/net/nf_conntrack:
      # the kernel creates that 0440 root:root so this process cannot read it on
      # any real box, it may not be compiled in at all, and it is an O(flows)
      # seq_file that would serialize megabytes onto the shared reactor. These
      # two sysctls are world-readable, O(1), and carry the number that actually
      # matters — how close the table is to full.
      def conntrack
        count = read("#{CONNTRACK}/nf_conntrack_count")
        max = read("#{CONNTRACK}/nf_conntrack_max")
        return nil unless count && max
        {count: Integer(count.strip, 10), max: Integer(max.strip, 10)}
      rescue ArgumentError, TypeError
        nil
      end

      private

      def parse(name, rel)
        text = read(rel) or return nil
        Parse.public_send(name, text)
      end

      # Pure text -> Hash. Tested directly against captured fixture text, so the
      # field orders below are pinned by assertions rather than by memory.
      module Parse
        module_function

        # Fields after the label, 0-based:
        #   0 user  1 nice  2 system  3 idle  4 iowait
        #   5 irq   6 softirq  7 steal  8 guest  9 guest_nice
        #
        # Sum 0..7 and NOT 0..9: the kernel already counts guest inside user and
        # guest_nice inside nice, so including them double-counts and quietly
        # deflates every percentage. iowait is an IDLE state, not busy — folding
        # it into busy is the other classic error, and it matters here because a
        # VPS under storage contention would otherwise read as pegged CPU.
        def stat(text)
          aggregate = nil
          cores = 0
          running = nil
          blocked = nil
          text.each_line do |line|
            label, *rest = line.split
            case label
            when "cpu"
              f = rest.first(8).map(&:to_i)
              next if f.size < 4
              total = f.sum
              idle = f[3] + f[4].to_i
              aggregate = {total: total, busy: total - idle, idle: idle,
                           iowait: f[4].to_i, steal: f[7].to_i}
            when /\Acpu\d+\z/ then cores += 1
            when "procs_running" then running = rest.first.to_i
            when "procs_blocked" then blocked = rest.first.to_i
            end
          end
          return nil unless aggregate
          aggregate.merge(ncpu: cores, procs_running: running, procs_blocked: blocked)
        end

        def loadavg(text)
          f = text.split
          return nil if f.size < 5
          running, procs = f[3].split("/")
          {one: f[0].to_f, five: f[1].to_f, fifteen: f[2].to_f,
           running: running.to_i, procs: procs.to_i, last_pid: f[4].to_i}
        end

        # Values are KiB despite the "kB" suffix. MemFree is the wrong number for
        # "used" on a modern kernel — it counts reclaimable page cache as used
        # and reads 90-95% on a perfectly healthy idle box. MemAvailable is the
        # kernel's own estimate of what a new allocation could actually get.
        def meminfo(text)
          kb = {}
          text.each_line do |line|
            key, rest = line.split(":", 2)
            next unless rest
            kb[key] = rest.split.first.to_i
          end
          return nil if kb["MemTotal"].nil?
          {total_kb: kb["MemTotal"], available_kb: kb["MemAvailable"],
           free_kb: kb["MemFree"], buffers_kb: kb["Buffers"], cached_kb: kb["Cached"],
           swap_total_kb: kb["SwapTotal"].to_i, swap_free_kb: kb["SwapFree"].to_i}
        end

        # Field 2 is idle time summed across every core, so on a 2-core box it is
        # roughly twice field 1. Only field 1 is wall-clock uptime.
        def uptime(text)
          f = text.split
          return nil if f.empty?
          {seconds: f[0].to_f, idle_seconds: f[1].to_f}
        end

        # Two header lines, then one row per interface. Split on the FIRST colon
        # rather than on whitespace: an interface with a wide counter prints as
        # "eth0:1234567890" with no space, which shifts every field by one and
        # silently reports the packet count as the byte count.
        COLUMNS = {
          rx_bytes: 0, rx_packets: 1, rx_errs: 2, rx_drop: 3,
          tx_bytes: 8, tx_packets: 9, tx_errs: 10, tx_drop: 11
        }.freeze

        def net_dev(text)
          text.each_line.drop(2).each_with_object({}) do |line, acc|
            name, rest = line.split(":", 2)
            next if rest.nil?
            f = rest.split
            next if f.size < 16
            acc[name.strip] = COLUMNS.transform_values { |i| f[i].to_i }
          end
        end

        # Header line then value line, per protocol. Zip them rather than
        # indexing by position — the field set grows between kernel versions and
        # a hardcoded index silently starts reporting a different counter. Match
        # "Udp:" including the colon, because "Udp" is a prefix of "UdpLite".
        def snmp_udp(text)
          lines = text.each_line.select { |l| l.start_with?("Udp:") }
          return nil if lines.size < 2
          keys = lines[0].split.drop(1)
          values = lines[1].split.drop(1)
          return nil if keys.size != values.size
          pairs = keys.zip(values.map { |v| Integer(v, 10) }).to_h
          {in_datagrams: pairs["InDatagrams"], no_ports: pairs["NoPorts"],
           in_errors: pairs["InErrors"], out_datagrams: pairs["OutDatagrams"],
           rcvbuf_errors: pairs["RcvbufErrors"], sndbuf_errors: pairs["SndbufErrors"]}
        rescue ArgumentError
          nil
        end

        # The WAN interface is discovered, never hardcoded — AGENTS.md is
        # explicit that eth0/ens3 must not be assumed. A default route is
        # destination 0.0.0.0 with mask 0.0.0.0 and the gateway flag set.
        RTF_GATEWAY = 0x2

        def default_interface(text)
          text.each_line.drop(1).each do |line|
            f = line.split
            next if f.size < 8
            next unless f[1] == "00000000" && f[7] == "00000000"
            next if (f[3].to_i(16) & RTF_GATEWAY).zero?
            return f[0]
          end
          nil
        end

        def self_status(text)
          kb = {}
          text.each_line do |line|
            key, rest = line.split(":", 2)
            kb[key] = rest.to_s.split.first.to_i if rest
          end
          return nil if kb["VmRSS"].nil?
          {vm_rss_kb: kb["VmRSS"], vm_hwm_kb: kb["VmHWM"], threads: kb["Threads"]}
        end

        # comm is field 2 and is wrapped in parentheses, but it can itself
        # contain spaces and parentheses ("(ruby (worker) 1)"), so splitting the
        # whole line on whitespace shifts every later field. Take everything
        # after the LAST ")" — that is the documented way to parse this file.
        def self_stat(text)
          close = text.rindex(")") or return nil
          rest = text[(close + 1)..].split
          return nil if rest.size < 20
          # rest[0] is field 3 (state), so field N is rest[N - 3].
          {utime: rest[11].to_i, stime: rest[12].to_i, num_threads: rest[17].to_i}
        end

        # avg10/60/300 are already-averaged percentages, so they are gauges and
        # must not be differenced. "full" is absent on some kernels for cpu.
        def pressure(text)
          out = text.each_line.each_with_object({}) do |line, acc|
            kind, *fields = line.split
            next unless %w[some full].include?(kind)
            acc[kind.to_sym] = fields.each_with_object({}) do |f, h|
              k, v = f.split("=", 2)
              h[k.to_sym] = v.to_f if v
            end
          end
          out.empty? ? nil : out
        end
      end
    end
  end
end
