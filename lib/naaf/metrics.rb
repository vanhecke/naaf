# frozen_string_literal: true

require_relative "metrics/num"
require_relative "metrics/series"
require_relative "metrics/proc_fs"
require_relative "metrics/dns_stats"
require_relative "metrics/peer_stats"
require_relative "metrics/snapshot"
require_relative "metrics/hub"
require_relative "metrics/sse"
require_relative "metrics/collector"

module Naaf
  # In-memory observability for the dashboard at /.
  #
  # Nothing in here is persisted. There is no metrics table and there must not
  # be one: naaf.db is configuration truth, and a high-frequency table in it
  # would multiply the WAL churn Litestream replicates to the object store.
  # History resets when the process restarts, and that is the deal.
  #
  # The names of the fragments the dashboard is built from. It doubles as the
  # whitelist for GET /metrics/<name> — without it that route is a template
  # path traversal — and as the list of SSE event names.
  module Metrics
    FRAGMENTS = %w[health kpis pipeline clients dns interfaces policy app].freeze

    # `policy` is the network's configuration — subnet, endpoint, rule counts —
    # and changes only when the admin changes it, so it is rendered once with
    # the page and left alone. Swapping it every couple of seconds would destroy
    # text selection, keyboard focus and browser find-highlighting inside it for
    # no new information. It stays in FRAGMENTS so the polling fallback and its
    # own GET route still work.
    LIVE_FRAGMENTS = (FRAGMENTS - %w[policy]).freeze
  end
end
