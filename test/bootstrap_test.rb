# frozen_string_literal: true

require_relative "helper"
require "bcrypt"
require "naaf/bootstrap"

describe Naaf::Bootstrap do
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

  it "reads the admin password from NAAF_ADMIN_PASSWORD when set" do
    with_env(NAAF_ADMIN_PASSWORD: "  fromenv  ") do
      pw = Naaf::Bootstrap.admin_password(prompt: -> { raise "should not prompt" })
      expect(pw).to be == "fromenv"
    end
  end

  it "falls back to the interactive prompt when the env var is unset" do
    with_env(NAAF_ADMIN_PASSWORD: nil) do
      pw = Naaf::Bootstrap.admin_password(prompt: -> { "typed\n" })
      expect(pw).to be == "typed"
    end
  end

  it "raises when neither the env var nor a prompt is available" do
    with_env(NAAF_ADMIN_PASSWORD: nil) do
      expect { Naaf::Bootstrap.admin_password }.to raise_exception(RuntimeError)
    end
  end

  it "reads the endpoint host from the env, or nil when blank/unset" do
    with_env(NAAF_ENDPOINT_HOST: "sg.example.com") do
      expect(Naaf::Bootstrap.endpoint_host).to be == "sg.example.com"
    end
    with_env(NAAF_ENDPOINT_HOST: "   ") do
      expect(Naaf::Bootstrap.endpoint_host).to be_nil
    end
    with_env(NAAF_ENDPOINT_HOST: nil) do
      expect(Naaf::Bootstrap.endpoint_host).to be_nil
    end
  end

  it "persists keys, a hashed password, and network facts" do
    db = reset_db!
    Naaf::Bootstrap.persist!(db, keys: stub_keys, password: "s3cret",
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
    Naaf::Bootstrap.persist!(db, keys: stub_keys, password: "pw",
      endpoint_v4: "203.0.113.7", endpoint_v6: nil, wan_interface: "ens3")
    expect(db[:settings].first[:endpoint_host]).to be_nil

    Naaf::Bootstrap.persist!(db, keys: stub_keys, password: "pw", endpoint_host: "sg.example.com",
      endpoint_v4: "203.0.113.7", endpoint_v6: nil, wan_interface: "ens3")
    expect(db[:settings].first[:endpoint_host]).to be == "sg.example.com"
  end

  describe ".seed_settings!" do
    it "writes only the values that differ from the built-in defaults" do
      db = reset_db!
      with_env(NAAF_DNS_DOMAIN: "internal", NAAF_MTU: "1380") do
        Naaf::Config.reset!
        seeded = Naaf::Bootstrap.seed_settings!(db)
        expect(seeded.keys.sort).to be == [:dns_domain, :mtu]
      end
      Naaf::Config.reset!
      s = db[:settings].first
      expect(s[:dns_domain]).to be == "internal"
      expect(s[:mtu]).to be == 1380
      expect(s[:wg_subnet]).to be == "10.8.0.0/24" # untouched: matches the default
    end

    it "is a no-op when nothing has been customized" do
      db = reset_db!
      expect(Naaf::Bootstrap.seed_settings!(db)).to be(:empty?)
      expect(db[:settings].first[:dns_domain]).to be == "vpn"
    end
  end

  # The migration path: a restored database carries these three across from the
  # old box, where they are wrong. See docs/BACKUP.md.
  describe ".refresh_network!" do
    it "updates the box-specific facts and nothing else" do
      db = reset_db!
      Naaf::Bootstrap.persist!(db, keys: stub_keys, password: "pw", endpoint_host: "vpn.example.com",
        endpoint_v4: "203.0.113.7", endpoint_v6: nil, wan_interface: "ens3")

      Naaf::Bootstrap.refresh_network!(db,
        endpoint_v4: "203.0.113.99", endpoint_v6: "2001:db8::99", wan_interface: "enp1s0")

      s = db[:settings].first
      expect(s[:endpoint_v4]).to be == "203.0.113.99"
      expect(s[:endpoint_v6]).to be == "2001:db8::99"
      expect(s[:wan_interface]).to be == "enp1s0"
      # The whole point of the migration is that these survive.
      expect(s[:server_privkey]).to be == "PRIV"
      expect(s[:server_pubkey]).to be == "PUB"
      expect(s[:endpoint_host]).to be == "vpn.example.com"
      expect(BCrypt::Password.new(s[:admin_pw_hash]) == "pw").to be == true
    end

    it "leaves a stored value alone rather than clobbering it with a blank" do
      db = reset_db!
      Naaf::Bootstrap.persist!(db, keys: stub_keys, password: "pw",
        endpoint_v4: "203.0.113.7", endpoint_v6: "2001:db8::7", wan_interface: "ens3")

      # v6 detection commonly returns "" on a v4-only host.
      Naaf::Bootstrap.refresh_network!(db,
        endpoint_v4: "203.0.113.99", endpoint_v6: "", wan_interface: "  ")

      s = db[:settings].first
      expect(s[:endpoint_v4]).to be == "203.0.113.99"
      expect(s[:endpoint_v6]).to be == "2001:db8::7"
      expect(s[:wan_interface]).to be == "ens3"
    end
  end

  describe ".detect_public_ip" do
    it "returns the first valid address it gets" do
      ip = Naaf::Bootstrap.detect_public_ip(4,
        resolvers: ["a", "b"], runner: ->(_) { "203.0.113.5\n" })
      expect(ip).to be == "203.0.113.5"
    end

    # A brand-new box's first boot is exactly when one service is having a bad
    # day, and a blank endpoint_v4 produces client configs that cannot connect.
    it "falls through to the next service when one fails or lies" do
      seen = []
      runner = lambda do |url|
        seen << url
        (url == "good") ? "203.0.113.5" : ""
      end
      ip = Naaf::Bootstrap.detect_public_ip(4, resolvers: ["bad", "good"], runner: runner)
      expect(ip).to be == "203.0.113.5"
      expect(seen.first).to be == "bad"
    end

    it "rejects a response of the wrong family or a non-address" do
      expect(Naaf::Bootstrap.detect_public_ip(4,
        resolvers: ["x"], runner: ->(_) { "2001:db8::1" })).to be == ""
      expect(Naaf::Bootstrap.detect_public_ip(4,
        resolvers: ["x"], runner: ->(_) { "<html>error</html>" })).to be == ""
    end

    it "returns empty rather than a bad value when every service fails" do
      expect(Naaf::Bootstrap.detect_public_ip(6,
        resolvers: ["a", "b"], runner: ->(_) { "" })).to be == ""
    end
  end
end
