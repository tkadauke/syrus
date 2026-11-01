module Coworkers
  class GrantCatalog
    POLICY_RANK = { "off" => 0, "queue" => 1, "confirm" => 2, "auto" => 3 }.freeze

    Descriptor = Data.define(:name, :label, :description, :default_policy, :maximum_policy, :tools,
      :scope_options_callback, :scope_label_callback, :valid_scope_callback, :privileged) do
      def initialize(default_policy: "confirm", privileged: false, **attributes) = super(default_policy: default_policy, privileged: privileged, **attributes)
      def scopeable? = scope_options_callback.present?
      def scope_options(user:) = scopeable? ? Array(scope_options_callback.call(user: user)) : []
      def scope_label(value) = scope_label_callback.call(value)
      def valid_scope?(value, user:) = scopeable? ? valid_scope_callback.call(value, user: user) : value.nil?
      def as_json(user: nil, **)
        availability = Coworkers::PrivilegedGrantGate.availability(self)
        payload = { name: name, label: label, description: description, default_policy: default_policy, maximum_policy: maximum_policy,
                    tools: tools, scopeable: scopeable?, privileged: privileged, available: availability.available?,
                    unavailable_reason: availability.reason }
        payload[:scope_options] = scope_options(user: user).map { |value| { value: value, label: scope_label(value) } } if scopeable? && user
        payload
      end
    end

    class << self
      def all
        (core_descriptors + plugin_descriptors).index_by(&:name).values.freeze
      end

      def names = all.map(&:name)
      def fetch(name) = all.index_by(&:name).fetch(name.to_s)

      def policy_allowed?(descriptor, policy)
        POLICY_RANK.fetch(policy.to_s) <= POLICY_RANK.fetch(descriptor.maximum_policy)
      rescue KeyError
        false
      end

      private

      def core_descriptors
        grouped = McpToolRegistry.entries(surface: :coworker).group_by { |entry| entry.capability.to_s }
        legacy = Coworkers::Create::DEFAULT_GRANTS.keys.map do |name|
          entries = grouped.fetch(name, [])
          next if name.blank?
          Descriptor.new(name: name, label: name.humanize, description: name.humanize,
            default_policy: Coworkers::Create::DEFAULT_GRANTS.fetch(name, "confirm"), maximum_policy: "auto", tools: entries.map(&:tool_name), scope_options_callback: nil,
            scope_label_callback: nil, valid_scope_callback: nil, privileged: false)
        end
        legacy + McpToolRegistry.coworker_grants.map { |attributes| build_descriptor(attributes) }
      end

      def plugin_descriptors
        Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set).flat_map do |provider|
          provider.respond_to?(:coworker_grants) ? Array(provider.coworker_grants) : []
        end.map { |attributes| build_descriptor(attributes) }
      end

      def build_descriptor(attributes)
        return attributes if attributes.is_a?(Descriptor)
        values = attributes.to_h.symbolize_keys
        Descriptor.new(**{ default_policy: "confirm" }.merge(values.slice(*Descriptor.members)))
      end
    end
  end
end
