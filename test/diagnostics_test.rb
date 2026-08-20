# frozen_string_literal: true

require_relative "helper"
require "sus/fixtures/async"
require "naaf/diagnostics"

# Two halves. The argv builders are pure and are checked without a reactor; the
# spawn/timeout/reap path is exactly the part that must never block the shared
# reactor, so it is driven under one.
# A binary that exists on every host this suite runs on, and whose behaviour can
# be dictated per example. Nothing here shells out to the network.
SH = %w[/bin/sh /usr/bin/sh].find { |candidate| File.executable?(candidate) }

describe Naaf::Diagnostics do
  describe "argv construction" do
    # -w is a deadline, not a timeout: without it ping waits for a reply that
    # may never come, and the kill in .capture would be the only thing ending
    # the run -- losing the summary line, which is the useful part.
    it "gives ping a count, a per-reply wait and a hard deadline" do
      expect(Naaf::Diagnostics.ping_argv("192.168.1.1"))
        .to be == ["-n", "-c", "3", "-W", "2", "-w", "8", "192.168.1.1"]
    end

    it "gives traceroute one probe per hop so twelve hops fit in the deadline" do
      argv = Naaf::Diagnostics.traceroute_argv("1.1.1.1")
      expect(argv).to be == ["-n", "-q", "1", "-m", "12", "-w", "1", "1.1.1.1"]
    end

    # The host is always the LAST element. Anything else would let a value that
    # looked like a flag land where curl reads options.
    it "puts the host last in every builder" do
      expect(Naaf::Diagnostics.ping_argv("h").last).to be == "h"
      expect(Naaf::Diagnostics.traceroute_argv("h").last).to be == "h"
      expect(Naaf::Diagnostics.curl_argv("http://h:80/", scheme: "http").last)
        .to be == "http://h:80/"
    end
  end

  describe "curl composition" do
    # Assembled server-side from validated parts. A free-form URL string would
    # be a different value from the one that was checked.
    it "composes a bare TCP connect as a telnet url" do
      expect(Naaf::Diagnostics.curl_url(host: "10.8.0.2", port: 443, scheme: "tcp"))
        .to be == "telnet://10.8.0.2:443"
    end

    it "composes http and https with the port and path" do
      expect(Naaf::Diagnostics.curl_url(host: "10.8.0.2", port: 8080, scheme: "http", path: "/x"))
        .to be == "http://10.8.0.2:8080/x"
      expect(Naaf::Diagnostics.curl_url(host: "h", port: 443, scheme: "https", path: "/"))
        .to be == "https://h:443/"
    end

    it "pins --proto per scheme, so file:// and gopher:// are refused by curl too" do
      expect(Naaf::Diagnostics.curl_argv("telnet://h:443", scheme: "tcp"))
        .to be(:include?, "=telnet")
      expect(Naaf::Diagnostics.curl_argv("https://h:443/", scheme: "https"))
        .to be(:include?, "=http,https")
    end

    it "only passes -k for https, never for a bare connect" do
      expect(Naaf::Diagnostics.curl_argv("https://h:443/", scheme: "https", insecure: true))
        .to be(:include?, "-k")
      expect(Naaf::Diagnostics.curl_argv("telnet://h:443", scheme: "tcp", insecure: true))
        .not.to be(:include?, "-k")
      expect(Naaf::Diagnostics.curl_argv("https://h:443/", scheme: "https", insecure: false))
        .not.to be(:include?, "-k")
    end
  end

  describe "a missing binary" do
    # A box provisioned before traceroute was added to 10-packages.sh must get a
    # sentence telling it to re-run ./deploy.sh, not a 500.
    it "reports unavailable rather than raising, so the page never 500s" do
      original = Naaf::Diagnostics.method(:resolve)
      Naaf::Diagnostics.define_singleton_method(:resolve) { |_tool| nil }
      result = Naaf::Diagnostics.run(:traceroute, ["-n", "1.1.1.1"])

      expect(result.unavailable).to be == true
      expect(result.output).to be(:empty?)
      expect(result.status).to be_nil
      expect(result.timed_out).to be == false
    ensure
      Naaf::Diagnostics.define_singleton_method(:resolve, original)
    end

    # PATH is never consulted: this process inherits systemd's, and an absolute
    # path cannot be shadowed.
    it "only ever resolves to an absolute path from the candidate list" do
      Naaf::Diagnostics::BINARIES.each do |tool, candidates|
        found = Naaf::Diagnostics.resolve(tool)
        next if found.nil?
        expect(candidates).to be(:include?, found)
        expect(found.start_with?("/")).to be == true
      end
    end
  end

  describe "output scrubbing" do
    it "forces invalid bytes to UTF-8 so h() has something it can escape" do
      out = Naaf::Diagnostics.scrub("banner \xff\xfe bytes".b)
      expect(out.encoding).to be == Encoding::UTF_8
      expect(out.valid_encoding?).to be == true
    end

    it "truncates at MAX_OUTPUT and says so" do
      out = Naaf::Diagnostics.scrub("x" * (Naaf::Diagnostics::MAX_OUTPUT + 5000))
      expect(out).to be(:include?, "[truncated at #{Naaf::Diagnostics::MAX_OUTPUT} bytes]")
      expect(out.bytesize < Naaf::Diagnostics::MAX_OUTPUT + 100).to be == true
    end

    it "leaves output that fits exactly alone" do
      expect(Naaf::Diagnostics.scrub("short")).to be == "short"
    end
  end

  # Falcon, Roda and async-dns share one reactor in one process. Every wait here
  # has to be a fiber wait, or a ten-second traceroute freezes the admin UI, the
  # resolver and the reconciler together.
  describe "the runner" do
    include Sus::Fixtures::Async::ReactorContext

    it "captures output and the exit status" do
      result = Naaf::Diagnostics.capture(SH, ["-c", "echo hello; exit 3"])
      expect(result.output).to be(:include?, "hello")
      expect(result.status.exitstatus).to be == 3
      expect(result.timed_out).to be == false
      expect(result.unavailable).to be == false
    end

    it "folds stderr into stdout, because curl -v says everything there" do
      result = Naaf::Diagnostics.capture(SH, ["-c", "echo out; echo err 1>&2"])
      expect(result.output).to be(:include?, "out")
      expect(result.output).to be(:include?, "err")
    end

    it "kills a run that outlives the deadline, keeps its partial output, and reaps it" do
      # A shell that prints and then sleeps far past NAAF_DIAG_TIMEOUT. Its own
      # deadline is what a real tool would have; this one deliberately has none.
      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Naaf::Diagnostics.capture(SH, ["-c", "echo starting; sleep 120"])
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - began

      expect(result.timed_out).to be == true
      expect(result.output).to be(:include?, "starting")
      # Inside the deadline plus the TERM grace, with room for a slow CI box.
      expect(elapsed < Naaf::Diagnostics::TIMEOUT + 3).to be == true
      # No zombie: .capture always reaps, whichever way the run ended.
      expect { Process.waitpid(-1, Process::WNOHANG) }.to raise_exception(Errno::ECHILD)
    end

    # A browser tab retrying a request must not be able to fork a box that also
    # routes everyone's traffic. curl is a hard dependency of this project
    # (deploy/provision/10-packages.sh installs it), so leaning on it here is
    # safe -- and `--version` spawns without touching the network.
    it "makes a run wait when every concurrency slot is taken" do
      limit = Naaf::Diagnostics::GATE.limit
      expect(limit).to be == Naaf::Config.int("NAAF_DIAG_CONCURRENCY")
      expect(Naaf::Diagnostics.resolve(:curl).nil?).to be == false

      holders = limit.times.map { Async { Naaf::Diagnostics::GATE.acquire { sleep 0.3 } } }
      sleep 0.05
      expect(Naaf::Diagnostics::GATE.count).to be == limit

      finished = false
      queued = Async do
        Naaf::Diagnostics.run(:curl, ["--version"])
        finished = true
      end
      sleep 0.05
      expect(finished).to be == false

      holders.each(&:wait)
      queued.wait
      expect(finished).to be == true
    end
  end
end
