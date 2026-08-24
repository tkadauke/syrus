module Syrus
  module Plugin
    # Canonical plugin category taxonomy — the single source of truth for the
    # category: kwarg on Syrus::PluginRegistry.register and for the
    # operator-facing label shown on /admin/plugins. Mirrors the
    # Workflow::TriggerKind / Step::Kind convention: one small registry backs
    # validation instead of scattering ad hoc category strings across plugin
    # engine initializers.
    module Category
      Entry = Data.define(:key, :label)

      ENTRIES = [
        Entry.new(key: "language",          label: "Language & framework intelligence"),
        Entry.new(key: "agent",             label: "Agent provider"),
        Entry.new(key: "input_source",      label: "Input source"),
        Entry.new(key: "mcp_tool_set",      label: "MCP tool set"),
        Entry.new(key: "platform_delivery", label: "Platform delivery"),
        Entry.new(key: "connectivity",      label: "Connectivity"),
        Entry.new(key: "observability",     label: "Observability"),
        Entry.new(key: "tooling",           label: "Tooling")
      ].freeze

      BY_KEY = ENTRIES.index_by(&:key).freeze

      module_function

      def values
        BY_KEY.keys.freeze
      end

      def valid?(key)
        BY_KEY.key?(key.to_s)
      end

      def fetch(key)
        BY_KEY.fetch(key.to_s) do
          raise ArgumentError, "unknown plugin category=#{key.inspect}"
        end
      end

      def label_for(key)
        BY_KEY[key.to_s]&.label
      end
    end
  end
end
