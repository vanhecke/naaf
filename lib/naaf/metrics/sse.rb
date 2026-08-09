# frozen_string_literal: true

module Naaf
  module Metrics
    # Server-sent event framing. A pure function, tested byte for byte.
    module SSE
      module_function

      # The first newline in a `data:` line TERMINATES the event — the rest of
      # the payload is then read as garbage field lines and silently dropped. An
      # HTML fragment is full of newlines, so every line gets its own `data:`
      # and the client rejoins them with "\n". Getting this wrong produces a
      # page that swaps in the first line of each panel and nothing else.
      def frame(data, event: nil)
        out = +""
        out << "event: #{event}\n" if event
        lines = data.to_s.split(/\r\n|\r|\n/)
        lines = [""] if lines.empty?
        lines.each { |line| out << "data: #{line}\n" }
        out << "\n"
      end

      # Sent once at the top of a stream. Milliseconds, and it only tunes the
      # browser's own EventSource reconnect — the htmx extension's backoff after
      # the browser gives up is fixed and not configurable from the server.
      def retry_after(ms) = "retry: #{ms.to_i}\n\n"

      # A comment frame. Not needed as a keep-alive here because the collector
      # publishes every tick whether or not anything changed, but it is the
      # cheapest way to write something at a moment when there is no snapshot.
      def comment(text) = ": #{text}\n\n"
    end
  end
end
