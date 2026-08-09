# frozen_string_literal: true

require_relative "helper"
require "naaf/metrics/series"

describe Naaf::Metrics::Series do
  def series(capacity, *values)
    s = Naaf::Metrics::Series.new(capacity)
    values.each { |v| s << v }
    s
  end

  it "refuses a capacity that could never hold a sample" do
    expect { Naaf::Metrics::Series.new(0) }.to raise_exception(ArgumentError)
  end

  it "returns samples oldest first" do
    expect(series(5, 1, 2, 3).last).to be == [1.0, 2.0, 3.0]
  end

  # The bound is the whole point: this runs for months in a long-lived process
  # and there is a ring per client and per interface.
  it "keeps only the newest samples and never grows past its capacity" do
    s = series(3, 1, 2, 3, 4, 5)
    expect(s.last).to be == [3.0, 4.0, 5.0]
    expect(s.size).to be == 3
    expect(s.capacity).to be == 3
  end

  it "clamps a request for more samples than it holds" do
    expect(series(5, 1, 2).last(100)).to be == [1.0, 2.0]
    expect(series(5, 1, 2).last(0)).to be == []
  end

  it "reports the newest sample" do
    expect(decimals(series(3, 1, 2).latest)).to be == "2.000"
    expect(series(3).latest).to be_nil
  end

  # An empty series is the state every chart is in for the first tick after
  # boot. Aggregating it must not divide by zero.
  it "aggregates an empty series to nothing rather than raising" do
    s = series(3)
    expect(s).to be(:empty?)
    expect(s.mean).to be_nil
    expect(s.max).to be_nil
  end

  # A nil sample is "not known for this interval" — the first tick, or an
  # interval that spanned a counter reset. It must not be counted as a zero,
  # which would drag a mean down and claim the link was idle.
  it "skips unknown samples when aggregating but keeps their place in the ring" do
    s = series(5, 10, nil, 20)
    expect(s.last).to be == [10.0, nil, 20.0]
    expect(decimals(s.mean)).to be == "15.000"
    expect(decimals(s.max)).to be == "20.000"
    expect(decimals(s.latest)).to be == "20.000"
  end

  it "aggregates a series of only unknowns to nothing" do
    expect(series(3, nil, nil).mean).to be_nil
  end
end

describe Naaf::Metrics::SeriesStore do
  def store = Naaf::Metrics::SeriesStore.new(4)

  it "creates a series on first use at the configured capacity" do
    s = store
    s.for(:cpu) << 1
    expect(s.for(:cpu).capacity).to be == 4
    expect(s.for(:cpu).last).to be == [1.0]
  end

  # Without this, every deleted client and every interface that ever appeared
  # keeps a full-length ring alive until the process restarts.
  it "frees the series of keys that no longer exist" do
    s = store
    s.for(:"peer.a") << 1
    s.for(:"peer.b") << 1
    s.for(:cpu) << 1
    s.retain!([:"peer.a", :cpu])
    expect(s.keys.sort).to be == [:cpu, :"peer.a"]
    expect(s[:"peer.b"]).to be_nil
  end

  it "drops everything when nothing is retained" do
    s = store
    s.for(:cpu) << 1
    s.retain!([])
    expect(s.size).to be == 0
  end
end
