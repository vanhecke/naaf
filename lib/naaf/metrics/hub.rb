# frozen_string_literal: true

require "async/notification"

module Naaf
  module Metrics
    # One process-wide slot, one edge-triggered notification, one sequence
    # number. Every open dashboard tab waits on the same Hub.
    #
    # There is deliberately NO per-subscriber registry and no per-subscriber
    # queue. A registry is a thing entries can leak into when a browser vanishes
    # without closing cleanly; with nothing to register, that whole class of bug
    # does not exist. A queue would also buffer stale frames for a slow client,
    # and a monitoring stream wants the newest sample, never a backlog — so this
    # is deliberately lossy: a subscriber busy writing when a tick lands simply
    # picks up the newer frame on its next wait.
    #
    # The sequence number is what makes that safe. Async::Notification#signal
    # only wakes fibers already waiting, so a subscriber that was mid-render
    # when a tick landed would sleep until the tick after next. Comparing
    # sequences instead of relying on the wakeup closes that hole.
    class Hub
      def initialize
        @sequence = 0
        @snapshot = nil
        @closed = false
        @notification = Async::Notification.new
      end

      attr_reader :sequence, :snapshot

      def closed? = @closed

      # Collector fiber only. Two assignments and a signal, with no yield
      # between them, so @snapshot and @sequence can never be read out of step.
      # signal never blocks the publisher, however slow the subscribers are.
      def publish(snapshot)
        @snapshot = snapshot
        @sequence += 1
        @notification.signal
        self
      end

      # Returns [sequence, snapshot], or nil once the hub is closed AND the
      # caller has already seen the last frame. Draining before terminating
      # matters: it is what lets a test publish one frame, close, and get
      # exactly one frame followed by a clean end.
      #
      # seen == 0 delivers the current frame immediately, so a tab that connects
      # between ticks paints at once instead of staring at an empty page.
      def wait(seen)
        @notification.wait while @sequence == seen && !@closed
        return nil if @sequence == seen
        [@sequence, @snapshot]
      end

      # Ends every stream. Called at reactor shutdown so open SSE connections
      # cannot hold `systemctl restart naaf` open until it gives up and SIGKILLs
      # the process, possibly mid-VACUUM.
      def close
        @closed = true
        @notification.signal
        self
      end
    end
  end
end
