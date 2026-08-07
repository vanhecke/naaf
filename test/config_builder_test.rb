# frozen_string_literal: true

require_relative "helper"
require "naaf/config_builder"

describe Naaf::ConfigBuilder do
  before do
    @db = reset_db!(
      server_pubkey: "SRVPUB", server_ip: "10.8.0.1",
      endpoint_v4: "203.0.113.5", endpoint_v6: "2001:db8::5",
      listen_port: 51820, mtu: 1420, wg_subnet: "10.8.0.0/24", dns_domain: "vpn"
    )
    id = make_client(@db, name: "laptop", wg_ip: "10.8.0.2", pubkey: "LAPPUB", psk: "LAPPSK")
    @client = @db[:clients][id: id]
  end

  def build(flavor, **opts)
    Naaf::ConfigBuilder.new(@db, @client).render(flavor, **opts)
  end

  it "split has a DNS line and routes only the vpn subnet" do
    c = build("split")
    expect(c).to be(:include?, "DNS = 10.8.0.1")
    expect(c).to be(:include?, "Endpoint = 203.0.113.5:51820")
    expect(c).to be(:include?, "AllowedIPs = 10.8.0.0/24")
    expect(c.include?("0.0.0.0/0")).to be == false
  end

  it "split-nodns is split without the DNS line" do
    c = build("split-nodns")
    expect(c.include?("DNS =")).to be == false
    expect(c).to be(:include?, "AllowedIPs = 10.8.0.0/24")
  end

  it "full routes 0.0.0.0/0 and never ::/0 (interior is IPv4-only)" do
    c = build("full")
    # Assert on the actual AllowedIPs line — the template's explanatory comment
    # legitimately mentions ::/0, so a bare string search would false-positive.
    expect(c[/^AllowedIPs = .*/]).to be == "AllowedIPs = 0.0.0.0/0"
    expect(c).to be(:include?, "DNS = 10.8.0.1")
  end

  it "uses the placeholder when no private key is supplied" do
    expect(build("split")).to be(:include?, "REPLACE_WITH_YOUR_PRIVATE_KEY")
  end

  it "injects the one-shot private key when supplied, and the DB never stores one" do
    expect(build("split", private_key: "ONESHOTPRIV")).to be(:include?, "PrivateKey = ONESHOTPRIV")
    expect(@db[:clients].columns.include?(:privkey)).to be == false
    expect(@db[:clients].columns.include?(:private_key)).to be == false
  end

  it "folds global and per-client extra routes into split AllowedIPs" do
    @db[:extra_routes].insert(client_id: nil, cidr: "192.168.9.0/24")
    @db[:extra_routes].insert(client_id: @client[:id], cidr: "10.99.0.0/16")
    c = build("split")
    expect(c).to be(:include?, "192.168.9.0/24")
    expect(c).to be(:include?, "10.99.0.0/16")
  end

  it "rejects unknown flavors" do
    expect { build("bogus") }.to raise_exception(ArgumentError, message: be =~ /unknown flavor/)
  end
end
