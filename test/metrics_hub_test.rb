# frozen_string_literal: true

require_relative "helper"
require "sus/fixtures/async"
require "naaf/metrics/hub"

# The first test in this project that needs a real reactor. Everything else —
# collector, samplers, renderers — is deliberately drivable without one; the
# hub is the one piece whose whole job is fiber behaviour.
#
# Every wait is wrapped in a timeout so a regression fails loudly instead of
# wedging bin/ci forever.
describe Naaf::Metrics::Hub do
  include Sus::Fixtures::Async::ReactorContext

  def hub = @hub ||= Naaf::Metrics::Hub.new

  def within(seconds = 1.0, &block)
    Async::Task.current.with_timeout(seconds, &block)
  end

  it "wakes a subscriber that was already waiting" do
    got = nil
    waiter = Async { within { got = hub.wait(0) } }
    Async { hub.publish(:first) }.wait
    waiter.wait

    expect(got).to be == [1, :first]
  end

  # A tab that connects between ticks must paint immediately rather than stare
  # at an empty page until the next one.
  it "hands the current frame straight to a subscriber that arrives late" do
    hub.publish(:already_here)
    within { expect(hub.wait(0)).to be == [1, :already_here] }
  end

  # The lost-wakeup hole: signal only reaches fibers that are already parked, so
  # a subscriber busy rendering when a tick lands would sleep through it. The
  # sequence number is what closes that.
  it "does not sleep through a frame published while the subscriber was busy" do
    hub.publish(:missed_it) # nobody waiting: the signal reaches no one
    within { expect(hub.wait(0)).to be == [1, :missed_it] }
  end

  # Deliberately lossy. A monitoring stream wants the freshest sample; a
  # backlog of stale frames is worse than no frames, and it is also the thing
  # that would grow without bound behind a wedged client.
  it "drops stale frames rather than queueing them" do
    hub.publish(:old)
    hub.publish(:new)
    within { expect(hub.wait(0)).to be == [2, :new] }
  end

  it "never blocks the publisher, however many subscribers are parked" do
    waiters = 3.times.map { Async { within(2.0) { hub.wait(0) } } }
    published = false
    Async {
      hub.publish(:frame)
      published = true
    }.wait

    expect(published).to be == true
    waiters.each { |w| expect(w.wait).to be == [1, :frame] }
  end

  # Draining before terminating is what lets a caller publish one frame, close,
  # and read exactly that frame followed by a clean end. It is also the seam
  # that keeps the route test from hanging.
  it "delivers the pending frame first and only then reports the end" do
    hub.publish(:last_words)
    hub.close

    within do
      seq, frame = hub.wait(0)
      expect(frame).to be == :last_words
      expect(hub.wait(seq)).to be_nil
    end
  end

  it "unparks a waiting subscriber when it closes" do
    waiter = Async { within(2.0) { hub.wait(0) } }
    Async { hub.close }.wait

    expect(waiter.wait).to be_nil
  end

  # An SSE fiber blocked here at shutdown must run its ensure, or a browser tab
  # left open holds `systemctl restart naaf` until it gives up and SIGKILLs.
  it "lets a parked subscriber be stopped, and its ensure still runs" do
    ran = false
    waiter = Async do
      hub.wait(0)
    ensure
      ran = true
    end

    Async { waiter.stop }.wait
    expect(ran).to be == true
  end
end
