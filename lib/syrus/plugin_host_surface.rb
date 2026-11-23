require "yaml"

module Syrus
  class PluginHostSurface
    Entry = Data.define(:name, :reason) do
      def initialize(name:, reason: nil) = super
    end
    DEFAULT_PATH = Pathname.new(File.expand_path("../../config/plugin_host_surface.yml", __dir__))

    attr_reader :legacy_baseline

    def initialize(path: DEFAULT_PATH)
      data = YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}
      @legacy_baseline = Integer(data.fetch("legacy_baseline"))
      @entries = Array(data.fetch("constants")).map { |attributes| Entry.new(name: attributes.fetch("name").to_s, reason: attributes["reason"]&.to_s) }
      validate!
      @by_name = @entries.to_h { |entry| [ entry.name, entry ] }
    rescue KeyError, ArgumentError, TypeError => e
      raise ArgumentError, "invalid plugin host surface: #{e.message}"
    end

    def entries = @entries.dup
    def lookup(name) = @by_name[name.to_s]
    alias legacy_entries entries

    private

    def validate!
      duplicates = @entries.group_by(&:name).select { |_name, entries| entries.many? }.keys
      raise ArgumentError, "duplicate names: #{duplicates.join(', ')}" if duplicates.any?
    end
  end
end
