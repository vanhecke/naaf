# frozen_string_literal: true

module WGCP
  module Schema
    def self.migrate!(db)
      db.create_table?(:settings) do
        primary_key :id
        String  :wg_interface,  null: false, default: "wg0"
        String  :wan_interface, null: false, default: "eth0"
        String  :wg_subnet,     null: false, default: "10.8.0.0/24"
        String  :server_ip,     null: false, default: "10.8.0.1"
        Integer :listen_port,   null: false, default: 51820
        String  :endpoint_v4
        String  :endpoint_v6
        String  :endpoint_host
        String  :dns_upstream,  null: false, default: "1.1.1.1"
        String  :dns_domain,    null: false, default: "vpn"
        Integer :mtu,           null: false, default: 1420
        String  :server_pubkey
        String  :server_privkey
        String  :admin_pw_hash
      end

      db.create_table?(:clients) do
        primary_key :id
        String    :name,     null: false, unique: true
        String    :hostname, null: false, unique: true
        String    :wg_ip,    null: false, unique: true
        String    :pubkey,   null: false, unique: true
        String    :psk,      null: false
        TrueClass :enabled,  null: false, default: true
        String    :notes
        DateTime  :created_at
        DateTime  :last_handshake_at
        String    :endpoint
        Bignum    :rx_bytes, default: 0
        Bignum    :tx_bytes, default: 0
      end

      # port is the range start and port_end the (inclusive) end; a single port
      # stores the same value in both. Left nullable so a fresh DB matches one
      # migrated below — SQLite cannot ADD COLUMN ... NOT NULL without a default
      # — so every reader treats NULL as "ends where it starts".
      # The unique index stays on the start alone and remains exactly right:
      # two ranges sharing a start always overlap.
      db.create_table?(:exposed_ports) do
        primary_key :id
        foreign_key :client_id, :clients, on_delete: :cascade, null: false
        String  :proto, null: false           # "tcp" | "udp"
        Integer :port,  null: false
        Integer :port_end
        String  :description
        unique [:client_id, :proto, :port]
      end

      db.create_table?(:port_forwards) do
        primary_key :id
        foreign_key :client_id, :clients, on_delete: :cascade, null: false
        Integer   :public_port, null: false
        String    :proto,       null: false
        Integer   :target_port, null: false
        TrueClass :enabled,     null: false, default: true
        unique [:public_port, :proto]
      end

      db.create_table?(:dns_records) do
        primary_key :id
        String    :name,  null: false
        String    :rtype, null: false, default: "A"
        String    :value, null: false
        Integer   :ttl,   null: false, default: 60
        TrueClass :managed, null: false, default: false
        unique [:name, :rtype, :value]
      end

      db.create_table?(:extra_routes) do
        primary_key :id
        foreign_key :client_id, :clients, on_delete: :cascade   # NULL = global
        String :cidr, null: false
      end

      alter_existing!(db)
    end

    # Idempotent column additions for databases created before a column existed.
    # create_table? only builds missing tables, so a live DB never picks these up
    # otherwise. Runs on every boot (lib/wgcp/db.rb), so each step must be a
    # no-op the second time. Plain ADD COLUMN on SQLite leaves the existing rows,
    # the unique index and the ON DELETE CASCADE intact.
    def self.alter_existing!(db)
      unless db[:exposed_ports].columns.include?(:port_end)
        db.alter_table(:exposed_ports) { add_column :port_end, Integer }
        db[:exposed_ports].where(port_end: nil).update(port_end: Sequel[:port])
      end
    end
  end
end
