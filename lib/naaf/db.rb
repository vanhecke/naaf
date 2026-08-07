# frozen_string_literal: true

require "sequel"
require_relative "../../db/schema"

module Naaf
  def self.db
    @db ||= begin
      path = ENV.fetch("NAAF_DB", "/var/lib/naaf/naaf.db")
      db = Sequel.connect("sqlite://#{path}")
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
