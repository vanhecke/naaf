# frozen_string_literal: true

module Naaf
  # Presentation-only helpers shared by the templates. Pure functions of their
  # arguments, so they are tested directly rather than through a rendered page.
  #
  # This started as an inline lambda at the top of views/dashboard.erb, which
  # was right while exactly one template needed it. The dashboard fragments need
  # the same formatting in several files, and duplicating it in each would let
  # them drift apart, so it moved here. It is deliberately a plain module and
  # NOT a Roda view-helper plugin: nothing here touches the request, and a pure
  # module is directly testable.
  #
  # Every formatter renders a nil as an em dash rather than "0" or "". A metric
  # that could not be sampled (no /proc on a dev box, a counter that has only
  # been seen once, conntrack absent) is genuinely unknown, and showing it as
  # zero would be a lie the operator cannot see through.
  module Format
    DASH = "—"

    # Base 1024 with the short labels, matching `ls -h` and what `wg show`
    # readers expect. Consistent across storage and throughput so two numbers on
    # the same screen are always comparable.
    UNITS = ["B", "KB", "MB", "GB", "TB", "PB"].freeze
    STEP = 1024.0

    module_function

    # Output is pinned by test/app_test.rb, which asserts "2h ago" appears for a
    # client that handshaked two hours ago.
    def ago(t, now: Time.now)
      return "never" unless t
      secs = (now - t.to_time).to_i
      return "just now" if secs < 5
      return "#{secs}s ago" if secs < 60
      return "#{secs / 60}m ago" if secs < 3600
      return "#{secs / 3600}h ago" if secs < 86_400
      "#{secs / 86_400}d ago"
    end

    def bytes(n)
      return DASH unless finite?(n)
      return "0 B" if n.zero?
      value = n.to_f.abs
      unit = 0
      while value >= STEP && unit < UNITS.length - 1
        value /= STEP
        unit += 1
      end
      sign = n.negative? ? "-" : ""
      # Whole bytes never get a decimal point; everything else gets one.
      places = unit.zero? ? 0 : 1
      "#{sign}#{trim(value, places)} #{UNITS[unit]}"
    end

    def bps(n)
      return DASH unless finite?(n)
      "#{bytes(n)}/s"
    end

    def pct(v, places: 0)
      return DASH unless finite?(v)
      "#{trim(v.to_f, places)}%"
    end

    def duration(secs)
      return DASH unless finite?(secs)
      s = secs.to_i.abs
      return "#{s}s" if s < 60
      return "#{s / 60}m #{s % 60}s" if s < 3600
      return "#{s / 3600}h #{(s % 3600) / 60}m" if s < 86_400
      "#{s / 86_400}d #{(s % 86_400) / 3600}h"
    end

    # Thousands-separated, for table columns and raw counters. The sign is held
    # aside rather than grouped: scanning digits off the reversed string would
    # otherwise drop the leading minus entirely.
    def count(n)
      return DASH unless finite?(n)
      i = n.to_i
      grouped = i.abs.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
      i.negative? ? "-#{grouped}" : grouped
    end

    # Auto-compacted, for the big number on a stat tile: 1,284 / 12.9K / 4.2M.
    def compact(n)
      return DASH unless finite?(n)
      v = n.to_i
      return count(v) if v.abs < 10_000
      return "#{trim(v / 1_000.0, 1)}K" if v.abs < 1_000_000
      return "#{trim(v / 1_000_000.0, 1)}M" if v.abs < 1_000_000_000
      "#{trim(v / 1_000_000_000.0, 1)}B"
    end

    # A countable rate: queries, packets, datagrams. Sub-1 rates keep a decimal
    # so a quiet-but-alive link does not read as a dead one.
    def per_sec(v, unit: "/s")
      return DASH unless finite?(v)
      f = v.to_f
      value = (f < 10 && f.positive?) ? trim(f, 1) : count(f.round)
      "#{value}#{unit}"
    end

    def clock(t)
      return DASH unless t
      t.to_time.strftime("%H:%M:%S")
    end

    # The catch-all for a value that needs no formatting but may be missing.
    def dash(v)
      s = v.to_s
      s.empty? ? DASH : s
    end

    # NaN and Infinity are the whole reason this exists: Float division does not
    # raise, so 1.0/0.0 and 0.0/0.0 sail through arithmetic and only surface
    # when format("%.1f", …) writes "NaN" or "Inf" into the page.
    def finite?(v)
      v.is_a?(Numeric) && v.to_f.finite?
    end

    # 1.0 -> "1", 1.25 -> "1.2". Trailing ".0" is noise on a dashboard.
    def trim(value, places)
      s = format("%.#{places}f", value)
      places.zero? ? s : s.sub(/\.0+\z/, "")
    end
  end
end
