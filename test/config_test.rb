# frozen_string_literal: true

require_relative "helper"
require "naaf/config"

CONF_EXAMPLE = File.expand_path("../naaf.conf.example", __dir__)

describe Naaf::Config do
  # The grammar naaf.conf.example must stay inside is the intersection of three
  # consumers: systemd EnvironmentFile=, `set -a; . file`, and Config.parse.
  # bin/ci proves the shell half by sourcing the file; this proves the systemd
  # half, which has no cheap runtime check.
  it "keeps naaf.conf.example inside the grammar all three consumers share" do
    grammar = /\A[A-Z][A-Z0-9_]*=(?:'[^'\n]*'|[^'\s]*)\n?\z/
    offenders = File.readlines(CONF_EXAMPLE).each_with_index.filter_map { |line, i|
      next if line.strip.empty? || line.start_with?("#")
      "#{i + 1}: #{line.chomp}" unless grammar.match?(line)
    }
    expect(offenders).to be(:empty?)
  end

  it "documents every key it defines, and defines every key it documents" do
    documented = Naaf::Config.parse(File.read(CONF_EXAMPLE)).keys
    missing = Naaf::Config::DEFAULTS.keys - documented - Naaf::Config::OPTIONAL
    extra = documented - Naaf::Config::DEFAULTS.keys
    expect(missing).to be(:empty?)
    expect(extra).to be(:empty?)
  end

  it "never grows a require, because bin/naaf-helper loads it as root" do
    src = File.read(File.expand_path("../lib/naaf/config.rb", __dir__))
    expect(src.lines.grep(/^\s*require/)).to be(:empty?)
  end

  describe ".parse" do
    it "reads plain assignments and ignores comments and blank lines" do
      out = Naaf::Config.parse("# a comment\n\nNAAF_A=1\nNAAF_B=two\n")
      expect(out).to be == {"NAAF_A" => "1", "NAAF_B" => "two"}
    end

    it "strips one layer of single quotes and trailing whitespace" do
      out = Naaf::Config.parse("NAAF_A='a b'\nNAAF_B=c   \n")
      expect(out["NAAF_A"]).to be == "a b"
      expect(out["NAAF_B"]).to be == "c"
    end

    it "keeps everything after the first = so a value may contain one" do
      expect(Naaf::Config.parse("NAAF_A=k=v\n")["NAAF_A"]).to be == "k=v"
    end

    it "tolerates a leading export even though the file must not use one" do
      expect(Naaf::Config.parse("export NAAF_A=1\n")["NAAF_A"]).to be == "1"
    end

    it "reads an empty assignment as empty, which resolves to the default" do
      expect(Naaf::Config.parse("NAAF_A=\n")).to be == {"NAAF_A" => ""}
    end
  end

  describe "precedence" do
    def with_conf(text)
      Dir.mktmpdir("naaf-conf-") do |dir|
        path = File.join(dir, "naaf.conf")
        File.write(path, text)
        prev_conf = ENV["NAAF_CONF"]
        ENV["NAAF_CONF"] = path
        Naaf::Config.reset!
        yield
      ensure
        ENV["NAAF_CONF"] = prev_conf
        Naaf::Config.reset!
      end
    end

    it "prefers the environment over the file, and the file over the default" do
      with_conf("NAAF_DNS_DOMAIN=fromfile\n") do
        expect(Naaf::Config["NAAF_DNS_DOMAIN"]).to be == "fromfile"
        prev = ENV["NAAF_DNS_DOMAIN"]
        ENV["NAAF_DNS_DOMAIN"] = "fromenv"
        expect(Naaf::Config["NAAF_DNS_DOMAIN"]).to be == "fromenv"
        ENV["NAAF_DNS_DOMAIN"] = prev
      end
      expect(Naaf::Config["NAAF_DNS_DOMAIN"]).to be == "vpn"
    end

    it "treats an empty value in the file as unset" do
      with_conf("NAAF_DNS_DOMAIN=\n") do
        expect(Naaf::Config["NAAF_DNS_DOMAIN"]).to be == "vpn"
      end
    end

    it "is not an error for the file to be missing — systemd already loaded it" do
      prev = ENV["NAAF_CONF"]
      ENV["NAAF_CONF"] = "/nonexistent/naaf.conf"
      Naaf::Config.reset!
      expect(Naaf::Config["NAAF_DNS_DOMAIN"]).to be == "vpn"
      ENV["NAAF_CONF"] = prev
      Naaf::Config.reset!
    end

    it "raises on a key it does not define, rather than returning nil" do
      expect { Naaf::Config["NAAF_TYPO"] }.to raise_exception(KeyError)
    end

    it "raises from fetch! when a required key has no value" do
      expect { Naaf::Config.fetch!("NAAF_ENDPOINT_HOST") }.to raise_exception(KeyError)
    end
  end

  describe "coercion" do
    it "reads integers and booleans" do
      expect(Naaf::Config.int("NAAF_WEB_PORT")).to be == 8080
      expect(Naaf::Config.bool("NAAF_BACKUP_ENABLED")).to be == false # forced off in test/helper.rb
      expect(Naaf::Config.bool("NAAF_LITESTREAM_ENABLED")).to be == false
    end
  end

  # The one duplication this design cannot remove: db/schema.rb column defaults
  # and Config::DEFAULTS both describe "the out-of-the-box value". Changing the
  # schema is an AGENTS.md "Ask first", so instead of collapsing them we pin them
  # together — drift fails here rather than in production.
  it "keeps the naaf.conf seeds and the schema column defaults in lock-step" do
    s = reset_db![:settings].first
    mismatches = Naaf::Config::SEEDS.filter_map { |col, key|
      want = Naaf::Config::DEFAULTS.fetch(key)
      have = s[col].to_s
      "#{key}: schema=#{have.inspect} config=#{want.inspect}" unless have == want
    }
    expect(mismatches).to be(:empty?)
  end

  describe ".drift" do
    it "is silent when the settings row matches the config" do
      expect(Naaf::Config.drift(reset_db![:settings].first)).to be(:empty?)
    end

    it "reports the column, the config value, and the database value" do
      settings = reset_db!(dns_domain: "internal")[:settings].first
      drift = Naaf::Config.drift(settings)
      expect(drift.size).to be == 1
      expect(drift.first).to be == {key: "NAAF_DNS_DOMAIN", conf: "vpn", db: "internal"}
    end

    # bootstrap writes the NIC it detected, so this disagrees with the naaf.conf
    # placeholder on nearly every cloud box. Warning about it every boot is how a
    # drift warning stops being read.
    it "stays quiet about the WAN interface, which bootstrap detects" do
      settings = reset_db!(wan_interface: "enp1s0")[:settings].first
      expect(Naaf::Config.drift(settings)).to be(:empty?)
    end

    # The case drift exists for: the helper takes wg_interface from naaf.conf
    # while the renderers take it from the database, so a half-finished rename
    # points nft at one interface and wg syncconf at another, silently.
    it "still reports a wg_interface disagreement, the failure it exists to catch" do
      settings = reset_db!(wg_interface: "wg1")[:settings].first
      expect(Naaf::Config.drift(settings).map { |d| d[:key] }).to be == ["NAAF_WG_INTERFACE"]
    end
  end
end
