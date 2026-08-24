# frozen_string_literal: true

require_relative "helper"
require "json"
require "naaf/warp"

describe Naaf::Warp do
  def fixture
    {
      "id" => "device-id",
      "token" => "TOKEN-MUST-NOT-BE-KEPT",
      "account" => {"license" => "LICENSE-MUST-NOT-BE-KEPT"},
      "config" => {
        "peers" => [{
          "public_key" => "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0KeGh6gWfdRcDsY=",
          "endpoint" => {
            "host" => "engage.cloudflareclient.com:2408",
            "v4" => "162.159.192.1:2408",
            "v6" => "[2606:4700:d0::a29f:c001]:2408"
          }
        }],
        "interface" => {
          "addresses" => {
            "v4" => "172.16.0.2",
            "v6" => "2606:4700:110:8f81:5ee:8e43:880:2fc"
          }
        }
      }
    }
  end

  def parse(hash = fixture) = Naaf::Warp.parse(JSON.generate(hash))

  it "parses a fixture response: peer key, hostname endpoint, IPv4 address" do
    result = parse
    expect(result.pubkey).to be == "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0KeGh6gWfdRcDsY="
    expect(result.endpoint).to be == "engage.cloudflareclient.com:2408"
    expect(result.address).to be == "172.16.0.2"
  end

  it "strips a prefix from the assigned IPv4 and ignores IPv6" do
    hash = fixture
    hash["config"]["interface"]["addresses"]["v4"] = "172.16.0.2/32"
    result = parse(hash)
    expect(result.address).to be == "172.16.0.2"
    expect(result.to_h.keys).not.to be(:include?, :v6)
  end

  it "does not persist a token or license" do
    result = parse
    dumped = result.to_h.values.join
    expect(dumped.include?("TOKEN")).to be == false
    expect(dumped.include?("LICENSE")).to be == false
    expect(result.members).not.to be(:include?, :token)
  end

  it "raises when the peer key, endpoint or address is missing" do
    [
      ->(h) { h["config"]["peers"][0]["public_key"] = nil },
      ->(h) { h["config"]["peers"][0]["endpoint"]["host"] = nil },
      ->(h) { h["config"]["interface"]["addresses"]["v4"] = nil }
    ].each do |edit|
      hash = fixture
      edit.call(hash)
      expect { parse(hash) }.to raise_exception(Naaf::Warp::Error)
    end
  end

  it "sends CF-Client-Version and User-Agent with the JSON body" do
    captured = nil
    response = JSON.generate(fixture)
    original = Naaf::Warp.method(:post)
    Naaf::Warp.define_singleton_method(:post) do |uri, headers, body|
      captured = {uri: uri, headers: headers, body: body}
      response
    end
    result = Naaf::Warp.register("OURPUB")
    expect(captured[:uri]).to be == Naaf::Warp::API_URI
    expect(captured[:headers]["CF-Client-Version"]).to be == "a-6.30-3596"
    expect(captured[:headers]["User-Agent"]).to be == "okhttp/3.12.1"
    expect(captured[:headers]["Content-Type"]).to be == "application/json"
    payload = JSON.parse(captured[:body])
    expect(payload["key"]).to be == "OURPUB"
    expect(payload["type"]).to be == "Linux"
    expect(payload["warp_enabled"]).to be == true
    expect(result.address).to be == "172.16.0.2"
  ensure
    Naaf::Warp.define_singleton_method(:post) { |*a, **k, &b| original.call(*a, **k, &b) }
  end
end
