module Syrus
  module Plugin
    # Canonical plugin category taxonomy -- the single source of truth for a
    # plugin's `category` and for the operator-facing label shown on
    # /admin/plugins.
    #
    # A category answers "what is this plugin FOR", never "which extension
    # point does it register". `mcp_tool_set` used to be a category as well as
    # an extension point, which put the memory store in a bucket named after a
    # mechanism it only incidentally uses; `agent_capability` is the question
    # an operator scanning the list is actually asking. Mirrors the
    # Workflow::TriggerKind / Step::Kind convention: one small registry backs
    # validation instead of scattering ad hoc category strings across plugin
    # engine initializers.
    module Category
      Entry = Data.define(:key, :label)

      ENTRIES = [
        Entry.new(key: "language",          label: "Language & framework intelligence"),
        Entry.new(key: "agent_provider",    label: "Agent provider"),
        Entry.new(key: "agent_capability",  label: "Agent capability"),
        Entry.new(key: "input_source",      label: "Input source"),
        Entry.new(key: "platform_delivery", label: "Platform delivery"),
        Entry.new(key: "connectivity",      label: "Connectivity"),
        Entry.new(key: "observability",     label: "Observability"),
        Entry.new(key: "collaboration",     label: "Collaboration"),
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
