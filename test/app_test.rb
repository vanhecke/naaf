# frozen_string_literal: true

require_relative "helper"
require "bcrypt"
require "rack/mock"
require "naaf/app"

# Stubs so routes run without a live helper/kernel. genkeys returns a distinct,
# predictable key per call so we can trace which client's key ends up where.
class StubHelper
  # How many keypairs have been handed out, so a test can name the key it
  # expects ("PRIV#{n}") without assuming which client id it landed on.
  attr_reader :n

  def initialize
    @n = 0
  end

  def genkeys
    @n += 1
    {public_key: "PUB#{@n}", private_key: "PRIV#{@n}", preshared_key: "PSK#{@n}"}
  end

  def apply(**) = {ok: true}
  def dump = ""
end

class StubReconciler
  attr_reader :helper

  def initialize
    @helper = StubHelper.new
  end

  def apply! = true
  def last_poll_at = nil
  def last_apply_at = nil
  def last_error = nil
end

# Rack::MockResponse drains a response body eagerly the moment it is built, so a
# stream that loops forever would wedge the whole suite with no timeout to save
# it. A hub that has been published to and then closed makes GET /events finite
# by the same code path production uses at shutdown: wait() drains the pending
# frame and then reports the end.
# A snapshot carrying the shape of a real helper failure. bin/naaf-helper folds
# the child's stderr into the exception it raises, and `wg` echoes an offending
# key verbatim — so this is what a leak would actually look like.
class LeakyMetrics
  attr_reader :hub, :snapshot

  SECRET = "SUPERSECRETKEYSUPERSECRETKEYSUPERSECRETKEY0="

  def initialize
    empty = Naaf::Metrics::Snapshot.empty
    # reconcile_failing is the only field the snapshot carries. reconcile_error
    # is planted here as a field a future change might reintroduce — if a
    # template ever renders free-form helper text again, this test fails.
    @snapshot = empty.with(app: empty.app.merge(
      reconcile_failing: true,
      reconcile_error: "wg-quick failed (1): Key is not the correct length or format: `#{SECRET}'"
    ).freeze).freeze
    @hub = Naaf::Metrics::Hub.new
    @hub.publish(@snapshot)
    @hub.close
  end
end

# Serves a snapshot with specific sections overridden, so a fragment can be
# rendered in a state the fixtures cannot reach (a full disk, a dead reconciler).
class StubMetrics
  attr_reader :snapshot, :hub

  def initialize(**sections)
    empty = Naaf::Metrics::Snapshot.empty
    merged = sections.to_h { |k, v| [k, empty.public_send(k).merge(v).freeze] }
    @snapshot = empty.with(**merged).freeze
    @hub = Naaf::Metrics::Hub.new
    @hub.publish(@snapshot)
    @hub.close
  end
end

class ScriptedMetrics
  attr_reader :hub, :snapshot

  def initialize(frames = 1)
    @hub = Naaf::Metrics::Hub.new
    @snapshot = Naaf::Metrics::Snapshot.empty
    frames.times { @hub.publish(@snapshot) }
    @hub.close
  end
end

describe "Naaf::App integration" do
  before do
    reset_db!(
      server_pubkey: "SRVPUB", server_ip: "10.8.0.1", endpoint_v4: "203.0.113.5",
      wg_subnet: "10.8.0.0/24", mtu: 1420, listen_port: 51820, dns_domain: "vpn",
      admin_pw_hash: BCrypt::Password.create("secret")
    )
    Naaf::App.reconciler = StubReconciler.new
    Naaf::App.metrics = nil
    @app = Naaf::App.app
    @cookie = nil
  end

  # --- a tiny cookie-jar HTTP client over Rack::MockRequest ---
  def mr = Rack::MockRequest.new(@app)

  def cookie_env = @cookie ? {"HTTP_COOKIE" => @cookie} : {}

  def remember_cookie(res)
    sc = res.headers["set-cookie"] || res.headers["Set-Cookie"]
    sc = sc.first if sc.is_a?(Array)
    @cookie = sc.to_s.split(";").first unless sc.to_s.empty?
  end

  def get(path, accept: "text/html,application/xhtml+xml")
    res = mr.get(path, cookie_env.merge("HTTP_ACCEPT" => accept))
    remember_cookie(res)
    res
  end

  def post(path, params)
    res = mr.post(path, cookie_env.merge(params: params))
    remember_cookie(res)
    res
  end

  # The layout renders an /apply form before the page body, so grab the token
  # that belongs to the specific form action, not merely the first on the page.
  def csrf_for(body, action)
    body[/action="#{Regexp.escape(action)}"[^>]*>.*?name="_csrf" value="([^"]+)"/m, 1]
  end

  def login!
    body = get("/login").body
    post("/login", "password" => "secret", "_csrf" => csrf_for(body, "/login"))
  end

  # Returns the actual new client id (ids are AUTOINCREMENT — never assume 1).
  def add_client(name, pubkey: "")
    body = get("/clients").body
    post("/clients", "name" => name, "hostname" => name, "pubkey" => pubkey,
      "_csrf" => csrf_for(body, "/clients"))
    Naaf.db[:clients].where(name: name).get(:id)
  end

  # Fetch the form on `list_path`, lift the token bound to `action`, then post to
  # `action`. For an add form list_path == action; for a row action (delete /
  # toggle) the token still lives on the list page.
  def post_form(list_path, action, params)
    body = get(list_path).body
    post(action, params.merge("_csrf" => csrf_for(body, action)))
  end

  it "logs in with a request-specific CSRF token and reaches the dashboard" do
    expect(login!.status).to be == 302
    expect(get("/clients").status).to be == 200
  end

  # Every other dashboard test runs against clients with a NULL last_handshake_at,
  # which short-circuits the view's `ago` helper before it does any arithmetic.
  it "renders the dashboard for a client that has actually handshaked" do
    login!
    add_client("nas")
    Naaf.db[:clients].where(name: "nas").update(
      last_handshake_at: Time.now - 7200, endpoint: "81.82.83.84:51820",
      rx_bytes: 12_345_678, tx_bytes: 9_876_543
    )
    res = get("/clients")
    expect(res.status).to be == 200
    expect(res.body).to be(:include?, "2h ago")
  end

  it "redirects the dashboard to /login when unauthenticated" do
    res = get("/")
    expect(res.status).to be == 302
    expect(res.headers["location"]).to be == "/login"
  end

  # --- the client list, moved from / to /clients ---

  # --- the dashboard at / ---

  it "serves the dashboard at /" do
    login!
    res = get("/")
    expect(res.status).to be == 200
    expect(res.body).to be(:include?, "Dashboard")
    expect(res.body).to be(:include?, "Packet pipeline")
    expect(res.body).to be(:include?, "Peers")
  end

  # The add form lives on /clients and nowhere else. If it ever appeared here
  # too, add_client's csrf_for would silently lift a token from the wrong page
  # and the two would drift apart without any test noticing.
  it "keeps the add-client form off the dashboard" do
    login!
    expect(get("/").body.include?('action="/clients"')).to be == false
  end

  # Before the collector has ever ticked — and forever on a box with no /proc —
  # every panel still has to render. An empty snapshot carries every key a
  # fragment touches, so the formatters turn the gaps into em dashes.
  it "renders every panel before the collector has produced anything" do
    login!
    Naaf::App.metrics = nil
    body = get("/").body

    expect(body).to be(:include?, "—")
    expect(body).not.to be(:match?, /NaN|Infinity/)
  end

  it "serves each fragment as a plain GET so the page works without the stream" do
    login!
    Naaf::Metrics::FRAGMENTS.each do |name|
      res = get("/metrics/#{name}")
      expect(res.status).to be == 200
      expect(res.body.include?("<html")).to be == false # a fragment, not a page
      expect(res.body).not.to be(:match?, /NaN|Infinity/)
    end
  end

  # The fragment name is interpolated into a template path, so the whitelist is
  # load-bearing rather than a convenience.
  it "serves only whitelisted fragment names" do
    login!
    expect(get("/metrics/nope").status).to be == 404
    expect(get("/metrics/..%2Fsettings").status).to be == 404
  end

  it "streams the fragments as named SSE events" do
    login!
    Naaf::App.metrics = ScriptedMetrics.new
    res = get("/events")

    expect(res.status).to be == 200
    expect(res.headers["content-type"]).to be == "text/event-stream"
    expect(res.headers["cache-control"]).to be == "no-store"
    # protocol-rack turns a Content-Length into a hard transport length and
    # raises on the first chunk past it, so the stream must not carry one.
    expect(res.headers.key?("content-length")).to be == false

    expect(res.body).to be(:include?, "retry: 3000")
    Naaf::Metrics::LIVE_FRAGMENTS.each do |name|
      expect(res.body).to be(:match?, /^event: #{name}$/)
    end
    # Configuration, not telemetry: swapping it every couple of seconds would
    # destroy text selection and focus inside it for no new information.
    expect(res.body).not.to be(:match?, /^event: policy$/)
    # Every payload line carries its own data: prefix — the first bare newline
    # in a data: line would terminate the event and drop the rest of the panel.
    expect(res.body.lines.grep_v(/\A(event:|data:|retry:|:|\n)/)).to be(:empty?)
  end

  # EventSource follows a 302, gets HTML, and fails with no retry of its own —
  # so a redirect here reads to the user as a dashboard that silently froze.
  it "answers an unauthenticated stream request with 401, not a redirect" do
    expect(get("/events").status).to be == 401
  end

  # htmx follows a redirect transparently and would swap the login page into
  # whichever panel asked for a fragment.
  it "bounces a lapsed htmx request with HX-Redirect rather than a redirect" do
    res = mr.get("/metrics/kpis", "HTTP_HX_REQUEST" => "true")
    expect(res.status).to be == 204
    expect(res.headers["HX-Redirect"]).to be == "/login"
  end

  it "still redirects an ordinary browser request to the login form" do
    expect(get("/metrics/kpis").status).to be == 302
  end

  # An EventSource cannot navigate the tab, so without this the page just
  # freezes when the session lapses and the extension retries forever.
  it "keeps an auth canary on the page that can bounce a lapsed tab" do
    login!
    body = get("/").body
    expect(body).to be(:match?, /hx-get="\/metrics\/health"[^>]*hx-trigger="every 60s"/)
    expect(body).to be(:include?, 'hx-swap="none"')
  end

  # The wrapper carrying hx-ext/sse-connect must never itself be swapped: htmx
  # re-processing it opens a second EventSource and leaks the first.
  it "keeps the stream wrapper out of every swap target" do
    login!
    body = get("/").body
    Naaf::Metrics::FRAGMENTS.each do |name|
      fragment = get("/metrics/#{name}").body
      expect(fragment.include?("sse-connect")).to be == false
      expect(fragment.include?("hx-ext")).to be == false
    end
    expect(body.scan("sse-connect").length).to be == 1
  end

  # The reconciler records the exception CLASS and never its message, because
  # the message can carry the WireGuard server private key. This asserts the
  # rendered output rather than the snapshot, since rendering is what would
  # actually put it in front of an admin and onto every open stream.
  it "never renders a helper failure message into a fragment or a frame" do
    login!
    Naaf::App.metrics = LeakyMetrics.new

    %w[app health].each do |name|
      body = get("/metrics/#{name}").body
      expect(body.include?(LeakyMetrics::SECRET)).to be == false
      expect(body).not.to be(:match?, %r{[A-Za-z0-9+/]{43}=})
    end

    frames = get("/events").body
    expect(frames.include?(LeakyMetrics::SECRET)).to be == false
    expect(frames).not.to be(:match?, %r{[A-Za-z0-9+/]{43}=})
  end

  # A tile in trouble colours its own edge, so it can be found without reading
  # the whole page. The colour is never the only signal — each of these tiles
  # also states the problem in words or numbers.
  describe "state borders" do
    it "leaves a healthy tile unmarked" do
      login!
      Naaf::App.metrics = StubMetrics.new(system: {mem_pct: 40.0, conntrack_pct: 5.0})
      body = get("/metrics/kpis").body
      expect(body.include?("naaf-alert")).to be == false
      expect(body.include?("naaf-warn")).to be == false
    end

    it "marks memory as a fault past 90% and a warning past 80%" do
      login!
      Naaf::App.metrics = StubMetrics.new(system: {mem_pct: 93.0})
      expect(get("/metrics/kpis").body).to be(:include?, "naaf-alert")

      Naaf::App.metrics = StubMetrics.new(system: {mem_pct: 84.0})
      body = get("/metrics/kpis").body
      expect(body).to be(:include?, "naaf-warn")
      expect(body.include?("naaf-alert")).to be == false
    end

    it "marks a conntrack table filling up" do
      login!
      Naaf::App.metrics = StubMetrics.new(system: {conntrack_pct: 88.0})
      expect(get("/metrics/kpis").body).to be(:include?, "naaf-warn")
    end

    it "marks the pipeline when no peer is connected" do
      login!
      Naaf::App.metrics = StubMetrics.new(pipeline: {verdict: :stalled, message: "x"})
      expect(get("/metrics/pipeline").body).to be(:include?, "naaf-alert")
    end

    it "marks a failing reconciler as a fault and absent backups as a warning" do
      login!
      Naaf::App.metrics = StubMetrics.new(app: {reconcile_failing: true, backups_enabled: true})
      expect(get("/metrics/app").body).to be(:include?, "naaf-alert")

      Naaf::App.metrics = StubMetrics.new(app: {backups_enabled: false})
      body = get("/metrics/app").body
      expect(body).to be(:include?, "naaf-warn")
      expect(body.include?("naaf-alert")).to be == false
    end
  end

  it "shows a live indicator while the stream is on" do
    login!
    body = get("/").body
    expect(body).to be(:include?, "naaf-live")
    expect(body).to be(:include?, "naaf-dot")
  end

  it "serves the vendored SSE extension and the stylesheet, cacheably" do
    %w[/htmx-ext-sse.min.js /naaf.css].each do |path|
      res = mr.get(path)
      expect(res.status).to be == 200
      expect(res.headers["cache-control"]).to be_nil
    end
  end

  it "serves the client list at /clients" do
    login!
    res = get("/clients")
    expect(res.status).to be == 200
    expect(res.body).to be(:include?, "Add client")
    expect(res.body).to be(:include?, "Clients")
  end

  it "guards /clients behind the same auth gate as every other page" do
    res = get("/clients")
    expect(res.status).to be == 302
    expect(res.headers["location"]).to be == "/login"
  end

  it "sends every client mutation back to the list it was made from" do
    login!
    dave = add_client("dave")

    body = get("/clients").body
    toggled = post("/clients/#{dave}/toggle",
      "_csrf" => csrf_for(body, "/clients/#{dave}/toggle"))
    expect(toggled.headers["location"]).to be == "/clients"

    body = get("/clients").body
    deleted = post("/clients/#{dave}/delete",
      "_csrf" => csrf_for(body, "/clients/#{dave}/delete"))
    expect(deleted.headers["location"]).to be == "/clients"
  end

  it "sends a newly added client back to the list" do
    login!
    body = get("/clients").body
    res = post("/clients", "name" => "erin", "hostname" => "erin", "pubkey" => "",
      "_csrf" => csrf_for(body, "/clients"))
    expect(res.headers["location"]).to be == "/clients"
  end

  # The list is matched with `r.get true`. A bare `r.get` would match any GET
  # under /clients and swallow these two before they ever reached a handler,
  # which is the one ordering mistake available here.
  it "still routes the per-client config and QR downloads" do
    login!
    frank = add_client("frank")

    conf = get("/clients/#{frank}/config/split")
    expect(conf.status).to be == 200
    expect(conf.headers["content-type"]).to be == "text/plain"

    qr = get("/clients/#{frank}/qr/split")
    expect(qr.status).to be == 200
    expect(qr.headers["content-type"]).to be == "image/svg+xml"
  end

  it "leaves the client list reachable from the navigation" do
    login!
    expect(get("/clients").body).to be(:include?, 'href="/clients"')
  end

  # Falcon installs a *shared* HTTP cache by default. It stores 302s, keys only on
  # method+path, and looks the entry up before checking whether the request is
  # cacheable — so it ignores the session cookie on the way in. A logged-out
  # GET / (302 -> /login, no Set-Cookie) would be stored and then replayed to
  # authenticated users forever, since the entry carries no max-age. bin/naaf
  # passes cache: false; no-store is the second, in-app barrier that also keeps
  # the pages out of browser and proxy caches.
  it "marks every app response no-store, including redirects" do
    expect(get("/").headers["cache-control"]).to be == "no-store"
    expect(get("/login").headers["cache-control"]).to be == "no-store"
    login!
    expect(get("/clients").headers["cache-control"]).to be == "no-store"
    expect(get("/exposed-ports").headers["cache-control"]).to be == "no-store"
  end

  it "keeps a client config and its QR out of every cache — they carry a private key" do
    login!
    erin = add_client("erin")
    expect(get("/clients/#{erin}/config/split").headers["cache-control"]).to be == "no-store"
    expect(get("/clients/#{erin}/qr/split").headers["cache-control"]).to be == "no-store"
  end

  it "leaves the vendored assets cacheable" do
    expect(get("/bulma.min.css").headers["cache-control"]).to be_nil
  end

  it "sends an already-authenticated admin away from the login form" do
    login!
    res = get("/login")
    expect(res.status).to be == 302
    expect(res.headers["location"]).to be == "/"
  end

  it "returns to the originally requested page after logging in" do
    expect(get("/exposed-ports").headers["location"]).to be == "/login"
    expect(login!.headers["location"]).to be == "/exposed-ports"
  end

  # A browser fetches /favicon.ico unprompted, and that request hits the auth
  # gate too. Recording it would land the admin on a 404 after logging in.
  it "does not let a browser sub-resource request hijack the post-login page" do
    get("/exposed-ports")
    get("/favicon.ico", accept: "image/avif,image/webp,image/*,*/*;q=0.8")
    expect(login!.headers["location"]).to be == "/exposed-ports"
  end

  it "takes the post-login destination from the session, never from a request param" do
    get("/exposed-ports") # the only thing that may set return_to
    body = get("/login").body
    res = post("/login", "password" => "secret", "_csrf" => csrf_for(body, "/login"),
      "return_to" => "/settings")
    expect(res.headers["location"]).to be == "/exposed-ports"
  end

  # `GET //evil.example.com/` leaves PATH_INFO protocol-relative, so an unguarded
  # return_to would redirect off-site after login. Rack::MockRequest normalizes
  # the "//" away, so drive the guard directly — verified against a live server too.
  it "refuses to bounce the post-login redirect off-site" do
    scope = Naaf::App.allocate
    def scope.session = @session ||= {}

    scope.session["return_to"] = "//evil.example.com/"
    expect(scope.safe_return_to).to be == "/"

    scope.session["return_to"] = "https://evil.example.com/"
    expect(scope.safe_return_to).to be == "/"

    scope.session["return_to"] = "/exposed-ports"
    expect(scope.safe_return_to).to be == "/exposed-ports"

    expect(scope.safe_return_to).to be == "/" # consumed, so it cannot replay
  end

  # The auth gate used to sit below check_csrf!, so a POST from a page whose
  # session had lapsed failed the CSRF check first and surfaced as a bare 500.
  it "sends a lapsed-session POST back to the login form instead of erroring" do
    login!
    body = get("/clients").body
    token = csrf_for(body, "/apply")
    @cookie = nil # session gone: browser restart, expiry, server-side clear
    res = post("/apply", "_csrf" => token)
    expect(res.status).to be == 302
    expect(res.headers["location"]).to be == "/login"
  end

  it "binds the one-shot private key to its client — never leaks it into another client's config" do
    login!
    alice = add_client("alice") # -> PRIV1
    bob = add_client("bob")     # -> PRIV2 (session slot now holds bob's key)

    alice_conf = get("/clients/#{alice}/config/split").body
    expect(alice_conf.include?("PRIV1")).to be == false # alice's own key already superseded
    expect(alice_conf.include?("PRIV2")).to be == false # and bob's key must NEVER appear here
    expect(alice_conf).to be(:include?, "REPLACE_WITH_YOUR_PRIVATE_KEY")

    bob_conf = get("/clients/#{bob}/config/split").body
    expect(bob_conf).to be(:include?, "PrivateKey = PRIV2")
  end

  it "does not leak a pending key into another client's QR" do
    login!
    alice = add_client("alice") # -> PRIV1
    add_client("bob")           # -> PRIV2 pending
    qr = get("/clients/#{alice}/qr/split") # alice's QR while bob's key is pending
    expect(qr.status).to be == 200
    expect(qr.body.include?("PRIV2")).to be == false
  end

  it "consumes the one-shot key on download; a second download yields the placeholder" do
    login!
    carol = add_client("carol") # -> PRIV1
    first = get("/clients/#{carol}/config/split").body
    expect(first).to be(:include?, "PrivateKey = PRIV1")
    second = get("/clients/#{carol}/config/split").body
    expect(second.include?("PRIV1")).to be == false
    expect(second).to be(:include?, "REPLACE_WITH_YOUR_PRIVATE_KEY")
  end

  # The QR is a peek, not a take: scanning it does not spend the key, so the
  # admin can still download the .conf for the same client afterwards.
  it "does not consume the one-shot key when rendering the QR" do
    login!
    quinn = add_client("quinn") # -> PRIV1
    expect(get("/clients/#{quinn}/qr/split").status).to be == 200
    expect(get("/clients/#{quinn}/config/split").body).to be(:include?, "PrivateKey = PRIV1")
  end

  # A successful ws download spends the key exactly like a plain one.
  it "consumes the one-shot key on a successful ws download" do
    login!
    rex = add_client("rex") # -> PRIV1
    with_wstunnel do
      expect(get("/clients/#{rex}/config/split-ws").body).to be(:include?, "PrivateKey = PRIV1")
      expect(get("/clients/#{rex}/config/split-ws").body)
        .to be(:include?, "REPLACE_WITH_YOUR_PRIVATE_KEY")
    end
  end

  # The availability guard is NOT a sufficient precondition for render():
  # ConfigBuilder raises ArgumentError for every one of these wstunnel
  # misconfigurations well after the flavor has been judged available, and each
  # one used to be reached with the session stash already deleted — permanently
  # destroying the only copy of a freshly generated private key whose sole
  # recovery is deleting and re-adding the client. The key must survive a 500.
  it "keeps the one-shot key when a ws render fails" do
    login!
    cells = {
      "unprovisioned path prefix" => {"NAAF_WSTUNNEL_PATH_PREFIX" => nil},
      "malformed path prefix" => {"NAAF_WSTUNNEL_PATH_PREFIX" => "not a prefix!"},
      "malformed SNI" => {"NAAF_WSTUNNEL_SNI" => "a b"},
      "out-of-range port" => {"NAAF_WSTUNNEL_PORT" => "99999"},
      "unrecognised TLS_VERIFY" => {"NAAF_WSTUNNEL_TLS_VERIFY" => "yes"},
      "verify + SNI without ACME" => {
        "NAAF_WSTUNNEL_TLS_VERIFY" => "on",
        "NAAF_WSTUNNEL_SNI" => "www.example.com",
        "NAAF_ACME_ENABLED" => "0"
      }
    }
    cells.each_with_index do |(label, env), i|
      who = add_client("burn#{i}") # -> a fresh PRIV stashed against this id
      key = "PrivateKey = PRIV#{Naaf::App.reconciler.helper.n}"
      with_wstunnel(env) do
        expect(get("/clients/#{who}/config/split-ws").status).to be == 500
      end
      conf = get("/clients/#{who}/config/split").body
      # The label rides along so a failure names the cell that burned the key.
      expect([label, conf.include?(key)]).to be == [label, true]
    end
  end

  # --- the wstunnel flavors, which exist only when the server half is on ---

  it "refuses a ws config while wstunnel is disabled, and serves one when it is on" do
    login!
    hank = add_client("hank")

    expect(get("/clients/#{hank}/config/split-ws").status).to be == 404
    expect(get("/clients/#{hank}/config/split-ws-nodns").status).to be == 404

    with_wstunnel do
      res = get("/clients/#{hank}/config/split-ws")
      expect(res.status).to be == 200
      expect(res.headers["content-type"]).to be == "text/plain"
      expect(res.headers["cache-control"]).to be == "no-store"
      # WireGuard dials the local relay; the real endpoint only appears in the
      # wss:// URL the PreUp hook hands to wstunnel.
      expect(res.body).to be(:include?, "Endpoint = 127.0.0.1:51820")
      expect(res.body).to be(:include?, "wss://203.0.113.5:443")
    end
  end

  # ConfigBuilder#render raises ArgumentError for an unknown flavor, and
  # error_handler flattens that into a 500 "Internal error". A path nobody
  # routes is a 404.
  it "answers an unknown config flavor with 404 rather than a server error" do
    login!
    ivy = add_client("ivy")
    expect(get("/clients/#{ivy}/config/bogus").status).to be == 404
    expect(get("/clients/#{ivy}/config/..%2Fsettings").status).to be == 404
  end

  # A halt(404) from inside the with_oneshot_privkey block would throw past the
  # delete, so this direction is safe by construction — but it is also the
  # direction a "just take it up front again" refactor breaks first, so pin it.
  it "does not consume the one-shot key on a request for an unavailable flavor" do
    login!
    grace = add_client("grace") # -> PRIV1, stashed against this client id

    expect(get("/clients/#{grace}/config/split-ws").status).to be == 404
    expect(get("/clients/#{grace}/config/bogus").status).to be == 404

    expect(get("/clients/#{grace}/config/split").body).to be(:include?, "PrivateKey = PRIV1")
  end

  # wireguard-apple's parser allows only privatekey/listenport/address/dns/mtu
  # in [Interface] and throws interfaceHasUnrecognizedKey otherwise, as does
  # wireguard-android. A ws config carries PreUp, so the scan could only ever
  # produce an import error — the refusal is not conditional on the server flag.
  it "offers no QR for a ws flavor even while wstunnel is enabled" do
    login!
    iris = add_client("iris")

    expect(get("/clients/#{iris}/qr/split-ws").status).to be == 404
    expect(get("/clients/#{iris}/qr/nope").status).to be == 404

    with_wstunnel do
      expect(get("/clients/#{iris}/qr/split-ws").status).to be == 404
      expect(get("/clients/#{iris}/qr/split-ws-nodns").status).to be == 404
      expect(get("/clients/#{iris}/qr/split").status).to be == 200
    end
  end

  # An assertion against get("/") would pass vacuously in both directions — the
  # flavour buttons live on /clients and nowhere else.
  it "shows the ws buttons on /clients only while wstunnel is enabled" do
    login!
    add_client("jade")

    body = get("/clients").body
    expect(body).to be(:include?, "/config/split")
    expect(body.include?("/config/split-ws")).to be == false

    with_wstunnel do
      body = get("/clients").body
      expect(body).to be(:include?, "/config/split-ws")
      expect(body).to be(:include?, "/config/split-ws-nodns")
      expect(body).to be(:include?, "split·ws·nodns") # U+00B7, as for split·nodns
      # are-small sizes every button in the group; losing it changes the row
      # height of the whole table.
      expect(body).to be(:include?, "buttons are-small has-addons")
      # Exactly one QR link per row, and it stays outside the flavour loop.
      expect(body.scan("/qr/split").length).to be == 1
      expect(body).to be(:match?, /class="button is-link is-light"[^>]*rel="noopener"/)
    end
  end

  # Enabled but not yet provisioned: 65-wstunnel has not written the path prefix,
  # so every ws config the page offers would dial a path the server rejects.
  it "flags a half-provisioned wstunnel on the client list" do
    login!
    add_client("kim")

    with_wstunnel("NAAF_WSTUNNEL_PATH_PREFIX" => nil) do
      body = get("/clients").body
      expect(body).to be(:include?, "65-wstunnel")
      # The one-shot-key banner is already is-warning; a second yellow banner
      # would stack into one indistinguishable block.
      expect(body).to be(:include?, "is-warning")
      expect(body.scan("is-warning").length).to be == 1
    end

    with_wstunnel do
      expect(get("/clients").body.include?("65-wstunnel")).to be == false
    end
  end

  # wg-quick(8) derives the interface name from the .conf basename and refuses
  # anything outside [a-zA-Z0-9_=+.-]{1,15}\.conf — it exits before reading a
  # line. `<hostname>-<flavor>.conf` broke that for split-nodns on any hostname
  # at all, and would have broken split-ws-nodns worse.
  it "names every downloaded config something wg-quick will accept" do
    login!
    long = add_client("averyverylonghostname")

    with_wstunnel do
      names = Naaf::ConfigBuilder::FLAVORS.map do |flavor|
        res = get("/clients/#{long}/config/#{flavor}")
        expect(res.status).to be == 200
        name = res.headers["content-disposition"][/filename="([^"]+)"/, 1]
        expect(name).to be(:match?, /\A[a-zA-Z0-9_=+.-]{1,15}\.conf\z/)
        name
      end
      # Truncation must not collapse two flavors onto one filename.
      expect(names.uniq.length).to be == Naaf::ConfigBuilder::FLAVORS.length
    end
  end

  it "accepts the re-apply action from the navbar form" do
    login!
    body = get("/clients").body
    res = post("/apply", "_csrf" => csrf_for(body, "/apply"))
    expect(res.status).to be == 302
    expect(res.headers["location"]).to be == "/"
  end

  it "accepts a request-specific delete and removes the client" do
    login!
    dave = add_client("dave")
    body = get("/clients").body
    res = post("/clients/#{dave}/delete", "_csrf" => csrf_for(body, "/clients/#{dave}/delete"))
    expect(res.status).to be == 302
    expect(Naaf.db[:clients][id: dave]).to be_nil
  end

  # --- resource management UIs: exposed ports / port forwards / DNS records ---

  it "redirects the resource pages to /login when unauthenticated" do
    %w[/exposed-ports /port-forwards /dns-records].each do |path|
      res = get(path)
      expect(res.status).to be == 302
      expect(res.headers["location"]).to be == "/login"
    end
  end

  it "exposes a port for a client and stores it, then deletes it" do
    login!
    nas = add_client("nas")
    res = post_form("/exposed-ports", "/exposed-ports",
      "client_id" => nas, "proto" => "tcp", "port" => "22", "description" => "ssh")
    expect(res.status).to be == 302
    row = Naaf.db[:exposed_ports].where(client_id: nas).first
    expect(row[:proto]).to be == "tcp"
    expect(row[:port]).to be == 22
    expect(row[:description]).to be == "ssh"

    post_form("/exposed-ports", "/exposed-ports/#{row[:id]}/delete", {})
    expect(Naaf.db[:exposed_ports][id: row[:id]]).to be_nil
  end

  it "rejects an out-of-range port and an unknown proto without writing a row" do
    login!
    nas = add_client("nas")
    post_form("/exposed-ports", "/exposed-ports", "client_id" => nas, "proto" => "tcp", "port" => "70000")
    post_form("/exposed-ports", "/exposed-ports", "client_id" => nas, "proto" => "sctp", "port" => "22")
    expect(Naaf.db[:exposed_ports].count).to be == 0
  end

  it "stores a single port as a range that starts and ends on itself" do
    login!
    nas = add_client("nas")
    post_form("/exposed-ports", "/exposed-ports",
      "client_id" => nas, "proto" => "tcp", "port" => "22")
    row = Naaf.db[:exposed_ports].first
    expect(row[:port]).to be == 22
    expect(row[:port_end]).to be == 22
  end

  it "exposes a port range in one row and shows it on the page" do
    login!
    nas = add_client("nas")
    res = post_form("/exposed-ports", "/exposed-ports",
      "client_id" => nas, "proto" => "tcp", "port" => "8000-8100", "description" => "plex")
    expect(res.status).to be == 302
    row = Naaf.db[:exposed_ports].first
    expect(row[:port]).to be == 8000
    expect(row[:port_end]).to be == 8100
    expect(get("/exposed-ports").body).to be(:include?, "8000-8100")
  end

  it "rejects a malformed or inverted range without writing a row" do
    login!
    nas = add_client("nas")
    ["8100-8000", "0-70000", "8000-", "-8000", "abc", "8000-8100-8200", "0x22", " ", "8000 - 8100"]
      .each do |port|
        post_form("/exposed-ports", "/exposed-ports",
          "client_id" => nas, "proto" => "tcp", "port" => port)
      end
    expect(Naaf.db[:exposed_ports].count).to be == 0
  end

  # The renderer would silently merge these into one interval, leaving the table
  # listing two rows that no longer describe the ruleset.
  it "refuses a range overlapping one already exposed, per protocol" do
    login!
    nas = add_client("nas")
    post_form("/exposed-ports", "/exposed-ports",
      "client_id" => nas, "proto" => "tcp", "port" => "8000-8100")

    ["8050", "8100", "8000-8100", "7000-8000", "1-65535"].each do |port|
      res = post_form("/exposed-ports", "/exposed-ports",
        "client_id" => nas, "proto" => "tcp", "port" => port)
      expect(res.status).to be == 302
    end
    expect(Naaf.db[:exposed_ports].count).to be == 1
    expect(get("/exposed-ports").body).to be(:include?, "already exposed")

    # A different protocol, and a non-overlapping neighbour, both still fit.
    post_form("/exposed-ports", "/exposed-ports",
      "client_id" => nas, "proto" => "udp", "port" => "8000-8100")
    post_form("/exposed-ports", "/exposed-ports",
      "client_id" => nas, "proto" => "tcp", "port" => "8101-8200")
    expect(Naaf.db[:exposed_ports].count).to be == 3
  end

  it "lets two clients expose the same range" do
    login!
    nas = add_client("nas")
    pi = add_client("pi")
    post_form("/exposed-ports", "/exposed-ports",
      "client_id" => nas, "proto" => "tcp", "port" => "8000-8100")
    post_form("/exposed-ports", "/exposed-ports",
      "client_id" => pi, "proto" => "tcp", "port" => "8000-8100")
    expect(Naaf.db[:exposed_ports].count).to be == 2
  end

  it "rejects an exposed port for an unknown client" do
    login!
    add_client("nas")
    post_form("/exposed-ports", "/exposed-ports", "client_id" => "9999", "proto" => "tcp", "port" => "22")
    expect(Naaf.db[:exposed_ports].count).to be == 0
  end

  it "adds a port forward enabled, toggles it, and deletes it" do
    login!
    nas = add_client("nas")
    post_form("/port-forwards", "/port-forwards",
      "client_id" => nas, "proto" => "tcp", "public_port" => "2222", "target_port" => "22")
    fwd = Naaf.db[:port_forwards].where(public_port: 2222).first
    expect(fwd[:enabled]).to be == true

    post_form("/port-forwards", "/port-forwards/#{fwd[:id]}/toggle", {})
    expect(Naaf.db[:port_forwards][id: fwd[:id]][:enabled]).to be == false

    post_form("/port-forwards", "/port-forwards/#{fwd[:id]}/delete", {})
    expect(Naaf.db[:port_forwards][id: fwd[:id]]).to be_nil
  end

  # A forward becomes a DNAT in `inet naaf` prerouting, which runs before the
  # routing decision — so a forward on a port the box answers on rewrites
  # packets addressed to the host and hands them to a client. tcp/22 takes SSH
  # away and udp/51820 stops every WireGuard handshake; together that is a
  # lockout only the provider's console recovers.
  it "refuses a port forward that would steal SSH or WireGuard from the box" do
    login!
    nas = add_client("nas")

    res = post_form("/port-forwards", "/port-forwards",
      "client_id" => nas, "proto" => "tcp", "public_port" => "22", "target_port" => "22")
    expect(Naaf.db[:port_forwards].where(public_port: 22).count).to be == 0
    expect(res.status).to be == 302
    expect(get("/port-forwards").body).to be(:include?, "SSH")

    post_form("/port-forwards", "/port-forwards",
      "client_id" => nas, "proto" => "udp", "public_port" => "51820", "target_port" => "51820")
    expect(Naaf.db[:port_forwards].where(public_port: 51820).count).to be == 0
    expect(get("/port-forwards").body).to be(:include?, "WireGuard")

    # Protocol-aware: neither of those ports is taken on the other protocol, and
    # refusing them would be a restriction with nothing behind it.
    post_form("/port-forwards", "/port-forwards",
      "client_id" => nas, "proto" => "udp", "public_port" => "22", "target_port" => "22")
    post_form("/port-forwards", "/port-forwards",
      "client_id" => nas, "proto" => "tcp", "public_port" => "51820", "target_port" => "51820")
    expect(Naaf.db[:port_forwards].count).to be == 2
  end

  # tcp/443 is only the box's while the transport is on: with wstunnel disabled
  # nothing listens there and the forward is an ordinary one.
  it "reserves the wstunnel port only while wstunnel is enabled" do
    login!
    nas = add_client("nas")

    post_form("/port-forwards", "/port-forwards",
      "client_id" => nas, "proto" => "tcp", "public_port" => "443", "target_port" => "443")
    expect(Naaf.db[:port_forwards].where(public_port: 443).count).to be == 1
    Naaf.db[:port_forwards].delete

    with_wstunnel do
      post_form("/port-forwards", "/port-forwards",
        "client_id" => nas, "proto" => "tcp", "public_port" => "443", "target_port" => "443")
      expect(Naaf.db[:port_forwards].where(public_port: 443).count).to be == 0
      expect(get("/port-forwards").body).to be(:include?, "wstunnel")
    end
  end

  # A row that predates the check — or one written straight into SQLite — must
  # not reach the kernel just because someone flipped it on.
  it "refuses to enable a disabled forward that sits on a reserved port" do
    login!
    nas = add_client("nas")
    id = Naaf.db[:port_forwards].insert(
      client_id: nas, proto: "tcp", public_port: 22, target_port: 22, enabled: false
    )

    post_form("/port-forwards", "/port-forwards/#{id}/toggle", {})
    expect(Naaf.db[:port_forwards][id: id][:enabled]).to be == false
    expect(get("/port-forwards").body).to be(:include?, "SSH")

    # Turning one OFF is always allowed, whatever port it names.
    Naaf.db[:port_forwards].where(id: id).update(enabled: true)
    post_form("/port-forwards", "/port-forwards/#{id}/toggle", {})
    expect(Naaf.db[:port_forwards][id: id][:enabled]).to be == false
  end

  it "rejects a duplicate public_port/proto forward" do
    login!
    nas = add_client("nas")
    post_form("/port-forwards", "/port-forwards",
      "client_id" => nas, "proto" => "tcp", "public_port" => "2222", "target_port" => "22")
    post_form("/port-forwards", "/port-forwards",
      "client_id" => nas, "proto" => "tcp", "public_port" => "2222", "target_port" => "80")
    expect(Naaf.db[:port_forwards].where(public_port: 2222).count).to be == 1
  end

  it "adds a normalized A record and rejects a non-IPv4 value" do
    login!
    post_form("/dns-records", "/dns-records", "name" => "Service.vpn", "value" => "10.8.0.10", "ttl" => "120")
    rec = Naaf.db[:dns_records].where(value: "10.8.0.10").first
    expect(rec[:name]).to be == "service.vpn"
    expect(rec[:rtype]).to be == "A"
    expect(rec[:ttl]).to be == 120

    post_form("/dns-records", "/dns-records", "name" => "bad.vpn", "value" => "not-an-ip")
    expect(Naaf.db[:dns_records].where(name: "bad.vpn").count).to be == 0
  end

  it "deletes a DNS record" do
    login!
    post_form("/dns-records", "/dns-records", "name" => "a.vpn", "value" => "10.8.0.11")
    id = Naaf.db[:dns_records].where(name: "a.vpn").get(:id)
    post_form("/dns-records", "/dns-records/#{id}/delete", {})
    expect(Naaf.db[:dns_records][id: id]).to be_nil
  end

  it "shows automatic client, gateway and apex records on the DNS page" do
    login!
    add_client("nas")
    body = get("/dns-records").body
    expect(body).to be(:include?, "Automatic records")
    expect(body).to be(:include?, "nas.vpn")
    expect(body).to be(:include?, "gateway.vpn")
  end

  it "flags an auto record overridden by a static record" do
    login!
    add_client("nas")
    post_form("/dns-records", "/dns-records", "name" => "nas.vpn", "value" => "10.8.0.99")
    expect(get("/dns-records").body).to be(:include?, "overridden by static")
  end

  # Renderers::WireGuard writes the name into wg0.conf as `# <name> (<host>)`,
  # so a newline in it injects lines into the file the root helper hands to
  # `wg-quick strip` — which is also how you would steer `wg` into echoing a key
  # back out through its stderr.
  it "rejects a client name carrying a newline, and never writes it" do
    login!
    body = get("/clients").body
    post("/clients", "name" => "evil\nPrivateKey = x", "hostname" => "evil", "pubkey" => "",
      "_csrf" => csrf_for(body, "/clients"))

    expect(Naaf.db[:clients].where(hostname: "evil").count).to be == 0
  end

  it "escapes a client name on the list page" do
    login!
    add_client("bob")
    Naaf.db[:clients].where(name: "bob").update(name: "<img src=x onerror=alert(1)>")

    body = get("/clients").body
    expect(body.include?("<img src=x")).to be == false
    expect(body).to be(:include?, "&lt;img src=x")
  end

  it "rejects a client hostname that is not a DNS label" do
    login!
    body = get("/clients").body
    post("/clients", "name" => "bad", "hostname" => "bad_host!", "pubkey" => "",
      "_csrf" => csrf_for(body, "/clients"))
    expect(Naaf.db[:clients].where(hostname: "bad_host!").count).to be == 0
  end

  # --- client enable/disable toggle ---

  it "toggles a client between enabled and disabled" do
    login!
    dave = add_client("dave")
    expect(Naaf.db[:clients][id: dave][:enabled]).to be == true
    post_form("/clients", "/clients/#{dave}/toggle", {})
    expect(Naaf.db[:clients][id: dave][:enabled]).to be == false
    post_form("/clients", "/clients/#{dave}/toggle", {})
    expect(Naaf.db[:clients][id: dave][:enabled]).to be == true
  end

  # --- extra (split-tunnel) routes ---

  it "redirects the new pages to /login when unauthenticated" do
    %w[/extra-routes /sites /settings].each do |path|
      res = get(path)
      expect(res.status).to be == 302
      expect(res.headers["location"]).to be == "/login"
    end
  end

  it "adds a global and a per-client route, normalizes the CIDR, and deletes one" do
    login!
    nas = add_client("nas")
    post_form("/extra-routes", "/extra-routes", "client_id" => "", "cidr" => "192.168.9.0/24")
    post_form("/extra-routes", "/extra-routes", "client_id" => nas, "cidr" => "10.99.5.3/16")
    glob = Naaf.db[:extra_routes].where(client_id: nil).first
    perc = Naaf.db[:extra_routes].where(client_id: nas).first
    expect(glob[:cidr]).to be == "192.168.9.0/24"
    expect(perc[:cidr]).to be == "10.99.0.0/16" # host bits masked to the network

    post_form("/extra-routes", "/extra-routes/#{glob[:id]}/delete", {})
    expect(Naaf.db[:extra_routes][id: glob[:id]]).to be_nil
  end

  it "rejects routes that are not valid CIDR and one for an unknown client" do
    login!
    add_client("nas")
    post_form("/extra-routes", "/extra-routes", "client_id" => "", "cidr" => "not-a-network")
    post_form("/extra-routes", "/extra-routes", "client_id" => "", "cidr" => "10.0.0.0") # no prefix
    post_form("/extra-routes", "/extra-routes", "client_id" => "9999", "cidr" => "192.168.9.0/24")
    expect(Naaf.db[:extra_routes].count).to be == 0
  end

  # --- sites (remote WireGuard servers) ---

  def site_pub = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  def site_pub2 = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBQ="

  def add_site(name: "unifi", pubkey: site_pub, host: "203.0.113.9", port: "51820",
    cidr: "192.168.1.0/24", **extra)
    fields = {
      "name" => name, "pubkey" => pubkey, "endpoint_host" => host,
      "endpoint_port" => port, "cidr" => cidr, "keepalive" => "25",
      "address" => "", "psk" => ""
    }.merge(extra.transform_keys(&:to_s))
    post_form("/sites", "/sites", fields)
  end

  it "adds a site, a second network, toggles, and deletes" do
    login!
    add_site
    site = Naaf.db[:sites].first
    expect(site[:name]).to be == "unifi"
    expect(site[:pubkey]).to be == site_pub
    expect(site[:endpoint]).to be == "203.0.113.9:51820"
    expect(site[:enabled]).to be == true
    expect(Naaf.db[:site_networks].where(site_id: site[:id]).select_map(:cidr))
      .to be == ["192.168.1.0/24"]

    post_form("/sites", "/sites/#{site[:id]}/networks", "cidr" => "10.0.0.0/16")
    expect(Naaf.db[:site_networks].where(site_id: site[:id]).select_map(:cidr).sort)
      .to be == ["10.0.0.0/16", "192.168.1.0/24"]

    post_form("/sites", "/sites/#{site[:id]}/toggle", {})
    expect(Naaf.db[:sites][id: site[:id]][:enabled]).to be == false

    net = Naaf.db[:site_networks].where(cidr: "10.0.0.0/16").first
    post_form("/sites", "/sites/#{site[:id]}/networks/#{net[:id]}/delete", {})
    expect(Naaf.db[:site_networks].where(id: net[:id]).count).to be == 0

    post_form("/sites", "/sites/#{site[:id]}/delete", {})
    expect(Naaf.db[:sites].count).to be == 0
    expect(Naaf.db[:site_networks].count).to be == 0
  end

  it "refuses a default route, a VPN-subnet overlap, IPv6, and a colliding pubkey" do
    login!
    add_client("nas", pubkey: site_pub2)
    add_site(cidr: "0.0.0.0/0")
    add_site(cidr: "10.8.0.0/24")
    add_site(cidr: "2001:db8::/32")
    add_site(pubkey: site_pub2)
    add_site(pubkey: "not-a-wireguard-key")
    expect(Naaf.db[:sites].count).to be == 0
  end

  it "refuses a site CIDR that contains the remote endpoint or overlaps another site" do
    login!
    add_site(cidr: "192.168.1.0/24")
    expect(Naaf.db[:sites].count).to be == 1
    add_site(name: "other", pubkey: site_pub2, cidr: "192.168.1.0/25")
    expect(Naaf.db[:sites].count).to be == 1
    add_site(name: "loop", pubkey: site_pub2, host: "203.0.113.9",
      cidr: "203.0.113.0/24")
    expect(Naaf.db[:sites].count).to be == 1
    # This box's own public address — would steal WAN if installed as a route.
    add_site(name: "hub", pubkey: site_pub2, host: "198.51.100.9",
      cidr: "203.0.113.0/24")
    expect(Naaf.db[:sites].count).to be == 1
  end

  it "renders the instruction banner with this box's public key" do
    login!
    body = get("/sites").body
    expect(body).to be(:include?, "SRVPUB")
    expect(body).to be(:include?, "10.8.0.0/24")
    expect(body).to be(:include?, "Sites")
  end

  it "edits an existing site's endpoint, key, keepalive and masquerade" do
    login!
    add_site
    site = Naaf.db[:sites].first
    # Same pubkey: the uniqueness check must exclude this row or a no-op
    # save (and any later field-only edit) would refuse its own key.
    post_form("/sites", "/sites/#{site[:id]}", {
      "name" => "home",
      "pubkey" => site_pub,
      "endpoint_host" => "203.0.113.9",
      "endpoint_port" => "51820",
      "keepalive" => "25",
      "address" => "",
      "psk" => ""
    })
    expect(Naaf.db[:sites][id: site[:id]][:name]).to be == "home"

    post_form("/sites", "/sites/#{site[:id]}", {
      "name" => "home",
      "pubkey" => site_pub2,
      "endpoint_host" => "unifi.example.com",
      "endpoint_port" => "51821",
      "keepalive" => "15",
      "address" => "192.168.2.2",
      "psk" => site_pub,
      "masquerade" => "on"
    })
    row = Naaf.db[:sites][id: site[:id]]
    expect(row[:name]).to be == "home"
    expect(row[:pubkey]).to be == site_pub2
    expect(row[:endpoint]).to be == "unifi.example.com:51821"
    expect(row[:keepalive]).to be == 15
    expect(row[:address]).to be == "192.168.2.2"
    expect(row[:psk]).to be == site_pub
    expect(row[:masquerade]).to be == true
    expect(Naaf.db[:site_networks].where(site_id: site[:id]).select_map(:cidr))
      .to be == ["192.168.1.0/24"]
  end

  it "refuses an edit whose new endpoint sits inside an existing site network" do
    login!
    add_site(cidr: "192.168.1.0/24")
    site = Naaf.db[:sites].first
    post_form("/sites", "/sites/#{site[:id]}", {
      "name" => "unifi",
      "pubkey" => site_pub,
      "endpoint_host" => "192.168.1.1",
      "endpoint_port" => "51820",
      "keepalive" => "25",
      "address" => "",
      "psk" => ""
    })
    expect(Naaf.db[:sites][id: site[:id]][:endpoint]).to be == "203.0.113.9:51820"
  end

  it "refuses this box's own server key as a site pubkey" do
    login!
    Naaf.db[:settings].update(server_pubkey: site_pub)
    add_site
    expect(Naaf.db[:sites].count).to be == 0
  end

  it "renders an edit form for an existing site" do
    login!
    add_site
    site = Naaf.db[:sites].first
    body = get("/sites").body
    expect(body).to be(:include?, ">Edit</summary>")
    expect(body).to be(:include?, %(action="/sites/#{site[:id]}"))
    expect(body).to be(:include?, %(value="#{site_pub}"))
  end

  # --- settings editor ---

  def save_settings(**over)
    fields = {
      "endpoint_host" => "", "endpoint_v4" => "203.0.113.9", "endpoint_v6" => "",
      "dns_upstream" => "9.9.9.9", "dns_domain" => "lan", "mtu" => "1400",
      "wan_interface" => "ens3"
    }.merge(over.transform_keys(&:to_s))
    post_form("/settings", "/settings", fields)
  end

  it "saves editable settings, and a client config then uses the new endpoint host" do
    login!
    save_settings("endpoint_host" => "sg.example.com")
    s = Naaf.settings
    expect(s[:endpoint_host]).to be == "sg.example.com"
    expect(s[:endpoint_v4]).to be == "203.0.113.9"
    expect(s[:dns_upstream]).to be == "9.9.9.9"
    expect(s[:dns_domain]).to be == "lan"
    expect(s[:mtu]).to be == 1400
    expect(s[:wan_interface]).to be == "ens3"

    nas = add_client("nas")
    conf = Naaf::ConfigBuilder.new(Naaf.db, Naaf.db[:clients][id: nas]).render("split")
    expect(conf).to be(:include?, "Endpoint = sg.example.com:51820")
  end

  it "rejects an out-of-range MTU or a bad IP without changing any setting" do
    login!
    save_settings("mtu" => "50")
    expect(Naaf.settings[:mtu]).to be == 1420
    expect(Naaf.settings[:endpoint_v4]).to be == "203.0.113.5" # unchanged whole-hog

    save_settings("endpoint_v4" => "not-an-ip")
    expect(Naaf.settings[:endpoint_v4]).to be == "203.0.113.5"
  end

  it "does not let the read-only subnet be written through the settings form" do
    login!
    save_settings("wg_subnet" => "10.9.0.0/24")
    expect(Naaf.settings[:wg_subnet]).to be == "10.8.0.0/24"
  end

  it "reports backups as disabled when they are off" do
    login!
    body = get("/settings").body
    expect(body).to be(:include?, "Last backup")
    expect(body).to be(:include?, "disabled") # test/helper.rb sets NAAF_BACKUP_ENABLED=0
  end

  it "names the newest snapshot on the settings page once one exists" do
    login!
    Dir.mktmpdir("naaf-app-backup-") do |dir|
      prev_enabled = ENV["NAAF_BACKUP_ENABLED"]
      prev_dir = ENV["NAAF_BACKUP_DIR"]
      ENV["NAAF_BACKUP_ENABLED"] = "1"
      ENV["NAAF_BACKUP_DIR"] = dir
      begin
        body = get("/settings").body
        expect(body).to be(:include?, "none yet")

        Naaf::Backup.new(Naaf.db, dir: dir, keep: 3).run!(now: Time.utc(2026, 1, 1, 12))
        expect(get("/settings").body).to be(:include?, "naaf-20260101T120000Z.db")
      ensure
        ENV["NAAF_BACKUP_ENABLED"] = prev_enabled
        ENV["NAAF_BACKUP_DIR"] = prev_dir
      end
    end
  end

  # The snapshot holds server_privkey and admin_pw_hash. There must be no route
  # that serves it, and no link inviting one to be added.
  it "offers no way to download a snapshot through the admin UI" do
    login!
    body = get("/settings").body
    expect(body).not.to be(:match?, %r{href="[^"]*backup}i)
    expect(get("/settings/backups").status).to be == 404
  end

  it "changes the admin password and swaps which password logs in" do
    login!
    post_form("/settings", "/settings/password", "password" => "newsecret123")
    @cookie = nil
    body = get("/login").body
    old = post("/login", "password" => "secret", "_csrf" => csrf_for(body, "/login"))
    expect(old.headers["location"]).to be == "/login"
    body = get("/login").body
    new = post("/login", "password" => "newsecret123", "_csrf" => csrf_for(body, "/login"))
    expect(new.headers["location"]).to be == "/"
  end

  it "rejects a too-short admin password and keeps the old one" do
    login!
    post_form("/settings", "/settings/password", "password" => "short")
    @cookie = nil
    body = get("/login").body
    res = post("/login", "password" => "secret", "_csrf" => csrf_for(body, "/login"))
    expect(res.headers["location"]).to be == "/"
  end
end
