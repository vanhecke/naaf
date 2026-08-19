# frozen_string_literal: true

require_relative "helper"

describe "Naaf.db" do
  # Litestream refuses a database that is not in WAL mode and asks for
  # busy_timeout ≈ 5000 ms so its checkpoints are not blocked. Both are
  # load-bearing; a "tidy" that drops them is a silent replica death.
  it "opens in WAL with foreign keys and a 5000 ms busy timeout" do
    db = Naaf.db
    expect(db.fetch("PRAGMA journal_mode").single_value.downcase).to be == "wal"
    expect(db.fetch("PRAGMA busy_timeout").single_value).to be == 5000
    expect(db.fetch("PRAGMA foreign_keys").single_value).to be == 1
  end

  it "has no private-key column on clients — keys are generated, shown once, never stored" do
    cols = Naaf.db[:clients].columns.map(&:to_s)
    expect(cols.grep(/privkey|private_key/i)).to be(:empty?)
  end
end
