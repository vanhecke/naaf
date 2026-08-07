# frozen_string_literal: true

require "erb"

module WGCP
  class ConfigBuilder
    FLAVORS = %w[split split-nodns full].freeze

    def initialize(db, client)
      @db = db
      @client = client
      @s = WGCP.settings
    end

    def render(flavor, private_key: nil)
      raise ArgumentError, "unknown flavor" unless FLAVORS.include?(flavor)
      path = File.expand_path("../../views/conf_#{flavor.tr("-", "_")}.erb", __dir__)
      client = @client
      s = @s
      pk = private_key || "REPLACE_WITH_YOUR_PRIVATE_KEY"
      allowed = allowed_ips(flavor)
      ep = endpoint
      ERB.new(File.read(path), trim_mode: "-").result(binding)
    end

    def allowed_ips(flavor)
      return "0.0.0.0/0" if flavor == "full"
      routes = [@s[:wg_subnet]]
      # NOTE: `where(client_id: [nil, id])` renders as `client_id IN (NULL, id)`,
      # and SQL `IN (NULL, ...)` never matches NULL rows — so the global routes
      # (client_id IS NULL) would be silently dropped. Use an explicit OR.
      routes += @db[:extra_routes]
        .where(Sequel[client_id: nil] | Sequel[client_id: @client[:id]])
        .select_map(:cidr)
      routes.uniq.join(", ")
    end

    def endpoint(family: :v4)
      host = @s[:endpoint_host] || ((family == :v6) ? "[#{@s[:endpoint_v6]}]" : @s[:endpoint_v4])
      "#{host}:#{@s[:listen_port]}"
    end
  end
end
