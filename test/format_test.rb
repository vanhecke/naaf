# frozen_string_literal: true

require_relative "helper"
require "naaf/format"

describe Naaf::Format do
  def f = Naaf::Format

  # These five bands are what views/dashboard.erb rendered inline before this
  # module existed, and test/app_test.rb still asserts "2h ago" appears on a
  # rendered page. Moving the formatter must not move the output.
  describe ".ago" do
    def at(secs) = Time.now - secs

    it "renders never for a client that has never handshaked" do
      expect(f.ago(nil)).to be == "never"
    end

    it "renders the five bands the clients table has always shown" do
      expect(f.ago(at(1))).to be == "just now"
      expect(f.ago(at(30))).to be == "30s ago"
      expect(f.ago(at(120))).to be == "2m ago"
      expect(f.ago(at(7200))).to be == "2h ago"
      expect(f.ago(at(172_800))).to be == "2d ago"
    end

    it "takes now as an argument so the bands are testable without sleeping" do
      now = Time.utc(2026, 8, 9, 12, 0, 0)
      expect(f.ago(Time.utc(2026, 8, 9, 10, 0, 0), now: now)).to be == "2h ago"
    end
  end

  describe ".bytes" do
    it "steps through the units at 1024" do
      expect(f.bytes(0)).to be == "0 B"
      expect(f.bytes(512)).to be == "512 B"
      expect(f.bytes(1024)).to be == "1 KB"
      expect(f.bytes(1536)).to be == "1.5 KB"
      expect(f.bytes(1024 * 1024)).to be == "1 MB"
      expect(f.bytes(3 * 1024**3)).to be == "3 GB"
    end

    it "stops at the largest unit rather than running off the end of the table" do
      expect(f.bytes(1024**6)).to be(:include?, "PB")
    end
  end

  describe ".compact" do
    it "keeps small numbers exact and compacts large ones" do
      expect(f.compact(42)).to be == "42"
      expect(f.compact(1284)).to be == "1,284"
      expect(f.compact(12_900)).to be == "12.9K"
      expect(f.compact(4_200_000)).to be == "4.2M"
    end
  end

  describe ".count" do
    it "separates thousands and keeps the sign outside the groups" do
      expect(f.count(1234)).to be == "1,234"
      expect(f.count(1_234_567)).to be == "1,234,567"
      expect(f.count(-1234)).to be == "-1,234"
      expect(f.count(0)).to be == "0"
    end
  end

  describe ".duration" do
    it "renders two units at most, largest first" do
      expect(f.duration(45)).to be == "45s"
      expect(f.duration(90)).to be == "1m 30s"
      expect(f.duration(3700)).to be == "1h 1m"
      expect(f.duration(273_600)).to be == "3d 4h"
    end
  end

  # The whole reason this module exists. Float division does not raise —
  # 1.0/0.0 is Infinity and 0.0/0.0 is NaN — and format("%.1f", NAN) writes the
  # literal text "NaN" into the page. Every formatter is the last gate before
  # HTML, so every one of them must refuse a non-finite value.
  describe "missing and non-finite values" do
    it "renders nil as an em dash rather than zero" do
      expect(f.bytes(nil)).to be == "—"
      expect(f.bps(nil)).to be == "—"
      expect(f.pct(nil)).to be == "—"
      expect(f.duration(nil)).to be == "—"
      expect(f.count(nil)).to be == "—"
      expect(f.compact(nil)).to be == "—"
      expect(f.clock(nil)).to be == "—"
      expect(f.dash(nil)).to be == "—"
    end

    it "renders NaN and Infinity as an em dash, never as text in the page" do
      [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |bad|
        expect(f.bytes(bad)).to be == "—"
        expect(f.bps(bad)).to be == "—"
        expect(f.pct(bad)).to be == "—"
        expect(f.compact(bad)).to be == "—"
      end
    end

    it "treats an empty string as missing" do
      expect(f.dash("")).to be == "—"
      expect(f.dash("wg0")).to be == "wg0"
    end
  end

  describe ".pct and .bps" do
    it "drops a trailing .0 so the tiles stay quiet" do
      expect(f.pct(42.0, places: 1)).to be == "42%"
      expect(f.pct(42.5, places: 1)).to be == "42.5%"
      expect(f.pct(42.4)).to be == "42%"
    end

    it "renders a throughput with its unit" do
      expect(f.bps(1536)).to be == "1.5 KB/s"
    end
  end
end
