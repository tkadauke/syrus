# frozen_string_literal: true

require "rails_helper"
require "erb"
require "yaml"

# The macOS worker reaches MySQL through `kubectl port-forward`. A forwarded
# stream can die without the local socket being reset, and with no read
# timeout a query on that connection waits forever -- an MCP tool call hung
# past the agent's 120s limit that way. bin/macos-worker sets the DB_*_TIMEOUT
# variables; cluster pods leave them unset and keep the driver defaults.
RSpec.describe "database socket timeouts" do
  TIMEOUT_VARS = %w[DB_CONNECT_TIMEOUT DB_READ_TIMEOUT DB_WRITE_TIMEOUT].freeze

  def production_config(env)
    raw = File.read(Rails.root.join("config/database.yml"))
    previous = (TIMEOUT_VARS + [ "SYRUS_SQLITE" ]).to_h { |key| [ key, ENV[key] ] }
    ENV.delete("SYRUS_SQLITE")
    TIMEOUT_VARS.each { |key| ENV.delete(key) }
    env.each { |key, value| ENV[key] = value }
    YAML.safe_load(ERB.new(raw).result, aliases: true).fetch("production")
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def mysql_connections(config)
    config.select { |_name, cfg| cfg.is_a?(Hash) && cfg["adapter"] == "mysql2" }
  end

  it "applies the socket timeouts to every MySQL connection when the worker sets them" do
    config = production_config("DB_CONNECT_TIMEOUT" => "10", "DB_READ_TIMEOUT" => "30", "DB_WRITE_TIMEOUT" => "30")

    expect(mysql_connections(config)).not_to be_empty
    mysql_connections(config).each do |name, cfg|
      expect(cfg.slice("connect_timeout", "read_timeout", "write_timeout")).to eq(
        "connect_timeout" => 10, "read_timeout" => 30, "write_timeout" => 30
      ), "#{name} did not pick up the worker's socket timeouts"
    end
  end

  it "leaves the driver defaults alone when nothing sets them" do
    mysql_connections(production_config({})).each do |name, cfg|
      expect(cfg.keys & %w[connect_timeout read_timeout write_timeout]).to be_empty, "#{name} gained a timeout nobody asked for"
    end
  end
end
