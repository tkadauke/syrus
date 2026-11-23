# frozen_string_literal: true

module Syrus
  module Plugin
    # Agent-facing tools, permission declarations, run context, and credentials.
    module Toolkit
      ReturnShape = Data.define(:description, :validator) do
        def valid?(value) = validator.call(value)
      end

      OPTIONAL_PROVIDER = ReturnShape.new(
        description: "Module or nil",
        validator: ->(value) { value.nil? || value.is_a?(Module) }
      )
      ProbeRegistration = Data.define(:credential, :handler)
      PROBE_REGISTRATIONS = ReturnShape.new(
        description: "Array<ProbeRegistration>",
        validator: ->(value) { value.is_a?(Array) && value.all? { |entry| entry.is_a?(ProbeRegistration) } }
      )
      EXTRACTORS = ReturnShape.new(
        description: "Array<secret extractor>",
        validator: ->(value) { value.is_a?(Array) && value.all? { |entry| entry.respond_to?(:call) } }
      )

      class LegacyAdapter
        def initialize(capability) = @capability = capability

        def dispatch(provider, context)
          case @capability
          when :workflow_tools, :chat_tools, :permissions
            provider
          when :run_context
            provider.context_attributes(run: context.run, role: context.role)
          end
        end

        def available_for?(provider, repository)
          selected = provider.workflow_tools(Context::ToolkitDiscoveryContext.new)
          selected&.available_for?(repository) || false
        end

        def tool_definitions(provider, ...)
          selected = provider.public_send(@capability, Context::ToolkitDiscoveryContext.new)
          selected ? selected.tool_definitions(...) : []
        end

        def context_attributes(provider, run:, role:)
          provider.run_context(Context::ToolkitRunContext.new(run:, role:))
        end

        def method_missing(name, provider, ...)
          selected = provider.public_send(@capability, Context::ToolkitDiscoveryContext.new)
          return super unless selected&.respond_to?(name)

          selected.public_send(name, ...)
        end

        def respond_to_missing?(name, _private = false) = name.to_sym != :key
      end

      # Builds a reload-safe provider class whose referenced plugin constants are
      # resolved only when the capability is invoked.
      def self.provider(key:, display_name:, workflow_tools: nil, chat_tools: nil,
        permissions: nil, run_context: nil, credential_probes: {}, secret_extractors: [])
        implementations = [ workflow_tools, chat_tools, permissions, run_context,
          *credential_probes.values, *secret_extractors ].compact.freeze
        Class.new do
          define_singleton_method(:key) { key.to_s }
          define_singleton_method(:display_name) { display_name.to_s }
          define_singleton_method(:owns_implementation?) do |candidate|
            candidate_class = candidate.is_a?(Class) ? candidate : candidate.class
            implementations.any? do |implementation|
              implementation.is_a?(String) ? implementation == candidate_class.name :
                implementation.equal?(candidate) || implementation == candidate_class
            end
          end
          define_singleton_method(:workflow_tools) do |context|
            context.enabled && workflow_tools ? Object.const_get(workflow_tools) : nil
          end
          define_singleton_method(:chat_tools) do |context|
            context.enabled && chat_tools ? Object.const_get(chat_tools) : nil
          end
          define_singleton_method(:permissions) do |context|
            context.enabled && permissions ? Object.const_get(permissions) : nil
          end
          define_singleton_method(:run_context) do |context|
            context.enabled && run_context ? Object.const_get(run_context).context_attributes(run: context.run, role: context.role) : {}
          end
          define_singleton_method(:credential_probes) do |context|
            next [] unless context.enabled
            credential_probes.map do |credential, name|
              ProbeRegistration.new(credential: credential.to_s, handler: name.is_a?(String) ? Object.const_get(name) : name)
            end
          end
          define_singleton_method(:secret_extractors) do |context|
            next [] unless context.enabled
            secret_extractors.map { |name| name.is_a?(String) ? Object.const_get(name) : name }
          end
        end
      end

      def self.workflow_tool_sets
        Dispatch.call(:toolkit, :workflow_tools, Context::ToolkitDiscoveryContext.new).compact
      end

      def self.chat_tool_sets
        Dispatch.call(:toolkit, :chat_tools, Context::ToolkitDiscoveryContext.new).compact
      end

      def self.permission_providers
        Dispatch.call(:toolkit, :permissions, Context::ToolkitDiscoveryContext.new).compact
      end

      def self.run_context_attributes(run:, role:)
        Dispatch.call(:toolkit, :run_context, Context::ToolkitRunContext.new(run:, role:))
      end

      def self.credential_probes(user: nil)
        Dispatch.call(:toolkit, :credential_probes, Context::ToolkitCredentialContext.new(user:)).each_with_object({}) do |entry, probes|
          raise ArgumentError, "credential probe #{entry.credential.inspect} is registered by more than one provider" if probes.key?(entry.credential)
          probes[entry.credential] = entry.handler
        end
      end

      def self.secret_extractors(user: nil)
        Dispatch.call(:toolkit, :secret_extractors, Context::ToolkitCredentialContext.new(user:)).flatten.uniq
      end

      def self.provider_for_manifest(manifest)
        declaration = manifest.family_provides.find { |entry| entry.family == :toolkit }
        declaration && Object.const_get(declaration.provider)
      end

      def self.chat_tool_set_for(manifest)
        provider = provider_for_manifest(manifest)
        provider&.chat_tools(Context::ToolkitDiscoveryContext.new)
      end
    end

    Toolkit::DEFINITION = Family.define(:toolkit) do
      shape :facet
      absorbs :mcp_tool_set, :chat_mcp_tool_set, :permission_provider, :mcp_run_context_contributor

      capability :workflow_tools, composition: :collect, absent: [], decline: nil, tier: :stable,
        context: Context::ToolkitDiscoveryContext, returns: Toolkit::OPTIONAL_PROVIDER
      capability :chat_tools, composition: :collect, absent: [], decline: nil, tier: :stable,
        context: Context::ToolkitDiscoveryContext, returns: Toolkit::OPTIONAL_PROVIDER
      capability :permissions, composition: :collect, absent: [], decline: nil, tier: :stable,
        context: Context::ToolkitDiscoveryContext, returns: Toolkit::OPTIONAL_PROVIDER
      capability :run_context, composition: :collect, absent: [], decline: {}, tier: :provisional,
        context: Context::ToolkitRunContext, returns: Hash
      capability :credential_probes, composition: :collect, absent: [], decline: [], tier: :stable,
        context: Context::ToolkitCredentialContext, returns: Toolkit::PROBE_REGISTRATIONS
      capability :secret_extractors, composition: :collect, absent: [], decline: [], tier: :stable,
        context: Context::ToolkitCredentialContext, returns: Toolkit::EXTRACTORS

      legacy :mcp_tool_set, capability: :workflow_tools, adapter: Toolkit::LegacyAdapter.new(:workflow_tools)
      legacy :chat_mcp_tool_set, capability: :chat_tools, adapter: Toolkit::LegacyAdapter.new(:chat_tools)
      legacy :permission_provider, capability: :permissions, adapter: Toolkit::LegacyAdapter.new(:permissions)
      legacy :mcp_run_context_contributor, capability: :run_context, adapter: Toolkit::LegacyAdapter.new(:run_context)
    end

    def Toolkit.restore_definition!
      Syrus::Plugin::Family.restore(Syrus::Plugin::Toolkit::DEFINITION)
    end
  end
end
