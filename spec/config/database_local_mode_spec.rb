require "rails_helper"
require "erb"
require "yaml"

# Guards the SYRUS_SQLITE single-host "local mode" branch in config/database.yml
# (Docker Compose on a laptop) without disturbing the MySQL production config
# used by the k3s deploy.
RSpec.describe "config/database.yml local SQLite mode" do
  def render_database_config(env)
    original = ENV.to_h
    %w[SYRUS_SQLITE SYRUS_DATA_ROOT SEARCH_DATABASE_PATH].each { |key| ENV.delete(key) }
    env.each { |key, value| ENV[key] = value }
    yaml = ERB.new(File.read(Rails.root.join("config/database.yml"))).result
    YAML.safe_load(yaml, aliases: true)
  ensure
    ENV.replace(original)
  end

  it "points all four production databases at SQLite files under SYRUS_DATA_ROOT" do
    config = render_database_config("SYRUS_SQLITE" => "1", "SYRUS_DATA_ROOT" => "/data")
    production = config.fetch("production")

    %w[primary cache queue cable search].each do |name|
      expect(production.dig(name, "adapter")).to eq("sqlite3")
    end
    expect(production.dig("primary", "database")).to eq("/data/db/production.sqlite3")
    expect(production.dig("cache", "database")).to eq("/data/db/production_cache.sqlite3")
    expect(production.dig("queue", "database")).to eq("/data/db/production_queue.sqlite3")
    expect(production.dig("cable", "database")).to eq("/data/db/production_cable.sqlite3")
    expect(production.dig("search", "database")).to eq("/data/search.sqlite3")
    # Each Solid* DB keeps its own migrations path.
    expect(production.dig("queue", "migrations_paths")).to eq("db/queue_migrate")
    expect(production.dig("search", "migrations_paths")).to eq("db/search_migrate")
    expect(production.dig("search", "schema_dump")).to be(false)
  end

  it "keeps MySQL for production when SYRUS_SQLITE is not set" do
    config = render_database_config({})

    expect(config.dig("production", "primary", "adapter")).to eq("mysql2")
    expect(config.dig("production", "cache", "adapter")).to eq("mysql2")
    expect(config.dig("production", "search", "adapter")).to eq("sqlite3")
  end

  it "allows production database pools to be capped independently of Rails thread count" do
    config = render_database_config("DB_POOL" => "4", "RAILS_MAX_THREADS" => "20")

    expect(config.dig("production", "primary", "pool")).to eq(4)
    expect(config.dig("production", "cache", "pool")).to eq(4)
    expect(config.dig("production", "queue", "pool")).to eq(4)
    expect(config.dig("production", "cable", "pool")).to eq(4)
    expect(config.dig("production", "search", "pool")).to eq(4)
  end

  it "leaves development and test on SQLite regardless" do
    config = render_database_config("SYRUS_SQLITE" => "1", "SYRUS_DATA_ROOT" => "/data")

    expect(config.dig("development", "primary", "adapter")).to eq("sqlite3")
    expect(config.dig("test", "primary", "adapter")).to eq("sqlite3")
    expect(config.dig("test", "search", "adapter")).to eq("sqlite3")
    expect(config.dig("test", "search", "database_tasks")).to be(false)
  end

  it "ships non-empty Solid Cache, Queue, and Cable schemas for local-mode db:prepare" do
    cache_schema = Rails.root.join("db/cache_schema.rb").read
    queue_schema = Rails.root.join("db/queue_schema.rb").read
    cable_schema = Rails.root.join("db/cable_schema.rb").read

    expect(cache_schema).to include('create_table "solid_cache_entries"')
    expect(cache_schema).to include('name: "index_solid_cache_entries_on_key_hash", unique: true')
    expect(queue_schema).to include('create_table "solid_queue_jobs"')
    expect(queue_schema).to include('create_table "solid_queue_ready_executions"')
    expect(cable_schema).to include('create_table "solid_cable_messages"')
  end
end
