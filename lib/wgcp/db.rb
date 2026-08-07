# frozen_string_literal: true

require "sequel"
require_relative "../../db/schema"

module WGCP
  def self.db
    @db ||= begin
      path = ENV.fetch("WGCP_DB", "/var/lib/wgcp/wgcp.db")
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
