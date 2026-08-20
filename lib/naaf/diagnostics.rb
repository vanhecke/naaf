# frozen_string_literal: true

require "async/semaphore"
require_relative "config"

module Naaf
  # ping, traceroute and curl, run from the web process.
  #
  # This is the one exception to "no command on the web or DNS path", and it is
  # narrow on purpose: three unprivileged binaries, reached by absolute path,
  # invoked as an argv array, bounded by a semaphore, hard-killed on a deadline,
  # and removable with NAAF_DIAG_ENABLED=0. The root helper's vocabulary is
  # unchanged at four commands — running these behind the socket would be
  # strictly worse, because it would widen a privilege boundary to gain nothing
  # (Debian ships /usr/bin/ping with cap_net_raw+ep, traceroute's default UDP
  # mode needs no privilege, and curl needs none). A FOURTH binary here is an
  # AGENTS.md "Ask first".
  #
  # Falcon, Roda and async-dns share one reactor in one process, so a blocking
  # ten-second read would freeze the admin UI, the resolver and the reconciler
  # together. Every wait below is a fiber wait.
  module Diagnostics
    Result = Data.define(:argv, :output, :status, :seconds, :timed_out, :unavailable)

    # Absolute paths, resolved from a candidate list at call time. Never PATH:
    # this process inherits systemd's, and an absolute path cannot be shadowed.
    # Debian has moved these between /bin and /usr/bin across releases.
    BINARIES = {
      ping: %w[/usr/bin/ping /bin/ping],
      traceroute: %w[/usr/bin/traceroute /usr/sbin/traceroute],
      curl: %w[/usr/bin/curl /bin/curl]
    }.freeze

    MAX_OUTPUT = 64 * 1024
    READ_CHUNK = 16 * 1024
    # Long enough for traceroute to flush a partial trace on TERM, short enough
    # that a stuck tool is not holding a semaphore slot for a noticeable time.
    GRACE = 0.2

    TIMEOUT = Config.int("NAAF_DIAG_TIMEOUT")

    # Process-wide. A browser tab retrying a request must not be able to fork a
    # box that also routes everyone's traffic.
    GATE = Async::Semaphore.new(Config.int("NAAF_DIAG_CONCURRENCY"))

    def self.enabled? = Config.bool("NAAF_DIAG_ENABLED")

    def self.resolve(tool) = BINARIES.fetch(tool).find { |path| File.executable?(path) }

    # `tool` is a key of BINARIES and `argv` comes from one of the builders
    # below, so nothing here is a caller-supplied program name.
    def self.run(tool, argv)
      bin = resolve(tool)
      unless bin
        return Result.new(argv: [tool.to_s, *argv], output: "", status: nil,
          seconds: 0.0, timed_out: false, unavailable: true)
      end
      GATE.acquire { capture(bin, argv) }
    end

    # The primitive. Public so a test can drive the spawn/timeout/reap path
    # against a binary that exists everywhere; the application only ever reaches
    # it through .run.
    def self.capture(bin, argv)
      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out = +""
      timed_out = false
      status = nil
      read_end, write_end = IO.pipe
      # in: :close so the child cannot inherit anything to read from. stderr is
      # folded into stdout because everything interesting curl -v says is on
      # stderr. pgroup so the kill below also reaches whatever the tool spawned.
      pid = Process.spawn(bin, *argv, in: :close, out: write_end,
        err: [:child, :out], pgroup: true)
      # Ours must be closed or EOF never arrives on the read end.
      write_end.close
      begin
        with_timeout do
          begin
            loop do
              chunk = read_end.readpartial(READ_CHUNK)
              out << chunk if out.bytesize < MAX_OUTPUT
            end
          rescue EOFError
            # The child closed stdout; it is exiting.
          end
          status = Process.wait2(pid)&.last
        end
      rescue Async::TimeoutError
        timed_out = true
      ensure
        status ||= stop!(pid)
        read_end.close
      end

      Result.new(argv: [bin, *argv], output: scrub(out), status: status,
        seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - began,
        timed_out: timed_out, unavailable: false)
    end

    # Negative pid = the whole process group. TERM first, because traceroute
    # prints a partial trace on TERM and that is worth having; then KILL
    # unconditionally, because a tool that ignores TERM must not outlive the
    # request. Always reaped afterwards: one zombie per timed-out run would
    # accumulate in a process expected to stay up for months.
    def self.stop!(pid)
      signal!(pid, "-TERM")
      Fiber.scheduler&.kernel_sleep(GRACE)
      signal!(pid, "-KILL")
      Process.wait2(pid)&.last
    rescue Errno::ECHILD
      nil
    end

    # ESRCH is "already gone". EPERM is the same thing on BSD and macOS once the
    # group's last member is a zombie this process has not reaped yet, which is
    # exactly the state TERM leaves behind. Signalling is pointless either way,
    # and neither is a reason to skip the reap.
    def self.signal!(pid, signal)
      Process.kill(signal, pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # Fiber.scheduler#with_timeout only fires while blocked on IO, which is
    # exactly what readpartial and wait2 do under the reactor, and it is nil
    # outside one — so the pure argv tests still run without a reactor, and
    # bin/naaf always has it.
    def self.with_timeout
      scheduler = Fiber.scheduler or return yield
      scheduler.with_timeout(TIMEOUT) { yield }
    end

    # This is remote text on its way to the admin's browser: curl -v echoes a
    # server banner verbatim, and a traceroute prints whatever a PTR record
    # says. Force it to valid UTF-8 so the template's h() has something it can
    # escape, and cap it so one command cannot fill a response.
    def self.scrub(text)
      out = text.dup.force_encoding(Encoding::UTF_8).scrub("?")
      return out if out.bytesize <= MAX_OUTPUT
      out.byteslice(0, MAX_OUTPUT).to_s.scrub("?") +
        "\n\n[truncated at #{MAX_OUTPUT} bytes]"
    end

    # -w is a deadline, not a timeout: ping exits at 8s even with a reply still
    # outstanding. The kill in .capture is the backstop, not the mechanism — a
    # tool that ends on its own prints its summary line.
    def self.ping_argv(host) = ["-n", "-c", "3", "-W", "2", "-w", "8", host]

    # -q 1 so a 12-hop trace cannot 3x-probe its way past the deadline on a
    # lossy path, which is exactly the path someone runs this on.
    def self.traceroute_argv(host) = ["-n", "-q", "1", "-m", "12", "-w", "1", host]

    # Composed server-side from the validated parts, never from a free-form
    # string: the parts are what were checked. `tcp` is a bare connect — the
    # question an operator actually has is "can I reach this ip/port at all",
    # which neither http nor https answers without also being served.
    def self.curl_url(host:, port:, scheme:, path: "/")
      return "telnet://#{host}:#{port}" if scheme == "tcp"
      "#{scheme}://#{host}:#{port}#{path}"
    end

    # --proto pins what curl may be talked into speaking, so file://, dict://
    # and gopher:// are refused by curl itself as well as by the scheme
    # whitelist in app.rb. Belt and braces, deliberately.
    def self.curl_argv(url, scheme:, insecure: false)
      proto = (scheme == "tcp") ? "=telnet" : "=http,https"
      argv = ["-sS", "-v", "-o", "/dev/null", "--proto", proto,
        "--connect-timeout", "4", "--max-time", "8", "--no-progress-meter"]
      argv << "-k" if insecure && scheme == "https"
      argv << url
    end
  end
end
