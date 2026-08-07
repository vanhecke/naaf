# frozen_string_literal: true

require "sequel"
require_relative "config"
require_relative "../../db/schema"

module Naaf
  def self.db
    @db ||= begin
      path = Config["NAAF_DB"]
      db = Sequel.connect("sqlite://#{path}")
      # Both pragmas below are load-bearing for Litestream and must not be
      # "tidied away": it refuses to replicate a database that is not in WAL
      # mode, and its own docs ask for busy_timeout ≈ 5000 ms so its checkpoints
      # are not blocked. See docs/BACKUP.md.
      db.run "PRAGMA journal_mode = WAL"
      db.run "PRAGMA foreign_keys = ON"
      db.run "PRAGMA busy_timeout = 5000"
      Schema.migrate!(db)
      db
    end
  end

  def self.settings
    db[:settings].first || begin
      db[:settings].insert({})
      db[:settings].first
    end
  end
end
