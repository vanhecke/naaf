# frozen_string_literal: true

require_relative "helper"
require "naaf/renderers/svg"

describe Naaf::Renderers::SVG do
  def svg = Naaf::Renderers::SVG

  # Every shape the renderer can produce, including the degenerate ones.
  def every_shape
    [
      svg.sparkline([]),
      svg.sparkline([5]),
      svg.sparkline([0, 0, 0]),
      svg.sparkline([1, nil, 3], series: "in", label: %(a "quoted" & <tagged> label)),
      svg.throughput(down: [], up: []),
      svg.throughput(down: [1, 2, 3], up: [3, 2, 1])
    ]
  end

  # A browser renders broken markup as nothing at all, with no error anywhere —
  # so structure gets asserted rather than assumed. There is no XML parser in
  # this project's dependencies and adding a gem is an "Ask first" boundary, so
  # this checks the three things that actually break: element balance,
  # self-closing children, and attribute quoting.
  it "emits structurally sound markup for every shape it can produce" do
    every_shape.each do |out|
      expect(out.scan("<svg").length).to be == 1
      expect(out.scan("</svg>").length).to be == 1
      # Children are self-closing, so no child can ever be left unclosed.
      expect(out.scan(/<(?:path|line|title)\b/).length)
        .to be == out.scan(/\/>|<\/title>/).length
      # An odd number of quotes means a value broke out of its attribute.
      expect(out.count("\"").even?).to be == true
      expect(out).not.to be(:match?, /<[^>]*<|>[^<]*>/)
    end
  end

  # A NaN or Infinity in path data does not raise and does not warn — the
  # browser silently draws nothing. Every degenerate input below produced one at
  # some point during development, which is why each gets its own test.
  describe "degenerate series" do
    it "renders a titled, empty chart for a series with no samples" do
      out = svg.sparkline([])
      expect(out).to be(:include?, "<svg")
      expect(out).to be(:include?, "<title>")
      expect(out.include?("<path")).to be == false
    end

    it "draws a single sample as a flat line rather than a dot" do
      d = svg.sparkline([5])[/class="naaf-line" d="([^"]+)"/, 1]
      ys = d.scan(/[\d.]+,([\d.]+)/).flatten
      expect(ys.length).to be == 2
      expect(ys.uniq.length).to be == 1
    end

    # max == min, so a naive (v - min) / (max - min) divides by zero here.
    it "renders an all-zero series against a pinned scale" do
      out = svg.sparkline([0, 0, 0])
      expect(out).to be(:include?, "<path")
      expect(out).not.to be(:match?, /NaN|Infinity/)
    end

    it "renders a flat non-zero series without dividing by zero" do
      out = svg.sparkline([7, 7, 7])
      expect(out).not.to be(:match?, /NaN|Infinity/)
    end

    # Flattening an entirely-unmeasured series to zeros paints a hard line
    # across the chart that reads exactly like a measured idle period — and in
    # the duplex chart it paints that line in the outbound colour, so a tunnel
    # nobody has measured yet shows up as a red streak.
    it "draws no line at all for a series with nothing measured in it" do
      out = svg.sparkline([nil, nil, nil])
      expect(out).to be(:include?, "<svg")
      expect(out.include?("<path")).to be == false
    end

    it "draws no arm for a duplex series with nothing measured in it" do
      out = svg.throughput(down: [nil, nil], up: [nil, nil])
      expect(out).to be(:include?, "naaf-baseline")
      expect(out.include?("naaf-line")).to be == false
    end

    it "draws an unknown sample at the baseline instead of emitting NaN" do
      out = svg.sparkline([1, nil, 2])
      expect(out).not.to be(:match?, /NaN|Infinity/)
    end

    it "refuses a non-finite sample rather than writing it into the path" do
      out = svg.sparkline([1, Float::INFINITY, Float::NAN, -5, 2])
      expect(out).not.to be(:match?, /NaN|Infinity|-\d/)
    end
  end

  describe ".sparkline" do
    it "emits an area under the line, both carrying classes and no colour" do
      out = svg.sparkline([1, 2, 3], series: "in")
      expect(out).to be(:include?, "class=\"naaf-spark naaf-in\"")
      expect(out).to be(:include?, "class=\"naaf-area\"")
      expect(out).to be(:include?, "class=\"naaf-line\"")
      # The stylesheet owns every hue so dark mode gets selected steps rather
      # than an automatic flip. A colour here would defeat that.
      expect(out).not.to be(:match?, /fill="#|stroke="#|rgb\(/)
    end

    it "keeps the stroke width constant however far the viewBox is stretched" do
      expect(svg.sparkline([1, 2])).to be(:include?, "vector-effect=\"non-scaling-stroke\"")
    end

    it "puts the oldest sample on the left and the newest on the right" do
      d = svg.sparkline([0, 10], height: 12, width: 12)[/class="naaf-line" d="([^"]+)"/, 1]
      first_y, last_y = d.scan(/[\d.]+,([\d.]+)/).flatten.map(&:to_f)
      expect(first_y > last_y).to be == true # y grows downwards, so higher value is lower y
    end

    it "escapes a label so a client name cannot inject markup into the chart" do
      out = svg.sparkline([1, 2], label: "<script>x</script>")
      expect(out).to be(:include?, "&lt;script&gt;")
      expect(out.include?("<script>")).to be == false
    end
  end

  describe ".throughput" do
    it "mirrors the two series about one shared baseline" do
      out = svg.throughput(down: [1, 2], up: [1, 2])
      expect(out).to be(:include?, "class=\"naaf-baseline\"")
      expect(out).to be(:include?, "naaf-in")
      expect(out).to be(:include?, "naaf-out")
      expect(out).not.to be(:match?, /NaN|Infinity/)
    end

    # One axis, one scale. Two independent y-scales would make the alignment of
    # the two arms arbitrary and invent a correlation that is not in the data.
    it "scales both arms against the same maximum" do
      out = svg.throughput(down: [100], up: [50], width: 100, height: 40)
      arms = out.scan(/class="naaf-line naaf-(in|out)" d="M[\d.]+,([\d.]+)/)
      inbound = arms.find { |a| a.first == "in" }.last.to_f
      outbound = arms.find { |a| a.first == "out" }.last.to_f
      mid = 20.0
      # The larger series reaches the edge; the half-sized one reaches halfway.
      expect(decimals(mid - inbound, 1)).to be == "18.0"
      expect(decimals(outbound - mid, 1)).to be == "9.0"
    end

    it "renders a baseline and nothing else when both series are empty" do
      out = svg.throughput(down: [], up: [])
      expect(out).to be(:include?, "naaf-baseline")
      expect(out.include?("naaf-line")).to be == false
    end

    it "draws only the arm that has samples" do
      out = svg.throughput(down: [1, 2], up: [])
      expect(out).to be(:include?, "naaf-line naaf-in")
      expect(out.include?("naaf-line naaf-out")).to be == false
    end
  end
end
