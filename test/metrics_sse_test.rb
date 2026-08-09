# frozen_string_literal: true

require_relative "helper"
require "naaf/metrics/sse"

describe Naaf::Metrics::SSE do
  def sse = Naaf::Metrics::SSE

  it "frames a single-line payload with its event name" do
    expect(sse.frame("hello", event: "kpis")).to be == "event: kpis\ndata: hello\n\n"
  end

  # The first newline inside a data: line terminates the event, and everything
  # after it is read as unknown field lines and dropped. An HTML fragment is
  # full of newlines, so getting this wrong swaps in the first line of a panel
  # and silently discards the rest.
  it "gives every line of a payload its own data: line" do
    out = sse.frame("<b>hi</b>\n<i>there</i>", event: "kpis")
    expect(out).to be == "event: kpis\ndata: <b>hi</b>\ndata: <i>there</i>\n\n"
  end

  it "splits on CRLF and on a bare CR, not only on LF" do
    expect(sse.frame("a\r\nb")).to be == "data: a\ndata: b\n\n"
    expect(sse.frame("a\rb")).to be == "data: a\ndata: b\n\n"
  end

  it "still emits a data: line for an empty payload" do
    expect(sse.frame("")).to be == "data: \n\n"
    expect(sse.frame(nil)).to be == "data: \n\n"
  end

  it "omits the event line when there is no event name" do
    expect(sse.frame("x")).to be == "data: x\n\n"
  end

  it "ends every frame with the blank line that dispatches it" do
    expect(sse.frame("x", event: "y").end_with?("\n\n")).to be == true
  end

  it "emits a retry hint in milliseconds" do
    expect(sse.retry_after(3000)).to be == "retry: 3000\n\n"
  end

  it "emits a comment frame that carries no data" do
    expect(sse.comment("keep-alive")).to be == ": keep-alive\n\n"
  end
end
