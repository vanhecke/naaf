# frozen_string_literal: true

require_relative "helper"
require "json"
require "socket"
require "timeout"
require "naaf/helper_client"

describe Naaf::HelperClient do
  def with_socket
    Dir.mktmpdir("naaf-helper-client-") do |dir|
      path = File.join(dir, "helper.sock")
      server = UNIXServer.new(path)
      begin
        yield path, server
      ensure
        server.close
      end
    end
  end

  def serve_one(server, resp)
    Thread.new do
      conn = server.accept
      begin
        req = JSON.parse(conn.gets.to_s)
        conn.puts(JSON.generate(resp.is_a?(Proc) ? resp.call(req) : resp))
      ensure
        conn.close
      end
    end
  end

  it "sends a JSON command and returns the parsed response" do
    with_socket do |path, server|
      thr = serve_one(server, {"ok" => true})
      Timeout.timeout(2) do
        expect(Naaf::HelperClient.new(path).call("ping")).to be == {"ok" => true}
      end
      thr.join
    end
  end

  it "raises HelperClient::Error when the helper reports one" do
    with_socket do |path, server|
      thr = serve_one(server, {"error" => "unknown command"})
      Timeout.timeout(2) do
        expect { Naaf::HelperClient.new(path).call("rm") }
          .to raise_exception(Naaf::HelperClient::Error, message: be == "unknown command")
      end
      thr.join
    end
  end

  it "forwards apply's four fields so an older helper can ignore the extras" do
    seen = nil
    with_socket do |path, server|
      thr = serve_one(server, ->(req) {
        seen = req
        {"ok" => true}
      })
      Timeout.timeout(2) do
        Naaf::HelperClient.new(path).apply(
          wg_conf: "WG", nft_ruleset: "NFT",
          routes: [{dst: "192.168.1.0/24", dev: "wg0"}],
          addresses: [{addr: "192.168.2.2", dev: "wg0"}]
        )
      end
      thr.join
    end
    expect(seen["cmd"]).to be == "apply"
    expect(seen["wg_conf"]).to be == "WG"
    expect(seen["nft_ruleset"]).to be == "NFT"
    expect(seen["routes"]).to be == [{"dst" => "192.168.1.0/24", "dev" => "wg0"}]
    expect(seen["addresses"]).to be == [{"addr" => "192.168.2.2", "dev" => "wg0"}]
  end

  it "returns dump as the raw text, and genkeys with symbol keys" do
    with_socket do |path, server|
      thr = serve_one(server, {"dump" => "LINE\n"})
      Timeout.timeout(2) { expect(Naaf::HelperClient.new(path).dump).to be == "LINE\n" }
      thr.join
    end
    with_socket do |path, server|
      thr = serve_one(server, {"public_key" => "P", "private_key" => "K", "preshared_key" => "S"})
      Timeout.timeout(2) do
        expect(Naaf::HelperClient.new(path).genkeys).to be == {
          public_key: "P", private_key: "K", preshared_key: "S"
        }
      end
      thr.join
    end
  end
end
