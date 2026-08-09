# frozen_string_literal: true

require_relative "helper"
require "naaf/metrics/num"

describe Naaf::Metrics::Num do
  def num = Naaf::Metrics::Num

  describe ".rate" do
    it "divides the delta by the real elapsed time, not the nominal interval" do
      expect(decimals(num.rate(100, 300, 2.5))).to be == "80.000"
    end

    # WireGuard rx/tx and /proc/net/dev counters restart at zero when a peer is
    # removed and re-added, when wg0 is recreated, or on an interface bounce.
    # Reporting the negative delta would draw a -4 GB/s spike that rescales every
    # other series into a flat line; .abs would invent a burst that never
    # happened. Neither is honest — we simply do not know the rate across a
    # reset, and nil is how the dashboard says so.
    it "reports nothing, never a negative rate, when a counter resets" do
      expect(num.rate(1_000_000, 12, 2)).to be_nil
    end

    it "refuses an interval too short to divide by" do
      expect(num.rate(100, 300, 0)).to be_nil
      expect(num.rate(100, 300, -1)).to be_nil
      expect(num.rate(100, 300, 0.001)).to be_nil
    end

    it "reports nothing when either side is missing" do
      expect(num.rate(nil, 300, 2)).to be_nil
      expect(num.rate(100, nil, 2)).to be_nil
      expect(num.rate(100, 300, nil)).to be_nil
    end

    it "reports zero for a genuinely idle counter" do
      expect(decimals(num.rate(500, 500, 2))).to be == "0.000"
    end
  end

  describe ".pct" do
    it "computes a percentage with float division, not integer truncation" do
      expect(decimals(num.pct(1, 8))).to be == "12.500"
    end

    it "refuses a zero or negative denominator instead of returning Infinity" do
      expect(num.pct(1, 0)).to be_nil
      expect(num.pct(1, -5)).to be_nil
    end

    it "refuses a negative numerator" do
      expect(num.pct(-1, 5)).to be_nil
    end

    it "clamps to 0..100 so a stale total cannot overflow a meter" do
      expect(decimals(num.pct(150, 100))).to be == "100.000"
      expect(decimals(num.pct(0, 100))).to be == "0.000"
    end

    it "refuses non-finite input rather than passing NaN downstream" do
      expect(num.pct(Float::NAN, 100)).to be_nil
      expect(num.pct(Float::INFINITY, 100)).to be_nil
      expect(num.pct(1, Float::NAN)).to be_nil
    end
  end

  describe ".cpu_busy" do
    it "computes the busy fraction from two jiffy snapshots" do
      a = {total: 1000, busy: 200}
      b = {total: 2000, busy: 450}
      expect(decimals(num.cpu_busy(a, b))).to be == "25.000"
    end

    # Two samples inside a single jiffy have a zero total delta. Dividing gives
    # Infinity, which would render as a 100% CPU spike out of nowhere.
    it "reports nothing for two samples inside one jiffy" do
      s = {total: 100, busy: 50}
      expect(num.cpu_busy(s, s)).to be_nil
    end

    it "reports nothing when the counters went backwards" do
      expect(num.cpu_busy({total: 2000, busy: 450}, {total: 10, busy: 2})).to be_nil
    end

    it "reports nothing when there is no previous sample yet" do
      expect(num.cpu_busy(nil, {total: 10, busy: 2})).to be_nil
    end
  end
end
