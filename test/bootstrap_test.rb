# frozen_string_literal: true

require_relative "helper"
require "bcrypt"
require "wgcp/bootstrap"

describe WGCP::Bootstrap do
  # Set/restore env vars around a block so cases don't leak into each other
  # (sus runs sequentially in one process).
  def with_env(**pairs)
    old = pairs.keys.to_h { |k| [k, ENV[k.to_s]] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k.to_s) : (ENV[k.to_s] = v) }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k.to_s) : (ENV[k.to_s] = v) }
  end

  def stub_keys = {private_key: "PRIV", public_key: "PUB", preshared_key: "PSK"}

  it "reads the admin password from WGCP_ADMIN_PASSWORD when set" do
    with_env(WGCP_ADMIN_PASSWORD: "  fromenv  ") do
      pw = WGCP::Bootstrap.admin_password(prompt: -> { raise "should not prompt" })
      expect(pw).to be == "fromenv"
    end
  end

  it "falls back to the interactive prompt when the env var is unset" do
    with_env(WGCP_ADMIN_PASSWORD: nil) do
      pw = WGCP::Bootstrap.admin_password(prompt: -> { "typed\n" })
      expect(pw).to be == "typed"
    end
  end

  it "raises when neither the env var nor a prompt is available" do
    with_env(WGCP_ADMIN_PASSWORD: nil) do
      expect { WGCP::Bootstrap.admin_password }.to raise_exception(RuntimeError)
    end
  end

  it "reads the endpoint host from the env, or nil when blank/unset" do
    with_env(WGCP_ENDPOINT_HOST: "sg.example.com") do
      expect(WGCP::Bootstrap.endpoint_host).to be == "sg.example.com"
    end
    with_env(WGCP_ENDPOINT_HOST: "   ") do
      expect(WGCP::Bootstrap.endpoint_host).to be_nil
    end
    with_env(WGCP_ENDPOINT_HOST: nil) do
      expect(WGCP::Bootstrap.endpoint_host).to be_nil
    end
  end

  it "persists keys, a hashed password, and network facts" do
    db = reset_db!
    WGCP::Bootstrap.persist!(db, keys: stub_keys, password: "s3cret",
      endpoint_v4: "203.0.113.7", endpoint_v6: "2001:db8::7", wan_interface: "ens3")
    s = db[:settings].first
    expect(s[:server_privkey]).to be == "PRIV"
    expect(s[:server_pubkey]).to be == "PUB"
    expect(s[:endpoint_v4]).to be == "203.0.113.7"
    expect(s[:wan_interface]).to be == "ens3"
    expect(BCrypt::Password.new(s[:admin_pw_hash]) == "s3cret").to be == true
  end

  it "writes endpoint_host only when provided" do
    db = reset_db!
    WGCP::Bootstrap.persist!(db, keys: stub_keys, password: "pw",
      endpoint_v4: "203.0.113.7", endpoint_v6: nil, wan_interface: "ens3")
    expect(db[:settings].first[:endpoint_host]).to be_nil

    WGCP::Bootstrap.persist!(db, keys: stub_keys, password: "pw", endpoint_host: "sg.example.com",
      endpoint_v4: "203.0.113.7", endpoint_v6: nil, wan_interface: "ens3")
    expect(db[:settings].first[:endpoint_host]).to be == "sg.example.com"
  end
end
