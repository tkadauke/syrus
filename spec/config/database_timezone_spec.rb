# frozen_string_literal: true

require "rails_helper"
require "erb"
require "yaml"

# Active Record writes timestamps from Ruby in UTC, but `insert_all` /
# `upsert_all` do not: ActiveRecord's MySQL adapter defines
# HIGH_PRECISION_CURRENT_TIMESTAMP as the literal SQL `CURRENT_TIMESTAMP(6)`,
# which MySQL evaluates in the session time zone. Left at SYSTEM, the database
# container's local zone wins and bulk-inserted rows land hours away from every
# row written through Ruby.
#
# Production showed solid_queue_claimed_executions.created_at exactly 4h behind
# UTC_TIMESTAMP() while runs.updated_at and solid_queue_jobs.created_at were
# correct. Syrus's own ChatMessage.insert_all! and Observability::EventStream
# writes take the same path, so chat and observability timestamps skew too.
RSpec.describe "database time zone" do
  def production_config
    raw = File.read(Rails.root.join("config/database.yml"))
    # config/database.yml serves SQLite when SYRUS_SQLITE is set; force the
    # MySQL branch so this spec reads the deploy-target configuration.
    previous = ENV["SYRUS_SQLITE"]
    ENV.delete("SYRUS_SQLITE")
    YAML.safe_load(ERB.new(raw).result, aliases: true).fetch("production")
  ensure
    ENV["SYRUS_SQLITE"] = previous
  end

  it "pins every MySQL connection's session time zone to UTC" do
    mysql_connections = production_config.select { |_name, cfg| cfg.is_a?(Hash) && cfg["adapter"] == "mysql2" }

    expect(mysql_connections).not_to be_empty, "expected the production config to define mysql2 connections"

    unpinned = mysql_connections.reject do |_name, cfg|
      cfg.dig("variables", "time_zone").to_s == "+00:00"
    end

    message = "these MySQL connections do not pin time_zone to UTC, so insert_all " \
              "timestamps will follow the server's local zone: #{unpinned.keys.join(', ')}"
    expect(unpinned).to be_empty, message
  end

  it "keeps the lock-wait ceiling alongside the time zone on every MySQL connection" do
    mysql_connections = production_config.select { |_name, cfg| cfg.is_a?(Hash) && cfg["adapter"] == "mysql2" }

    mysql_connections.each do |name, cfg|
      expect(cfg.dig("variables", "innodb_lock_wait_timeout")).to eq(10),
        "#{name} lost the innodb_lock_wait_timeout ceiling"
    end
  end
end
