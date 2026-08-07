# frozen_string_literal: true

require "json"
require "socket"

module WGCP
  class HelperClient
    class Error < StandardError; end

    def initialize(path = ENV.fetch("WGCP_HELPER_SOCKET", "/run/wgcp/helper.sock"))
      @path = path
      @mutex = Mutex.new
    end

    def call(cmd, **args)
      @mutex.synchronize do
        UNIXSocket.open(@path) do |sock|
          sock.puts(JSON.generate({cmd: cmd}.merge(args)))
          resp = JSON.parse(sock.gets.to_s)
          raise Error, resp["error"] if resp["error"]
          resp
        end
      end
    end

    def genkeys = call("genkeys").transform_keys(&:to_sym)
    def dump = call("dump")["dump"]
    def apply(wg_conf:, nft_ruleset:) = call("apply", wg_conf: wg_conf, nft_ruleset: nft_ruleset)
  end
end
