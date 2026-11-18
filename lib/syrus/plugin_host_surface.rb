require "yaml"

module Syrus
  class PluginHostSurface
    Entry = Data.define(:name, :tier, :since, :notes)
    TIERS = %w[public legacy].freeze
    DEFAULT_PATH = Rails.root.join("config/plugin_host_surface.yml")

    attr_reader :legacy_baseline

    def initialize(path: DEFAULT_PATH)
      data = YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}
      @legacy_baseline = Integer(data.fetch("legacy_baseline"))
      @entries = Array(data.fetch("constants")).map { |attributes| build_entry(attributes) }
      validate!
      @by_name = @entries.to_h { |entry| [ entry.name, entry ] }
    rescue KeyError, ArgumentError, TypeError => e
      raise ArgumentError, "invalid plugin host surface: #{e.message}"
    end

    def entries = @entries.dup
    def lookup(name) = @by_name[name.to_s]
    def legacy_entries = @entries.select { |entry| entry.tier == "legacy" }

    private

    def build_entry(attributes)
      Entry.new(
        name: attributes.fetch("name").to_s,
        tier: attributes.fetch("tier").to_s,
        since: attributes["since"]&.to_s,
        notes: attributes["notes"]&.to_s
      )
    end

    def validate!
      invalid = @entries.reject { |entry| TIERS.include?(entry.tier) }
      raise ArgumentError, "unknown tier for #{invalid.map(&:name).join(', ')}" if invalid.any?

      missing_since = @entries.select { |entry| entry.tier == "public" && entry.since.to_s.empty? }
      raise ArgumentError, "public entries require since: #{missing_since.map(&:name).join(', ')}" if missing_since.any?

      duplicates = @entries.group_by(&:name).select { |_name, entries| entries.many? }.keys
      raise ArgumentError, "duplicate names: #{duplicates.join(', ')}" if duplicates.any?
    end
  end
end
