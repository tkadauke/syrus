module Coworkers
  class GrantCatalog
    POLICIES = %w[off queue confirm auto].freeze

    Descriptor = Data.define(:name, :label, :description, :maximum_policy, :tools,
      :scope_options_callback, :scope_label_callback, :valid_scope_callback) do
      def scopeable? = valid_scope_callback.present?
      def scope_options(user:) = scope_options_callback ? Array(scope_options_callback.call(user: user)) : []
      def scope_label(value) = scope_label_callback ? scope_label_callback.call(value) : value.to_s
      def valid_scope?(value, user:) = !scopeable? || valid_scope_callback.call(value, user: user)

      def as_json(user: nil, **)
        payload = { name: name, label: label, description: description,
                    maximum_policy: maximum_policy, tools: tools, scopeable: scopeable? }
        if scopeable? && user
          payload[:scope_options] = scope_options(user: user).map do |value|
            { value: value, label: scope_label(value) }
          end
        end
        payload
      end
    end

    class << self
      def all
        providers = ([ Coworkers::ChatToolSet ] + Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set)).uniq
        declarations = McpToolRegistry.coworker_grants + providers.flat_map do |provider|
            provider.respond_to?(:coworker_grants) ? Array(provider.coworker_grants) : []
          end
        descriptors = declarations.map { |declaration| build(declaration) }
        duplicates = descriptors.group_by(&:name).select { |_name, values| values.many? }.keys
        raise ArgumentError, "duplicate coworker grants: #{duplicates.join(', ')}" if duplicates.any?

        descriptors.sort_by(&:name).freeze
      end

      def fetch(name) = all.find { |descriptor| descriptor.name == name.to_s } || raise(KeyError, "unknown grant: #{name}")
      def names = all.map(&:name)

      def policy_allowed?(descriptor, policy)
        POLICIES.index(policy.to_s).to_i <= POLICIES.index(descriptor.maximum_policy).to_i
      end

      private

      def build(raw)
        attributes = raw.to_h.symbolize_keys
        maximum_policy = attributes.fetch(:maximum_policy).to_s
        raise ArgumentError, "invalid maximum policy: #{maximum_policy}" unless POLICIES.include?(maximum_policy)

        Descriptor.new(
          name: attributes.fetch(:name).to_s,
          label: attributes.fetch(:label).to_s,
          description: attributes.fetch(:description).to_s,
          maximum_policy: maximum_policy,
          tools: Array(attributes.fetch(:tools)).map(&:to_s).uniq.freeze,
          scope_options_callback: attributes[:scope_options],
          scope_label_callback: attributes[:scope_label],
          valid_scope_callback: attributes[:valid_scope]
        )
      end
    end
  end
end
