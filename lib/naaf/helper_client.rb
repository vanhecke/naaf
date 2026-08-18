# frozen_string_literal: true

require "json"
require "socket"
require_relative "config"

module Naaf
  class HelperClient
    class Error < StandardError; end

    def initialize(path = Config["NAAF_HELPER_SOCKET"])
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

    def apply(wg_conf:, nft_ruleset:, routes: [], addresses: [])
      call("apply", wg_conf: wg_conf, nft_ruleset: nft_ruleset,
        routes: routes, addresses: addresses)
    end
  end
end
