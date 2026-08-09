# frozen_string_literal: true

module Naaf
  module Metrics
    # The only arithmetic allowed between a kernel counter and a template.
    #
    # Float division does not raise in Ruby: 1.0/0.0 is Infinity, 0.0/0.0 is
    # NaN, and Integer#fdiv(0) is Infinity. None of that blows up — it sails
    # through every later calculation and finally surfaces as the literal text
    # "NaN" in the page. So every division in the dashboard goes through here,
    # and every function returns either a finite Numeric or nil. nil means
    # "unknown" and renders as an em dash; it never means zero.
    module Num
      # Two samples taken inside the same scheduler turn would divide by very
      # nearly nothing and report an absurd rate. Below this, say nothing.
      MIN_DT = 0.05

      module_function

      def finite(v)
        (v.is_a?(Numeric) && v.to_f.finite?) ? v : nil
      end

      # Kernel counters are absolute and monotonic *until* they are not: removing
      # and re-adding a WireGuard peer, recreating wg0, or an interface bouncing
      # all restart them at zero. A decrease is therefore a reset, not negative
      # traffic. Report nil (the caller reseeds its previous sample) rather than
      # .abs, which would invent a huge burst, or a clamp to 0, which would claim
      # the link was idle when we simply do not know.
      def rate(previous, current, seconds)
        return nil unless previous.is_a?(Numeric) && current.is_a?(Numeric)
        return nil unless seconds.is_a?(Numeric) && seconds.to_f.finite?
        return nil if seconds.to_f < MIN_DT
        delta = current - previous
        return nil if delta.negative?
        finite(delta.fdiv(seconds.to_f))
      end

      def pct(num, den)
        return nil unless num.is_a?(Numeric) && den.is_a?(Numeric)
        return nil unless num.to_f.finite? && den.to_f.finite?
        return nil if den <= 0 || num.negative?
        finite(num.fdiv(den) * 100.0)&.clamp(0.0, 100.0)
      end

      # Busy fraction from two /proc/stat jiffy snapshots. A zero total delta is
      # two samples inside one jiffy, not an idle CPU.
      def cpu_busy(previous, current)
        return nil unless previous.is_a?(Hash) && current.is_a?(Hash)
        total = current[:total].to_i - previous[:total].to_i
        busy = current[:busy].to_i - previous[:busy].to_i
        return nil if total <= 0 || busy.negative?
        pct(busy, total)
      end
    end
  end
end
