# frozen_string_literal: true

require_relative "helper"
require "naaf/backup"

describe Naaf::Backup do
  def with_dir
    Dir.mktmpdir("naaf-backup-") { |dir| yield dir }
  end

  def at(hour) = Time.utc(2026, 1, 1, hour, 0, 0)

  # The load-bearing test: proves VACUUM INTO produced a consistent, complete
  # snapshot, not merely that a file appeared.
  it "writes a snapshot that opens as a database and carries every row" do
    db = reset_db!(endpoint_host: "vpn.example.com")
    make_client(db, name: "nas", wg_ip: "10.8.0.2")
    make_client(db, name: "laptop", wg_ip: "10.8.0.3")

    with_dir do |dir|
      path = Naaf::Backup.new(db, dir: dir, keep: 3).run!
      copy = Sequel.connect("sqlite://#{path}")
      begin
        expect(copy[:settings].first[:endpoint_host]).to be == "vpn.example.com"
        expect(copy[:clients].order(:wg_ip).map(:name)).to be == ["nas", "laptop"]
      ensure
        copy.disconnect
      end
    end
  end

  # A snapshot contains settings.server_privkey and admin_pw_hash. systemd's
  # default UMask=0022 would leave it 0644.
  it "writes the snapshot 0600, because it contains the server private key" do
    db = reset_db!
    with_dir do |dir|
      path = Naaf::Backup.new(db, dir: dir, keep: 3).run!
      expect(File.stat(path).mode & 0o777).to be == 0o600
    end
  end

  it "leaves no partial file behind on success" do
    db = reset_db!
    with_dir do |dir|
      Naaf::Backup.new(db, dir: dir, keep: 3).run!
      expect(Dir.glob(File.join(dir, "*.tmp"))).to be(:empty?)
    end
  end

  it "creates the backup directory when it does not exist yet" do
    db = reset_db!
    with_dir do |dir|
      nested = File.join(dir, "a", "b")
      path = Naaf::Backup.new(db, dir: nested, keep: 3).run!
      expect(File.exist?(path)).to be == true
    end
  end

  describe "rotation" do
    it "keeps exactly `keep` snapshots, newest first" do
      db = reset_db!
      with_dir do |dir|
        b = Naaf::Backup.new(db, dir: dir, keep: 3)
        (1..5).each { |h| b.run!(now: at(h)) }
        expect(b.snapshots.map { |p| File.basename(p) }).to be == [
          "naaf-20260101T030000Z.db",
          "naaf-20260101T040000Z.db",
          "naaf-20260101T050000Z.db"
        ]
      end
    end

    # Rotating before the write is what makes `keep` a ceiling rather than a
    # high-water mark, and frees a slot on a nearly-full volume before asking
    # for another file.
    it "never exceeds `keep`, even momentarily during a run" do
      db = reset_db!
      with_dir do |dir|
        b = Naaf::Backup.new(db, dir: dir, keep: 2)
        b.run!(now: at(1))
        b.run!(now: at(2))
        expect(b.snapshots.size).to be == 2
        b.run!(now: at(3))
        expect(Dir.children(dir).size).to be == 2
        expect(b.snapshots.map { |p| File.basename(p) }.first).to be == "naaf-20260101T020000Z.db"
      end
    end

    it "leaves files it did not create alone" do
      db = reset_db!
      with_dir do |dir|
        stranger = File.join(dir, "keep-me.db")
        File.write(stranger, "not ours")
        b = Naaf::Backup.new(db, dir: dir, keep: 1)
        b.run!(now: at(1))
        b.run!(now: at(2))
        expect(File.exist?(stranger)).to be == true
        expect(b.snapshots.size).to be == 1
      end
    end

    it "clears a stale partial file left by an interrupted run" do
      db = reset_db!
      with_dir do |dir|
        File.write(File.join(dir, "naaf-20250101T000000Z.db.tmp"), "junk")
        Naaf::Backup.new(db, dir: dir, keep: 3).run!(now: at(1))
        expect(Dir.glob(File.join(dir, "*.tmp"))).to be(:empty?)
      end
    end
  end

  describe "#latest" do
    it "is nil when nothing has been written yet" do
      with_dir { |dir| expect(Naaf::Backup.new(reset_db!, dir: dir, keep: 3).latest).to be_nil }
    end

    it "reports the newest snapshot's name and size" do
      db = reset_db!
      with_dir do |dir|
        b = Naaf::Backup.new(db, dir: dir, keep: 3)
        b.run!(now: at(1))
        b.run!(now: at(2))
        expect(b.latest[:name]).to be == "naaf-20260101T020000Z.db"
        expect(b.latest[:bytes]).to be > 0
      end
    end
  end

  describe "failure" do
    it "raises without destroying the snapshot already on disk" do
      skip "runs as root; the mode would not be enforced" if Process.uid.zero?
      db = reset_db!
      with_dir do |dir|
        b = Naaf::Backup.new(db, dir: dir, keep: 3)
        good = b.run!(now: at(1))
        File.chmod(0o500, dir)
        begin
          expect { b.run!(now: at(2)) }.to raise_exception(Exception)
          expect(File.exist?(good)).to be == true
        ensure
          File.chmod(0o700, dir)
        end
      end
    end

    # The seam that makes "a failed backup never takes down the reactor" testable
    # rather than a comment on the loop in bin/naaf.
    it "is swallowed by tick! so the reactor loop survives it" do
      boom = Object.new
      def boom.run! = raise("nope")
      expect(Naaf::Backup.tick!(boom)).to be_nil
    end
  end

  # The Litestream-safety claim, tested: VACUUM INTO must not touch the source.
  it "leaves the source untouched, still in WAL mode, still writable" do
    db = reset_db!
    before = db.fetch("PRAGMA journal_mode").single_value
    with_dir do |dir|
      Naaf::Backup.new(db, dir: dir, keep: 3).run!
      expect(db.fetch("PRAGMA journal_mode").single_value).to be == before
      expect(db[:settings].count).to be == 1
      make_client(db, name: "after", wg_ip: "10.8.0.9")
      expect(db[:clients].count).to be == 1
    end
  end
end
