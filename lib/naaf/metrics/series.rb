# frozen_string_literal: true

module Naaf
  module Metrics
    # A fixed-capacity ring of samples. Append is O(1) and allocates nothing
    # after construction.
    #
    # There is deliberately no SQLite table behind this. A metrics table in
    # naaf.db would multiply the WAL churn Litestream replicates to the object
    # store, and naaf.db is configuration truth, not a time series. The price is
    # that history resets when the process restarts. That is the deal, and it is
    # written down in AGENTS.md so nobody "improves" it later.
    #
    # A sample may be nil, meaning "not known for this interval" — the first
    # tick after boot, or an interval spanning a counter reset. Aggregations skip
    # nils, so a reset never drags a mean down. The sparkline draws them at the
    # baseline (Renderers::SVG.clean), which is indistinguishable from a genuine
    # idle period; the headline number beside the chart is the one that says
    # "—", and that is where the distinction is meant to be read.
    class Series
      attr_reader :capacity

      def initialize(capacity)
        capacity = capacity.to_i
        raise ArgumentError, "capacity must be positive" unless capacity.positive?
        @capacity = capacity
        @buffer = Array.new(capacity)
        @head = 0
        @size = 0
      end

      def <<(value)
        @buffer[@head] = value&.to_f
        @head = (@head + 1) % @capacity
        @size += 1 if @size < @capacity
        self
      end

      attr_reader :size
      def empty? = @size.zero?
      def latest = @size.zero? ? nil : @buffer[(@head - 1) % @capacity]

      # Oldest first, at most n samples.
      def last(n = @size)
        n = [n.to_i, @size].min
        return [] if n <= 0
        start = (@head - n) % @capacity
        Array.new(n) { |i| @buffer[(start + i) % @capacity] }
      end

      # Headline numbers use a short mean while the sparkline beside them shows
      # raw samples: a byte counter read every couple of seconds is too jumpy to
      # read as a number, though its shape is perfectly legible.
      def mean(n = @size)
        vals = last(n).compact
        vals.empty? ? nil : vals.sum / vals.size
      end

      def max(n = @size) = last(n).compact.max
    end

    # Named series, created on demand at a single capacity.
    #
    # retain! is the leak guard. Series are keyed per client and per interface,
    # so without it every deleted client and every interface that ever appeared
    # keeps a full-length ring alive until the process restarts.
    class SeriesStore
      def initialize(capacity)
        @capacity = capacity
        @series = {}
      end

      def for(key) = (@series[key] ||= Series.new(@capacity))
      def [](key) = @series[key]
      def keys = @series.keys
      def size = @series.size

      def retain!(keys)
        keep = keys.to_a.to_set
        @series.keys.each { |k| @series.delete(k) unless keep.include?(k) }
        self
      end
    end
  end
end
