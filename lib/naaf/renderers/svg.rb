# frozen_string_literal: true

require "cgi"

module Naaf
  module Renderers
    # Charts, as pure functions from a series of numbers to a string of SVG.
    #
    # It lives under renderers/ with the nftables and wireguard renderers
    # because it obeys the same rule: no side effects, no database, no clock —
    # so AGENTS.md's "every renderer change needs a test asserting the emitted
    # text" applies to it automatically.
    #
    # Nothing here names a colour. Every mark carries a class and the stylesheet
    # supplies the hue, which is what lets the same markup work on Bulma's light
    # and dark themes with selected steps for each rather than an automatic
    # flip. It is also what keeps this file testable as text.
    module SVG
      PAD = 2.0

      module_function

      # A single series, oldest sample on the left. No axes, no gridlines and no
      # per-point labels: the current value is printed beside it in the tile, and
      # the clients table is the table view for the per-peer ones.
      #
      # Four degenerate inputs have to be right, because a NaN in path data
      # renders as an invisible path with no console error and no exception:
      #   empty          -> an <svg> with the title and no path at all
      #   one sample     -> duplicated, so it draws a flat line and not a dot
      #   flat / all zero -> max == min, so a naive y-scale divides by zero
      #   nil or non-finite sample -> drawn at the baseline, never as NaN
      def sparkline(values, width: 160, height: 32, series: nil, label: nil, max: nil)
        vals = clean(values)
        klass = ["naaf-spark", series && "naaf-#{series}"].compact.join(" ")
        head = open_svg(klass, width, height, label)
        return "#{head}</svg>" if vals.empty?

        vals *= 2 if vals.size == 1
        top = scale(vals, max)
        inner_h = height - PAD * 2
        points = vals.each_with_index.map { |v, i|
          x = PAD + step(width, vals.size) * i
          y = PAD + inner_h - (v / top).clamp(0.0, 1.0) * inner_h
          "#{n(x)},#{n(y)}"
        }
        base = n(PAD + inner_h)
        line = "M#{points.join(" L")}"
        head +
          path("naaf-area", "#{line} L#{n(width - PAD)},#{base} L#{n(PAD)},#{base} Z") +
          path("naaf-line", line) +
          "</svg>"
      end

      # Two series against ONE axis and a shared scale: inbound above the centre
      # line, outbound below it. Never two y-scales — the alignment of two
      # independent scales is arbitrary and invents a correlation that is not in
      # the data. The caller prints "in 1.2 MB/s / out 340 KB/s" next to it, so
      # the two series are direct-labelled and identity is never colour alone.
      def throughput(down:, up:, width: 240, height: 56, label: nil)
        d = clean(down)
        u = clean(up)
        head = open_svg("naaf-spark naaf-duplex", width, height, label)
        mid = height / 2.0
        rule = line_el("naaf-baseline", PAD, mid, width - PAD, mid)
        return "#{head}#{rule}</svg>" if d.empty? && u.empty?

        d *= 2 if d.size == 1
        u *= 2 if u.size == 1
        top = scale(d + u, nil)
        half = mid - PAD

        head + rule +
          arm(d, width, mid, half, top, "naaf-in", -1) +
          arm(u, width, mid, half, top, "naaf-out", 1) +
          "</svg>"
      end

      # --- internals ---------------------------------------------------------

      def arm(vals, width, mid, half, top, series, direction)
        return "" if vals.empty?
        points = vals.each_with_index.map { |v, i|
          x = PAD + step(width, vals.size) * i
          y = mid + direction * (v / top).clamp(0.0, 1.0) * half
          "#{n(x)},#{n(y)}"
        }
        stroke = "M#{points.join(" L")}"
        area = "#{stroke} L#{n(width - PAD)},#{n(mid)} L#{n(PAD)},#{n(mid)} Z"
        path("naaf-area #{series}", area) + path("naaf-line #{series}", stroke)
      end

      # A nil sample means "not known for this interval" and a non-finite one
      # means an upstream divisor was zero. Both are drawn at the baseline; what
      # must never happen is either reaching the path data.
      def clean(values)
        Array(values).map do |v|
          f = v.to_f
          (v.is_a?(Numeric) && f.finite? && f >= 0) ? f : 0.0
        end
      end

      # An all-zero or flat-at-zero series has no range to scale against, so pin
      # the top rather than dividing by zero.
      def scale(vals, explicit)
        top = [explicit.to_f, vals.max.to_f, 0.0].max
        top.positive? ? top : 1.0
      end

      def step(width, count) = (width - PAD * 2) / (count - 1)

      def open_svg(klass, width, height, label)
        "<svg class=\"#{klass}\" role=\"img\" width=\"100%\" height=\"#{n(height)}\" " \
          "viewBox=\"0 0 #{n(width)} #{n(height)}\" preserveAspectRatio=\"none\">" \
          "<title>#{escape(label || "trend")}</title>"
      end

      # non-scaling-stroke keeps the line 2px however far the viewBox is
      # stretched; without it, preserveAspectRatio="none" smears the stroke.
      def path(klass, d)
        "<path class=\"#{klass}\" d=\"#{d}\" vector-effect=\"non-scaling-stroke\"/>"
      end

      def line_el(klass, x1, y1, x2, y2)
        "<line class=\"#{klass}\" x1=\"#{n(x1)}\" y1=\"#{n(y1)}\" x2=\"#{n(x2)}\" " \
          "y2=\"#{n(y2)}\" vector-effect=\"non-scaling-stroke\"/>"
      end

      # One decimal place, trailing ".0" stripped: keeps the path short and makes
      # the emitted string stable enough for a test to assert on exactly.
      def n(f)
        v = f.to_f
        v = 0.0 unless v.finite?
        v.round(1).to_s.sub(/\.0\z/, "")
      end

      def escape(s) = CGI.escapeHTML(s.to_s)
    end
  end
end
