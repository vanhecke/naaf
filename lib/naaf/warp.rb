# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Naaf
  # Cloudflare WARP device registration. Stdlib Net::HTTP, no gem. The API is
  # unofficial and can break — fail loudly, never re-register on boot.
  module Warp
    API_URI = URI("https://api.cloudflareclient.com/v0a737/reg")
    # Pinned next to the path: they version together. The endpoint 403s without
    # CF-Client-Version.
    CLIENT_VERSION = "a-6.30-3596"
    USER_AGENT = "okhttp/3.12.1"
    TIMEOUT = 10

    class Error < StandardError; end
    Result = Data.define(:pubkey, :endpoint, :address)

    def self.request_headers
      {
        "Content-Type" => "application/json",
        "CF-Client-Version" => CLIENT_VERSION,
        "User-Agent" => USER_AGENT
      }
    end

    def self.register(public_key)
      body = JSON.generate({
        "key" => public_key,
        "install_id" => "",
        "warp_enabled" => true,
        "tos" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.000+00:00"),
        "type" => "Linux",
        "locale" => "en_US"
      })
      parse(post(API_URI, request_headers, body))
    end

    def self.parse(raw)
      data = JSON.parse(raw)
      peer = data.dig("config", "peers", 0) || {}
      pubkey = peer["public_key"]
      endpoint = peer.dig("endpoint", "host")
      v4 = data.dig("config", "interface", "addresses", "v4")
      raise Error, "Cloudflare WARP response is missing the peer public key." if blank?(pubkey)
      raise Error, "Cloudflare WARP response is missing the peer endpoint." if blank?(endpoint)
      raise Error, "Cloudflare WARP response is missing the assigned IPv4 address." if blank?(v4)
      Result.new(
        pubkey: pubkey.to_s,
        endpoint: endpoint.to_s,
        address: v4.to_s.split("/", 2).first
      )
    rescue JSON::ParserError
      raise Error, "Cloudflare WARP returned invalid JSON."
    end

    def self.post(uri, headers, body)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      req = Net::HTTP::Post.new(uri.request_uri)
      headers.each { |k, v| req[k] = v }
      req.body = body
      res = http.request(req)
      unless res.is_a?(Net::HTTPSuccess)
        raise Error, "Cloudflare WARP registration failed (HTTP #{res.code})."
      end
      res.body
    rescue Error
      raise
    rescue Net::OpenTimeout, Net::ReadTimeout
      raise Error, "Cloudflare WARP registration timed out."
    rescue SystemCallError, SocketError => e
      raise Error, "Cloudflare WARP registration failed (#{e.class})."
    end

    def self.blank?(value)
      value.nil? || value == "null" || value.to_s.strip.empty?
    end
    private_class_method :blank?
  end
end
