require "yaml"
require "rubygems/version"

module Syrus
  class PluginHostSurface
    Entry = Data.define(:name)
    DEFAULT_PATH = Pathname.new(File.expand_path("../../config/plugin_host_surface.yml", __dir__))

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
    def public_entries = @entries.select { |entry| entry.tier == "public" }

    private

    def build_entry(attributes)
      Entry.new(
        name: attributes.fetch("name").to_s,
        tier: attributes.fetch("tier").to_s,
        since: attributes["since"]&.to_s,
        contract: attributes["contract"]&.to_s,
        members: normalize_members(attributes["members"])
      )
    end

    def normalize_members(value)
      Hash(value || {}).to_h do |kind, names|
        [ kind.to_s, Array(names).map(&:to_s).freeze ]
      end.freeze
    end

    def validate!
      invalid = @entries.reject { |entry| TIERS.include?(entry.tier) }
      raise ArgumentError, "unknown tier for #{invalid.map(&:name).join(', ')}" if invalid.any?

      missing_since = @entries.select { |entry| entry.tier == "public" && entry.since.to_s.empty? }
      raise ArgumentError, "public entries require since: #{missing_since.map(&:name).join(', ')}" if missing_since.any?

      invalid_since = @entries.select do |entry|
        entry.tier == "public" && !entry.since.to_s.empty? && !Gem::Version.correct?(entry.since)
      end
      raise ArgumentError, "public entries require valid since: #{invalid_since.map(&:name).join(', ')}" if invalid_since.any?

      missing_contract = @entries.select { |entry| entry.tier == "public" && entry.contract.to_s.strip.empty? }
      raise ArgumentError, "public entries require contract: #{missing_contract.map(&:name).join(', ')}" if missing_contract.any?

      invalid_member_kinds = @entries.flat_map do |entry|
        entry.members.keys.reject { |kind| %w[class instance].include?(kind) }.map { |kind| "#{entry.name}.#{kind}" }
      end
      raise ArgumentError, "unknown member kinds: #{invalid_member_kinds.join(', ')}" if invalid_member_kinds.any?

      duplicates = @entries.group_by(&:name).select { |_name, entries| entries.many? }.keys
      raise ArgumentError, "duplicate names: #{duplicates.join(', ')}" if duplicates.any?
    end
  end
end
