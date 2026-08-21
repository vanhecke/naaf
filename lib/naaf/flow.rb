# frozen_string_literal: true

require "ipaddr"
require_relative "ipam"
require_relative "config_builder"
require_relative "renderers/routes"

module Naaf
  # A static reachability analysis: given a source address, a destination and a
  # protocol, what would this box do with the packet?
  #
  # Deliberately NOT under renderers/ — AGENTS.md names exactly four renderers
  # and this emits nothing the kernel ever sees. It is an analyzer over the same
  # rows, and it is pure: no writes, no helper call, no kernel read.
  #
  # Every step quotes the line a renderer actually emits or calls the renderer
  # itself, so the tester cannot drift away from the box without a renderer test
  # failing in the same run. What it CANNOT see is stated as such rather than
  # guessed: the remote end of a site, the base firewall as loaded, and whether
  # a peer is actually handshaking.
  module Flow
    # :hub | :client | :site | :extra | :vpn_unassigned | :internet
    Endpoint = Data.define(:kind, :ip, :label, :row, :enabled)
    # verdict: :pass | :fail | :warn | :info | :unknown
    Step = Data.define(:stage, :verdict, :detail, :rule, :fix)
    Report = Data.define(:src, :dst, :proto, :dport, :steps, :verdict, :summary)

    # Worst first. :info never decides a report — it is a caveat attached to a
    # verdict somebody else reached.
    RANK = {fail: 0, warn: 1, unknown: 2, pass: 3, info: 4}.freeze

    CHIP = {pass: "REACHABLE", fail: "BLOCKED", warn: "CHECK THIS",
            unknown: "UNKNOWN"}.freeze

    # split-nodns and the two ws flavors route exactly what split routes — the
    # flavor changes the DNS line and the transport, never the route set — so
    # reporting all five would be four copies of one answer.
    REPORTED_FLAVORS = %w[split full].freeze

    def self.analyze(db, src:, dst:, proto:, dport: nil)
      s = Naaf.settings
      source = classify(db, src)
      target = classify(db, dst)
      steps = build(db, s, source, target, proto, dport)
      verdict = steps.map(&:verdict).min_by { |v| RANK.fetch(v, 9) } || :unknown
      verdict = :pass if verdict == :info
      Report.new(src: source, dst: target, proto: proto, dport: dport,
        steps: steps.freeze, verdict: verdict,
        summary: summarize(source, target, proto, dport, verdict)).freeze
    end

    # First match wins, most specific role first. A disabled site still claims
    # its own networks: telling the operator "that site is switched off" is the
    # answer they came for, where falling through to :internet would invent a
    # WAN egress path the packet does not take.
    def self.classify(db, ip)
      s = Naaf.settings
      addr = IPAM.parse_v4(ip)
      return Endpoint.new(kind: :internet, ip: ip, label: ip, row: nil, enabled: true) unless addr

      if ip == s[:server_ip]
        return Endpoint.new(kind: :hub, ip: ip, label: "this hub", row: nil, enabled: true)
      end
      if (c = db[:clients].where(wg_ip: ip).first)
        return Endpoint.new(kind: :client, ip: ip, label: "client #{c[:name]}",
          row: c, enabled: c[:enabled])
      end
      db[:sites].order(:name).each do |site|
        cidr = db[:site_networks].where(site_id: site[:id]).order(:cidr)
          .select_map(:cidr).find { |c| IPAM.parse_v4(c)&.include?(addr) }
        next unless cidr
        return Endpoint.new(kind: :site, ip: ip, label: "site #{site[:name]} (#{cidr})",
          row: site, enabled: site[:enabled])
      end
      if (route = db[:extra_routes].all.find { |r| IPAM.parse_v4(r[:cidr])&.include?(addr) })
        return Endpoint.new(kind: :extra, ip: ip, label: "extra route #{route[:cidr]}",
          row: route, enabled: true)
      end
      if IPAM.parse_v4(s[:wg_subnet])&.include?(addr)
        return Endpoint.new(kind: :vpn_unassigned, ip: ip, label: "unassigned VPN address",
          row: nil, enabled: false)
      end
      Endpoint.new(kind: :internet, ip: ip, label: "the internet", row: nil, enabled: true)
    end

    def self.build(db, s, src, dst, proto, dport)
      steps = [Step.new(stage: "Endpoints", verdict: :info,
        detail: "#{src.ip} is #{src.label}; #{dst.ip} is #{dst.label}.",
        rule: nil, fix: nil)]

      # Reported before anything else runs: no peer owns that address, so every
      # question after it is moot.
      [[src, "Source"], [dst, "Destination"]].each do |ep, side|
        next unless ep.kind == :vpn_unassigned
        return steps << Step.new(stage: "#{side} address", verdict: :fail,
          detail: "#{ep.ip} is inside the VPN subnet (#{s[:wg_subnet]}) but no client holds " \
                  "it and no site network covers it, so no peer's AllowedIPs claim it.",
          rule: "AllowedIPs", fix: "/clients")
      end

      return steps.concat(to_hub(db, s, src, proto, dport)) if dst.kind == :hub
      return steps.concat(from_hub(db, s, dst, proto)) if src.kind == :hub

      # Everything arriving on the WAN side goes through one door, whatever it is
      # aimed at: there is no DNAT to anything but a client, and the internet has
      # no route to a private address without one.
      return steps.concat(from_internet(db, s, dst, proto, dport)) if src.kind == :internet

      steps.concat(egress(db, s, src))
      steps.concat(case dst.kind
      when :client then to_client(db, s, src, dst, proto, dport)
      when :site then to_site(db, s, src, dst)
      when :extra then to_extra(db, s, src, dst)
      else to_internet(db, s, src, dst)
      end)
      steps
    end

    # --- the hub itself ----------------------------------------------------

    def self.to_hub(db, s, src, proto, dport)
      base = "tcp/22, udp/#{s[:listen_port]}, ICMP, established/related, `iif lo`" \
             "#{", tcp/#{Config.int("NAAF_WSTUNNEL_PORT")}" if ConfigBuilder.wstunnel?}, " \
             "then `iifname \"#{s[:wg_interface]}\" accept`, then `counter drop`"
      caveat = Step.new(stage: "Base firewall", verdict: :unknown,
        detail: "Traffic to the hub is the `input` chain of `table inet filter`, which this " \
                "application never writes — it is what keeps SSH alive. As the template " \
                "ships it accepts #{base}. That is the file's shape, not the ruleset as " \
                "loaded; only `sudo nft list table inet filter` shows the latter.",
        rule: "/etc/nftables.conf", fix: nil)

      if [:client, :site].include?(src.kind)
        [Step.new(stage: "From the tunnel", verdict: :info,
          detail: "The packet arrives on #{s[:wg_interface]}, which the base template accepts " \
                  "wholesale — that is how the resolver on #{s[:server_ip]}:53 and the admin " \
                  "UI on #{s[:server_ip]}:8080 are reachable at all.",
          rule: "iifname \"#{s[:wg_interface]}\" accept", fix: nil), caveat]
      else
        wanted = hub_port_note(s, proto, dport)
        [Step.new(stage: "From the WAN", verdict: :info, detail: wanted,
          rule: "counter drop", fix: nil), caveat]
      end
    end

    def self.hub_port_note(s, proto, dport)
      open = {["tcp", 22] => "SSH", ["udp", s[:listen_port].to_i] => "WireGuard"}
      open[["tcp", Config.int("NAAF_WSTUNNEL_PORT")]] = "wstunnel" if ConfigBuilder.wstunnel?
      if proto == "icmp"
        "ICMP to the public address is accepted by the base template."
      elsif (name = open[[proto, dport.to_i]])
        "#{proto}/#{dport} is the #{name} port, which the base template accepts."
      else
        "#{proto}/#{dport} is not one of the ports the base template opens on the WAN side, " \
          "so it would reach the chain's `counter drop`. There is deliberately no tcp/80 rule: " \
          "certificates come from ACME DNS-01 and need no inbound port."
      end
    end

    def self.from_hub(db, s, dst, proto)
      steps = [Step.new(stage: "From the hub", verdict: :info,
        detail: "The hub originates this itself — a forwarded DNS query, a `ping` from the " \
                "Troubleshoot page. The `output` chain is `policy accept`, so what decides it " \
                "is routing and the far end, not this box's filter.",
        rule: "chain output { policy accept; }", fix: nil)]
      hub = Endpoint.new(kind: :hub, ip: s[:server_ip], label: "this hub", row: nil,
        enabled: true)
      return steps.concat(to_site(db, s, hub, dst)) if dst.kind == :site
      return steps.concat(hub_to_client(s, dst)) if dst.kind == :client

      # Everything else — the internet, and an extra route, which installs no
      # hub route of its own — leaves the same way.
      steps << Step.new(stage: "Delivery", verdict: :info,
        detail: "#{dst.label} is not behind a site tunnel and the hub has no proto-158 route " \
                "for it, so this leaves by the ordinary default route on " \
                "#{s[:wan_interface]}.", rule: nil, fix: nil)
    end

    # The Troubleshoot page's own ping runs from here, so this is a path an
    # operator reaches by accident as much as on purpose. It goes over the
    # tunnel, not the WAN, and a disabled client is not there to receive it.
    def self.hub_to_client(s, dst)
      row = dst.row
      unless row[:enabled]
        return [Step.new(stage: "Cryptokey routing", verdict: :fail,
          detail: "Client #{row[:name]} is disabled, so Renderers::WireGuard omits it from " \
                  "#{s[:wg_interface]}. Nothing on this box has a route to #{dst.ip}.",
          rule: "[Peer] AllowedIPs = #{row[:wg_ip]}/32", fix: "/clients")]
      end
      [Step.new(stage: "Cryptokey routing", verdict: :pass,
        detail: "#{dst.ip} is client #{row[:name]}'s AllowedIPs, and the interface address " \
                "makes #{s[:wg_subnet]} a connected route — so this goes over the tunnel, " \
                "not the WAN.",
        rule: "[Peer] AllowedIPs = #{row[:wg_ip]}/32", fix: nil),
        Step.new(stage: "Forward chain", verdict: :info,
          detail: "Traffic the hub originates does not traverse the forward hook, so neither " \
                  "the exposed-port sets nor the spoke-to-spoke drop apply. Whether the " \
                  "client answers is up to the client.",
          rule: nil, fix: nil)]
    end

    # --- leaving a client --------------------------------------------------

    # Whether the SOURCE is a peer at all. Every destination branch runs after
    # this one, so the check lives here rather than in each of them — which is
    # how a disabled site came to be reported as reachable in the first place.
    def self.egress(db, s, src)
      case src.kind
      when :client then client_egress(s, src.row)
      when :site then site_egress(db, s, src.row)
      else []
      end
    end

    def self.client_egress(s, row)
      unless row[:enabled]
        return [Step.new(stage: "Source peer", verdict: :fail,
          detail: "Client #{row[:name]} is disabled, so Renderers::WireGuard omits it from " \
                  "#{s[:wg_interface]} entirely — the hub has no key for it and never " \
                  "decrypts its packets.",
          rule: "[Peer] AllowedIPs = #{row[:wg_ip]}/32", fix: "/clients")]
      end

      [Step.new(stage: "Source peer", verdict: :pass,
        detail: "Client #{row[:name]} is enabled and installed on #{s[:wg_interface]} with " \
                "its own /32.",
        rule: "[Peer] AllowedIPs = #{row[:wg_ip]}/32", fix: nil)]
    end

    # A disabled site is absent from wg0 AND from @site_nets, so nothing it
    # sends is decrypted and nothing it sends would be accepted if it were.
    def self.site_egress(db, s, row)
      cidrs = db[:site_networks].where(site_id: row[:id]).order(:cidr).select_map(:cidr)
      unless row[:enabled]
        return [Step.new(stage: "Source peer", verdict: :fail,
          detail: "Site #{row[:name]} is disabled, so it is not a peer on " \
                  "#{s[:wg_interface]}: the hub never decrypts anything from it, and its " \
                  "networks are not in @site_nets either.",
          rule: "[Peer] # #{row[:name]} (site)", fix: "/sites")]
      end

      [Step.new(stage: "Source peer", verdict: :pass,
        detail: "Site #{row[:name]} is enabled and installed on #{s[:wg_interface]} with its " \
                "LANs as AllowedIPs.",
        rule: "AllowedIPs = #{cidrs.join(", ")}", fix: nil)]
    end

    # Which client configs send this destination to the hub at all. A route the
    # config does not carry is a blackhole on the laptop, not a firewall verdict
    # here — the packet never arrives.
    #
    # These steps are :info, NEVER :pass or :fail, and that is the whole point.
    # The report has one source address but no way to know which of five configs
    # is installed on it, so a per-flavor answer is context and not a verdict.
    # Scoring a miss as :fail made `analyze` — which takes the worst step — call
    # every ordinary client-to-internet query BLOCKED, because `split` correctly
    # does not route 0.0.0.0/0. Whether ANY flavor carries it is the decidable
    # question, and routed_by_any? is where it is asked.
    def self.client_routes(db, src, dst)
      return [] unless src.kind == :client
      addr = IPAM.parse_v4(dst.ip)
      builder = ConfigBuilder.new(db, src.row)
      REPORTED_FLAVORS.map { |flavor|
        allowed = builder.allowed_ips(flavor)
        hit = allowed.split(", ").find { |c| IPAM.parse_v4(c)&.include?(addr) }
        detail = if hit
          "The `#{flavor}` config routes #{dst.ip} to the hub via `#{hit}`."
        else
          "The `#{flavor}` config does not route #{dst.ip}, so a client running it never " \
            "sends the packet to the hub — it follows its own default route instead. That " \
            "is a blackhole on the laptop, not a rule on this box."
        end
        Step.new(stage: "Client AllowedIPs (#{flavor})", verdict: :info, detail: detail,
          rule: "AllowedIPs = #{allowed}", fix: hit ? nil : "/extra-routes")
      }
    rescue ArgumentError => e
      # audit_transport_capture refuses a route set that would capture a ws
      # transport. Report it rather than turning a 500 into the answer.
      [Step.new(stage: "Client AllowedIPs", verdict: :warn,
        detail: "ConfigBuilder refuses to compose this client's config: #{e.message}",
        rule: nil, fix: "/clients")]
    end

    # True when at least one reported flavor carries the route. An empty set
    # means the source is not a client, so there is no config to consult and
    # nothing to hold against it.
    def self.routed_by_any?(steps)
      flavor = steps.select { |step| step.stage.start_with?("Client AllowedIPs") }
      flavor.empty? || flavor.any? { |step| step.detail.include?("routes ") }
    end

    # --- spoke to spoke ----------------------------------------------------

    def self.to_client(db, s, src, dst, proto, dport)
      wg = s[:wg_interface]
      steps = client_routes(db, src, dst)
      row = dst.row
      unless row[:enabled]
        return steps << Step.new(stage: "Cryptokey routing", verdict: :fail,
          detail: "Client #{row[:name]} is disabled, so it is not a peer on #{wg}. The hub " \
                  "has nowhere to send the packet and drops it as unroutable.",
          rule: "[Peer] AllowedIPs = #{row[:wg_ip]}/32", fix: "/clients")
      end
      steps << Step.new(stage: "Cryptokey routing", verdict: :pass,
        detail: "#{dst.ip} is client #{row[:name]}'s AllowedIPs on #{wg}.",
        rule: "[Peer] AllowedIPs = #{row[:wg_ip]}/32", fix: nil)

      if src.kind == :site
        # Nftables.site_forwarding builds @site_nets from ENABLED sites only, so
        # a disabled source is not in the set and falls through to the drop.
        unless src.enabled
          return steps << Step.new(stage: "Forward chain", verdict: :fail,
            detail: "Site #{src.row[:name]} is disabled, so its networks are absent from " \
                    "@site_nets and nothing from them matches the saddr accept.",
            rule: "iifname \"#{wg}\" oifname \"#{wg}\" counter drop", fix: "/sites")
        end

        return steps << Step.new(stage: "Forward chain", verdict: :pass,
          detail: "The source sits in an enabled site's LAN, and site traffic is accepted " \
                  "wholesale in both directions — the exposed-port sets do not apply to it.",
          rule: "iifname \"#{wg}\" oifname \"#{wg}\" ip saddr @site_nets accept", fix: nil)
      end

      if proto == "icmp"
        return steps << Step.new(stage: "Forward chain", verdict: :pass,
          detail: "Ping between spokes is allowed unconditionally, above the port sets. " \
                  "A successful ping therefore says nothing about whether a port is open.",
          rule: "iifname \"#{wg}\" oifname \"#{wg}\" icmp type echo-request accept", fix: nil)
      end

      open = exposed_row(db, row[:id], proto, dport)
      set = "@vpn_#{proto}_allow"
      if open
        last = open[:port_end] || open[:port]
        span = (last == open[:port]) ? open[:port].to_s : "#{open[:port]}-#{last}"
        steps << Step.new(stage: "Forward chain", verdict: :pass,
          detail: "#{row[:name]} exposes #{proto} #{span} to other spokes, so the pair " \
                  "(#{dst.ip}, #{dport}) is an element of that set.",
          rule: "iifname \"#{wg}\" oifname \"#{wg}\" ip daddr . #{proto} dport #{set} accept",
          fix: nil)
      else
        steps << Step.new(stage: "Forward chain", verdict: :fail,
          detail: "#{row[:name]} does not expose #{proto}/#{dport}, and spoke-to-spoke is " \
                  "default-deny. Expose the port to open it — `AllowedIPs` is a client-side " \
                  "hint and will not do it.",
          rule: "iifname \"#{wg}\" oifname \"#{wg}\" counter drop", fix: "/exposed-ports")
      end
      steps
    end

    # Reproduces exactly what Nftables.merge folds into the interval set: a row
    # covers dport when port <= dport <= coalesce(port_end, port). NULL port_end
    # means "ends where it starts", the reading every other consumer uses. The
    # join to an enabled client is the only gate — exposed_ports has no `enabled`
    # column of its own.
    def self.exposed_row(db, client_id, proto, dport)
      return nil unless dport
      db[:exposed_ports]
        .where(client_id: client_id, proto: proto)
        .where(Sequel[:port] <= dport.to_i)
        .where(Sequel.function(:coalesce, Sequel[:port_end], Sequel[:port]) >= dport.to_i)
        .first
    end

    # --- reaching a site LAN ------------------------------------------------

    def self.to_site(db, s, src, dst)
      wg = s[:wg_interface]
      site = dst.row
      steps = client_routes(db, src, dst)

      unless site[:enabled]
        return steps << Step.new(stage: "Site peer", verdict: :fail,
          detail: "Site #{site[:name]} is disabled. It is not a peer on #{wg}, its networks " \
                  "are not in @site_nets, and Routes.desired installs no route for them.",
          rule: "[Peer] # #{site[:name]} (site)", fix: "/sites")
      end

      cidrs = db[:site_networks].where(site_id: site[:id]).order(:cidr).select_map(:cidr)
      if cidrs.empty?
        return steps << Step.new(stage: "Site peer", verdict: :fail,
          detail: "Site #{site[:name]} has no networks, so Renderers::WireGuard omits it — " \
                  "WireGuard refuses an empty AllowedIPs.",
          rule: "next if cidrs.empty?", fix: "/sites")
      end

      addr = IPAM.parse_v4(dst.ip)
      route = Renderers::Routes.desired(db)[:routes]
        .find { |r| IPAM.parse_v4(r[:dst])&.include?(addr) }
      steps << if route
        Step.new(stage: "Hub route", verdict: :pass,
          detail: "The hub installs a route for #{route[:dst]} on #{route[:dev]}, so the " \
                  "kernel hands the packet to WireGuard instead of the WAN.",
          rule: "ip route replace #{route[:dst]} dev #{route[:dev]} proto 158", fix: nil)
      else
        Step.new(stage: "Hub route", verdict: :fail,
          detail: "No proto-158 route covers #{dst.ip}.",
          rule: "Renderers::Routes.desired", fix: "/sites")
      end

      steps << Step.new(stage: "Cryptokey routing", verdict: :pass,
        detail: "#{dst.ip} falls inside site #{site[:name]}'s AllowedIPs, so WireGuard " \
                "encrypts it to that peer.",
        rule: "AllowedIPs = #{cidrs.join(", ")}", fix: nil)

      steps << if src.kind == :hub
        Step.new(stage: "Forward chain", verdict: :info,
          detail: "Traffic the hub originates does not traverse the forward hook at all.",
          rule: nil, fix: nil)
      else
        Step.new(stage: "Forward chain", verdict: :pass,
          detail: "Site LANs are accepted wholesale, above the spoke-to-spoke drop and " \
                  "regardless of protocol or port. Exposed ports do not apply here.",
          rule: "iifname \"#{wg}\" oifname \"#{wg}\" ip daddr @site_nets accept", fix: nil)
      end

      steps << masquerade_step(s, site, cidrs)
      steps << Step.new(stage: "The remote end", verdict: :info,
        detail: "naaf cannot see this. The host at #{dst.ip} must answer, and the remote " \
                "WireGuard must list #{site[:masquerade] ? site[:address] || "this hub's site address" : s[:wg_subnet]} " \
                "in its own AllowedIPs, or it will drop the packet after decrypting it.",
        rule: nil, fix: nil)
    end

    def self.masquerade_step(s, site, cidrs)
      dest = (cidrs.size == 1) ? cidrs.first : "{ #{cidrs.join(", ")} }"
      unless site[:masquerade]
        return Step.new(stage: "Source address", verdict: :info,
          detail: "Masquerade is off, so the remote sees the original VPN address. That is " \
                  "what lets a host behind the site open a connection back to a laptop.",
          rule: nil, fix: nil)
      end

      target = site[:address] ? "snat to #{site[:address]}" : "masquerade"
      Step.new(stage: "Source address", verdict: :warn,
        detail: "Masquerade is on for this site, so the remote sees the query coming from " \
                "#{site[:address] || "this hub"} and not from the original VPN address. " \
                "Return traffic works; a host behind the site cannot INITIATE a connection " \
                "to a laptop.",
        rule: "ip saddr #{s[:wg_subnet]} ip daddr #{dest} oifname \"#{s[:wg_interface]}\" #{target}",
        fix: "/sites")
    end

    # --- the remaining destinations ----------------------------------------

    # extra_routes widen a client's AllowedIPs and install NO hub route, so the
    # packet arrives and is then handled by the hub's ordinary routing table —
    # which almost always means straight back out of the WAN interface.
    def self.to_extra(db, s, src, dst)
      steps = client_routes(db, src, dst)
      steps << Step.new(stage: "Hub route", verdict: :warn,
        detail: "#{dst.ip} is covered by the extra route #{dst.row[:cidr]}, which is folded " \
                "into client AllowedIPs but installs nothing on the hub — Routes.desired " \
                "only emits site networks. The packet reaches the hub and then follows its " \
                "default route out of #{s[:wan_interface]}, masqueraded. That is rarely what " \
                "an extra route was added for: if the network lives behind a tunnel, it " \
                "belongs to a site.",
        rule: "ip saddr #{s[:wg_subnet]} oifname \"#{s[:wan_interface]}\" masquerade",
        fix: "/sites")
    end

    def self.to_internet(db, s, src, dst)
      steps = client_routes(db, src, dst)
      steps << Step.new(stage: "Egress", verdict: routed_by_any?(steps) ? :pass : :fail,
        detail: "Full-tunnel clients send everything here and leave masqueraded behind the " \
                "hub's public address. A split client reaches #{dst.ip} over its own " \
                "connection instead, without involving this box at all.",
        rule: "ip saddr #{s[:wg_subnet]} oifname \"#{s[:wan_interface]}\" masquerade", fix: nil)
    end

    # --- arriving from the public side --------------------------------------

    def self.from_internet(db, s, dst, proto, dport)
      wg = s[:wg_interface]
      wan = s[:wan_interface]
      unless dst.kind == :client
        return [Step.new(stage: "Inbound", verdict: :fail,
          detail: "Only a client can be reached from the internet, and only through a port " \
                  "forward. There is no DNAT to a site LAN.",
          rule: "chain prerouting", fix: "/port-forwards")]
      end

      row = dst.row
      forwards = db[:port_forwards].where(client_id: row[:id], enabled: true).all
      hit = forwards.find { |f| f[:proto] == proto && f[:target_port].to_i == dport.to_i }
      unless row[:enabled]
        return [Step.new(stage: "DNAT", verdict: :fail,
          detail: "Client #{row[:name]} is disabled, so its port forwards are dropped from " \
                  "the ruleset along with its peer.",
          rule: "chain prerouting", fix: "/clients")]
      end

      if hit
        [Step.new(stage: "DNAT", verdict: :pass,
          detail: "Reach it on the PUBLIC port #{hit[:public_port]}, not #{dport}: the hub " \
                  "rewrites the destination to #{row[:wg_ip]}:#{hit[:target_port]} in " \
                  "prerouting.",
          rule: "iifname \"#{wan}\" #{hit[:proto]} dport #{hit[:public_port]} " \
                "dnat ip to #{row[:wg_ip]}:#{hit[:target_port]}", fix: nil),
          Step.new(stage: "Forward chain", verdict: :pass,
            detail: "The forward chain accepts it because conntrack has marked it as " \
                    "translated, and postrouting masquerades the reply so the client answers " \
                    "via the hub rather than its own default route.",
            rule: "iifname \"#{wan}\" oifname \"#{wg}\" ct status dnat accept", fix: nil)]
      else
        [Step.new(stage: "DNAT", verdict: :fail,
          detail: "No enabled port forward targets #{proto}/#{dport} on #{row[:name]}. The " \
                  "forward chain's policy is `accept`, but that is not why this fails: " \
                  "#{row[:wg_ip]} is a private address inside the tunnel and the internet has " \
                  "no route to it at all. Without a DNAT the packet never arrives.",
          rule: "chain prerouting", fix: "/port-forwards")]
      end
    end

    def self.summarize(src, dst, proto, dport, verdict)
      what = (proto == "icmp") ? "ICMP echo" : "#{proto}/#{dport}"
      case verdict
      when :pass then "#{what} from #{src.label} reaches #{dst.label}."
      when :fail then "#{what} from #{src.label} does not reach #{dst.label}."
      when :warn then "#{what} from #{src.label} reaches #{dst.label}, but read the warning."
      else "naaf cannot decide this one from the database alone."
      end
    end
  end
end
