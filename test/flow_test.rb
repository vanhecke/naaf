# frozen_string_literal: true

require_relative "helper"
require "naaf/flow"

# Flow.analyze is pure, so one fixture topology can be driven through every pair
# the box supports without a reactor, a helper or a kernel.
describe Naaf::Flow do
  before do
    @db = reset_db!(server_ip: "10.8.0.1", wg_subnet: "10.8.0.0/24",
      wg_interface: "wg0", wan_interface: "eth0", listen_port: 51820,
      endpoint_v4: "203.0.113.5", dns_domain: "vpn")

    @nas = make_client(@db, name: "nas", wg_ip: "10.8.0.2")
    @pi = make_client(@db, name: "pi", wg_ip: "10.8.0.3")
    @off = make_client(@db, name: "off", wg_ip: "10.8.0.4", enabled: false)
    @db[:exposed_ports].insert(client_id: @nas, proto: "tcp", port: 8000, port_end: 8100)
    @db[:exposed_ports].insert(client_id: @nas, proto: "udp", port: 53, port_end: nil)
    @db[:port_forwards].insert(client_id: @nas, proto: "tcp",
      public_port: 8443, target_port: 443, enabled: true)

    @room = make_site(@db, name: "room", pubkey: "SITE-room", networks: ["192.168.1.0/24"])
    @dark = make_site(@db, name: "dark", pubkey: "SITE-dark", enabled: false,
      networks: ["192.168.9.0/24"])
    @bare = make_site(@db, name: "bare", pubkey: "SITE-bare", networks: [])
    @db[:extra_routes].insert(client_id: nil, cidr: "10.50.0.0/16")
  end

  def run(src, dst, proto = "tcp", dport = 443)
    Naaf::Flow.analyze(@db, src: src, dst: dst, proto: proto, dport: dport)
  end

  def stage(report, name) = report.steps.find { |s| s.stage == name }

  def rules(report) = report.steps.filter_map(&:rule).join("\n")

  describe "classification" do
    it "names the hub, a client, a site LAN, an extra route and the internet" do
      kinds = {
        "10.8.0.1" => :hub, "10.8.0.2" => :client, "192.168.1.5" => :site,
        "10.50.0.9" => :extra, "10.8.0.99" => :vpn_unassigned, "8.8.8.8" => :internet
      }
      kinds.each do |ip, kind|
        expect(Naaf::Flow.classify(@db, ip).kind).to be == kind
      end
    end

    # A disabled site still owns its addresses. Falling through to :internet
    # would invent a WAN egress path the packet never takes, and hide the one
    # fact the operator needs.
    it "still attributes a disabled site's LAN to that site" do
      ep = Naaf::Flow.classify(@db, "192.168.9.5")
      expect(ep.kind).to be == :site
      expect(ep.enabled).to be == false
      expect(ep.row[:name]).to be == "dark"
    end

    # A site network is the more specific role: it installs a hub route, where
    # an extra route does not.
    it "prefers a site network over an extra route covering the same address" do
      @db[:extra_routes].insert(client_id: nil, cidr: "192.168.1.0/24")
      expect(Naaf::Flow.classify(@db, "192.168.1.5").kind).to be == :site
    end
  end

  describe "an address no peer owns" do
    it "stops before anything else runs, from either side" do
      report = run("10.8.0.3", "10.8.0.99")
      expect(report.verdict).to be == :fail
      expect(stage(report, "Destination address").detail).to be(:include?, "no client holds it")
      expect(report.steps.size).to be == 2

      expect(stage(run("10.8.0.99", "10.8.0.2"), "Source address")).not.to be_nil
    end
  end

  describe "client to client" do
    # The tester's only real acceptance criterion: the boundary of an exposed
    # range has to move with the range.
    it "passes a port inside an exposed range and fails one just outside it" do
      expect(run("10.8.0.3", "10.8.0.2", "tcp", 8000).verdict).to be == :pass
      expect(run("10.8.0.3", "10.8.0.2", "tcp", 8100).verdict).to be == :pass
      expect(run("10.8.0.3", "10.8.0.2", "tcp", 7999).verdict).to be == :fail
      expect(run("10.8.0.3", "10.8.0.2", "tcp", 8101).verdict).to be == :fail
    end

    # NULL port_end means "ends where it starts" -- the reading every other
    # consumer of this table uses.
    it "reads a NULL port_end as a single port" do
      expect(run("10.8.0.3", "10.8.0.2", "udp", 53).verdict).to be == :pass
      expect(run("10.8.0.3", "10.8.0.2", "udp", 54).verdict).to be == :fail
    end

    it "does not let a tcp range open the same udp port" do
      expect(run("10.8.0.3", "10.8.0.2", "udp", 8050).verdict).to be == :fail
    end

    it "quotes the deciding line and links the page that would change it" do
      blocked = run("10.8.0.3", "10.8.0.2", "tcp", 22)
      step = stage(blocked, "Forward chain")
      expect(step.rule).to be == %(iifname "wg0" oifname "wg0" counter drop)
      expect(step.fix).to be == "/exposed-ports"

      allowed = stage(run("10.8.0.3", "10.8.0.2", "tcp", 8050), "Forward chain")
      expect(allowed.rule).to be(:include?, "ip daddr . tcp dport @vpn_tcp_allow accept")
    end

    # Rule 2 of the forward chain sits above both port sets, so a successful
    # ping says nothing at all about whether a port is open.
    it "passes ICMP regardless of any exposed port" do
      report = Naaf::Flow.analyze(@db, src: "10.8.0.3", dst: "10.8.0.2",
        proto: "icmp", dport: nil)
      expect(report.verdict).to be == :pass
      expect(stage(report, "Forward chain").rule).to be(:include?, "icmp type echo-request accept")
    end

    it "blames the source peer when the sender is disabled" do
      report = run("10.8.0.4", "10.8.0.2", "tcp", 8050)
      expect(report.verdict).to be == :fail
      expect(stage(report, "Source peer").detail).to be(:include?, "is disabled")
    end

    it "blames cryptokey routing when the destination is disabled" do
      @db[:exposed_ports].insert(client_id: @off, proto: "tcp", port: 22, port_end: 22)
      report = run("10.8.0.3", "10.8.0.4", "tcp", 22)
      expect(report.verdict).to be == :fail
      expect(stage(report, "Cryptokey routing").detail).to be(:include?, "is disabled")
    end
  end

  describe "client to a site LAN" do
    it "reports the route, the peer and the forward rule" do
      report = run("10.8.0.3", "192.168.1.5")
      expect(report.verdict).to be == :pass
      expect(stage(report, "Hub route").rule)
        .to be == "ip route replace 192.168.1.0/24 dev wg0 proto 158"
      expect(rules(report)).to be(:include?, "ip daddr @site_nets accept")
      # The half naaf cannot see is stated, never guessed.
      expect(stage(report, "The remote end").detail).to be(:include?, "naaf cannot see this")
    end

    it "reports both route sets, because which config was installed decides it" do
      report = run("10.8.0.3", "192.168.1.5")
      %w[split full].each do |flavor|
        step = stage(report, "Client AllowedIPs (#{flavor})")
        expect(step.detail).to be(:include?, "routes 192.168.1.5 to the hub")
        # Context, not a verdict: one report has a single source address and no
        # way to know which of five configs is on it.
        expect(step.verdict).to be == :info
      end
    end

    it "fails on a disabled site before it looks at anything else" do
      report = run("10.8.0.3", "192.168.9.5")
      expect(report.verdict).to be == :fail
      expect(stage(report, "Site peer").detail).to be(:include?, "not in @site_nets")
      expect(stage(report, "Hub route")).to be_nil
    end

    it "warns about masquerade rewriting the source address" do
      @db[:sites].where(id: @room).update(masquerade: true, address: "192.168.1.250")
      report = run("10.8.0.3", "192.168.1.5")
      expect(report.verdict).to be == :warn
      expect(stage(report, "Source address").rule).to be(:include?, "snat to 192.168.1.250")
    end
  end

  # A site with no networks has no addresses to classify, so it is reached
  # through the destination it would have owned: nothing routes there.
  describe "a site with no networks" do
    it "is not a peer, so its would-be LAN is not a site destination" do
      @db[:site_networks].insert(site_id: @bare, cidr: "172.16.0.0/24")
      report = run("10.8.0.3", "172.16.0.5")
      expect(stage(report, "Site peer")).to be_nil # it has a network again

      @db[:site_networks].where(site_id: @bare).delete
      expect(Naaf::Flow.classify(@db, "172.16.0.5").kind).to be == :internet
    end
  end

  describe "site to client" do
    it "accepts on the saddr rule, not on an exposed port" do
      report = run("192.168.1.5", "10.8.0.2", "tcp", 22)
      expect(report.verdict).to be == :pass
      expect(stage(report, "Forward chain").rule).to be(:include?, "ip saddr @site_nets accept")
    end
  end

  describe "an extra-route-only destination" do
    # extra_routes widen AllowedIPs and install no hub route, so the packet
    # arrives and leaves again by the WAN. Almost never the intent.
    it "warns that the packet leaves by the WAN instead of a tunnel" do
      report = run("10.8.0.3", "10.50.0.9")
      expect(report.verdict).to be == :warn
      step = stage(report, "Hub route")
      expect(step.detail).to be(:include?, "installs nothing on the hub")
      expect(step.rule).to be == %(ip saddr 10.8.0.0/24 oifname "eth0" masquerade)
      expect(step.fix).to be == "/sites"
    end
  end

  describe "client to the internet" do
    it "says full routes it and split does not" do
      report = run("10.8.0.3", "8.8.8.8")
      expect(stage(report, "Client AllowedIPs (full)").detail)
        .to be(:include?, "routes 8.8.8.8 to the hub")
      expect(stage(report, "Client AllowedIPs (split)").detail)
        .to be(:include?, "blackhole on the laptop")
    end

    # `split` correctly does not route 0.0.0.0/0, and analyze takes the worst
    # step -- so scoring that miss as :fail called every ordinary client query
    # for a public address BLOCKED.
    it "is not BLOCKED just because one flavor does not route it" do
      report = run("10.8.0.3", "8.8.8.8")
      expect(report.verdict).to be == :pass
      expect(stage(report, "Egress").verdict).to be == :pass
      expect(Naaf::Flow::CHIP[report.verdict]).to be == "REACHABLE"
    end
  end

  describe "internet to a client" do
    it "reports the public port, which is not the one that was asked about" do
      report = run("203.0.113.9", "10.8.0.2", "tcp", 443)
      expect(report.verdict).to be == :pass
      expect(stage(report, "DNAT").detail).to be(:include?, "PUBLIC port 8443")
      expect(rules(report)).to be(:include?, "ct status dnat accept")
    end

    # The forward chain's policy is accept, so "allow" would be a true statement
    # about the wrong thing.
    it "explains that there is no route to a private address, not a drop" do
      report = run("203.0.113.9", "10.8.0.2", "tcp", 22)
      expect(report.verdict).to be == :fail
      expect(stage(report, "DNAT").detail).to be(:include?, "no route to it at all")
    end

    it "refuses to pretend a site LAN can be port-forwarded" do
      report = run("203.0.113.9", "192.168.1.5")
      expect(report.verdict).to be == :fail
      expect(stage(report, "Inbound").detail).to be(:include?, "no DNAT to a site LAN")
    end
  end

  describe "the hub itself" do
    it "answers UNKNOWN, because inet filter is not this application's table" do
      report = run("10.8.0.3", "10.8.0.1", "udp", 53)
      expect(report.verdict).to be == :unknown
      expect(stage(report, "Base firewall").detail).to be(:include?, "never writes")
      expect(stage(report, "From the tunnel").rule).to be == %(iifname "wg0" accept)
    end

    it "names the WAN ports the base template opens" do
      expect(stage(run("203.0.113.9", "10.8.0.1", "tcp", 22), "From the WAN").detail)
        .to be(:include?, "SSH")
      expect(stage(run("203.0.113.9", "10.8.0.1", "udp", 51820), "From the WAN").detail)
        .to be(:include?, "WireGuard")
      expect(stage(run("203.0.113.9", "10.8.0.1", "tcp", 80), "From the WAN").detail)
        .to be(:include?, "counter drop")
    end

    # The forwarded-DNS path: the hub originates the query itself.
    it "walks a query the hub sends to a site resolver" do
      report = run("10.8.0.1", "192.168.1.53", "udp", 53)
      expect(report.verdict).to be == :pass
      expect(stage(report, "From the hub").rule).to be(:include?, "policy accept")
      expect(stage(report, "Hub route")).not.to be_nil
      expect(stage(report, "Forward chain").detail)
        .to be(:include?, "does not traverse the forward hook")
    end
  end

  # The Troubleshoot page's own ping originates here, so this path is reached by
  # accident as much as on purpose. It goes over the tunnel; reporting it as WAN
  # egress -- and never reading the client's enabled flag -- was wrong twice.
  describe "the hub reaching a client" do
    it "routes over the tunnel, not out of the WAN" do
      report = run("10.8.0.1", "10.8.0.2", "icmp", nil)
      expect(report.verdict).to be == :pass
      expect(stage(report, "Cryptokey routing").rule)
        .to be == "[Peer] AllowedIPs = 10.8.0.2/32"
      expect(stage(report, "Delivery")).to be_nil
      expect(rules(report)).not.to be(:include?, "eth0")
      # The hub originates it, so the forward hook never sees it.
      expect(stage(report, "Forward chain").detail)
        .to be(:include?, "does not traverse the forward hook")
    end

    it "fails when the client is disabled, instead of claiming WAN egress" do
      report = run("10.8.0.1", "10.8.0.4", "icmp", nil)
      expect(report.verdict).to be == :fail
      expect(stage(report, "Cryptokey routing").detail).to be(:include?, "is disabled")
    end

    it "still leaves by the WAN for an address nothing routes" do
      report = run("10.8.0.1", "8.8.8.8", "tcp", 443)
      expect(stage(report, "Delivery").detail).to be(:include?, "eth0")
    end
  end

  # @site_nets holds ENABLED sites' networks only, so a disabled site's LAN
  # matches neither the saddr accept nor anything else above the drop.
  describe "a disabled site as the source" do
    it "is not a peer, and does not reach a client" do
      report = run("192.168.9.5", "10.8.0.2", "tcp", 22)
      expect(report.verdict).to be == :fail
      expect(stage(report, "Source peer").detail).to be(:include?, "is disabled")
      expect(stage(report, "Forward chain").rule)
        .to be == %(iifname "wg0" oifname "wg0" counter drop)
    end

    it "does not reach another site's LAN either" do
      other = make_site(@db, name: "other", pubkey: "SITE-other",
        networks: ["172.20.0.0/24"])
      expect(other).not.to be_nil
      report = run("192.168.9.5", "172.20.0.5", "tcp", 443)
      expect(report.verdict).to be == :fail
      expect(stage(report, "Source peer").detail).to be(:include?, "is disabled")
    end

    # The enabled site is the control: the same shape must still pass.
    it "still passes from an enabled site" do
      expect(run("192.168.1.5", "10.8.0.2", "tcp", 22).verdict).to be == :pass
    end
  end
end
