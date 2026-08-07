# frozen_string_literal: true

require "fileutils"
require "console"
require_relative "config"

module Naaf
  # Point-in-time snapshots of the SQLite database, taken in-process on the
  # shared reactor.
  #
  # The database is the whole system: it holds the server private key, every
  # peer, and every firewall rule. Losing it means re-enrolling every client by
  # hand, which for a QR-provisioned phone means physically handling the device.
  #
  # VACUUM INTO is read-only with respect to the source — it runs in a read
  # transaction, takes no write lock, checkpoints nothing, and rewrites no page —
  # so it is safe to run underneath Litestream. Three things must NEVER replace
  # it here:
  #   * bare VACUUM        pushes every page through the WAL as one transaction
  #                        and invalidates Litestream's tracking
  #   * wal_checkpoint     Litestream manages checkpoints; a second manager
  #                        corrupts its view
  #   * cp of the live .db without the -wal is a torn read
  class Backup
    STAMP = "%Y%m%dT%H%M%SZ" # same format as deploy/run-remote.sh's ts()
    NAME = /\Anaaf-\d{8}T\d{6}Z\.db\z/

    # Log a warning if a snapshot blocks the reactor longer than this. The
    # database is a settings row plus tens of clients and rules, so a snapshot is
    # single-digit milliseconds — two orders of magnitude below what
    # Reconciler#apply! already blocks for. This exists so that if the assumption
    # ever stops holding it shows up in the journal rather than as mystery DNS
    # latency.
    SLOW_MS = 250

    attr_reader :dir, :keep

    def initialize(db, dir: Config["NAAF_BACKUP_DIR"], keep: Config.int("NAAF_BACKUP_KEEP"))
      @db = db
      @dir = dir
      @keep = keep
    end

    # Returns the path written. `now` is injectable so filenames are
    # deterministic in tests.
    def run!(now: Time.now.utc)
      FileUtils.mkdir_p(@dir)
      # Rotate to keep-1 BEFORE writing, so `keep` is a hard ceiling on disk use
      # and a nearly-full volume gets a slot freed before we ask for another file.
      rotate!(@keep - 1)

      final = File.join(@dir, "naaf-#{now.strftime(STAMP)}.db")
      tmp = "#{final}.tmp"
      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        # VACUUM INTO refuses an existing target, and an interrupted run leaves a
        # file that may be incomplete. Writing to .tmp and renaming closes both:
        # rename within a filesystem is atomic, so no reader ever sees a partial
        # snapshot, and a crashed run leaves only a .tmp the next rotate removes.
        FileUtils.rm_f(tmp)
        @db.run("VACUUM INTO #{@db.literal(tmp)}")
        # SQLite creates the file 0644 under systemd's default umask. It contains
        # server_privkey and admin_pw_hash — narrow it before it is reachable
        # under its final name.
        File.chmod(0o600, tmp)
        File.rename(tmp, final)
      ensure
        FileUtils.rm_f(tmp)
      end

      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - began) * 1000).round
      Console.info(self, "backup written", path: final, bytes: File.size(final), ms: ms)
      Console.warn(self, "backup blocked the reactor for an unexpectedly long time", ms: ms) if ms > SLOW_MS
      final
    end

    def snapshots = Dir.glob(File.join(@dir, "naaf-*.db")).select { |p| NAME.match?(File.basename(p)) }.sort

    def latest
      path = snapshots.last or return nil
      {name: File.basename(path), bytes: File.size(path), mtime: File.mtime(path)}
    end

    # Only files matching NAME are ever deleted, so an operator's own file in the
    # directory is left alone. Timestamps are UTC basic ISO-8601, so a lexical
    # sort is chronological.
    def rotate!(keep = @keep)
      Dir.glob(File.join(@dir, "*.tmp")).each { |f| FileUtils.rm_f(f) }
      excess = keep.positive? ? snapshots[0...-keep].to_a : snapshots
      excess.each { |f| FileUtils.rm_f(f) }
      excess.size
    end

    # The reactor loop body. The rescue lives here rather than inline in bin/naaf
    # so "a failed backup never takes down the reactor" is a tested claim.
    # StandardError covers Sequel::DatabaseError, SQLite3::* and Errno::ENOSPC
    # while letting Async::Stop (an Exception) through, so task shutdown works.
    def self.tick!(backup)
      backup.run!
    rescue => e
      Console.error(backup, "backup failed", exception: e)
      nil
    end
  end
end
