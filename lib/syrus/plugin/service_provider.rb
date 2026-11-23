# frozen_string_literal: true

module Syrus
  module Plugin
    # Shared declaration machinery for service families (AgentRuntime,
    # ExecutionBackend, RuntimeSession, SourceHost, SpeechToText).
    #
    # A service keeps its own large stateful interface module (for example
    # Syrus::Plugin::AgentProvider) as the contract. The family only reuses the
    # declaration, dispatch, legacy-bridge and conformance machinery: a plugin
    # declares one lightweight provider class per family, and each capability
    # returns the plugin's service class (or classes). Constants stay lazy, so
    # manifest and catalog reads never resolve plugin application code.
    module ServiceProvider
      # Capability name => owning family. Capability names equal the legacy
      # extension-point names the services were registered under.
      FAMILY_FOR = {
        agent_provider: :agent_runtime,
        chat_provider: :agent_runtime,
        execution_backend: :execution_backend,
        runtime_session_provider: :runtime_session,
        source_control_provider: :source_host,
        input_source: :source_host,
        repository_content_provider: :source_host,
        workspace_git_transport: :source_host,
        speech_to_text_provider: :speech_to_text
      }.freeze

      # A service class (or a directly registered legacy instance), an array of
      # them, or nil to decline. The service's own interface module is the
      # contract for what the class does.
      SERVICES = ContributionProvider::ReturnShape.new(
        description: "Service class or instance, Array of them, or nil",
        validator: ->(value) { value.is_a?(Array) ? value.none?(&:nil?) : true }
      )

      # Answers legacy lookups for family declarations and presents legacy
      # registrations to the dispatcher. Both directions hand back the service
      # class itself: it is the contract.
      class LegacyAdapter
        def initialize(capability) = @capability = capability

        def dispatch(provider, _context) = provider

        def legacy_providers(provider)
          Array(provider.public_send(@capability, Context::ServiceContext.new)).compact
        end
      end

      # Builds a reload-safe declaration provider. +services+ maps a capability
      # to a constant name (or array of names) resolved only when invoked.
      def self.build(key:, display_name:, **services)
        implementations = services.values.flatten.compact.freeze
        Class.new do
          define_singleton_method(:key) { key.to_s }
          define_singleton_method(:display_name) { display_name.to_s }
          define_singleton_method(:available_for?) { |context| context.enabled ? true : false }
          define_singleton_method(:owns_implementation?) do |candidate|
            candidate_class = candidate.is_a?(Class) ? candidate : candidate.class
            implementations.any? { |item| item.is_a?(String) ? item == candidate_class.name : item.equal?(candidate_class) }
          end
          services.each do |capability, names|
            raise ArgumentError, "Unknown service capability #{capability.inspect}" unless FAMILY_FOR.key?(capability)

            define_singleton_method(capability) do |context|
              next nil unless context.enabled

              interface = Syrus::PluginRegistry::INTERFACE_FOR.fetch(capability).call
              resolved = Array(names).map do |name|
                klass = name.is_a?(String) ? Object.const_get(name) : name
                klass.include(interface) unless klass.include?(interface)
                klass
              end
              names.is_a?(Array) ? resolved : resolved.first
            end
          end
        end
      end

      # Every service capability a family absorbs, declared the same way.
      def self.define_family(name, tiers:)
        Family.define(name, built_in: true) do
          shape :service
          absorbs(*tiers.keys)
          tiers.each do |capability_name, tier|
            capability capability_name, composition: :collect, absent: [], decline: nil, tier:,
              context: Context::ServiceContext, returns: SERVICES
          end
          tiers.each_key do |capability_name|
            legacy capability_name, capability: capability_name, adapter: LegacyAdapter.new(capability_name)
          end
        end
      end

      TIERS = {
        agent_runtime: { agent_provider: :stable, chat_provider: :stable },
        execution_backend: { execution_backend: :provisional },
        runtime_session: { runtime_session_provider: :stable },
        source_host: {
          source_control_provider: :provisional, input_source: :stable,
          repository_content_provider: :stable, workspace_git_transport: :provisional
        },
        speech_to_text: { speech_to_text_provider: :provisional }
      }.freeze

      DEFINITIONS = TIERS.to_h { |family, tiers| [ family, define_family(family, tiers:) ] }.freeze

      def self.restore_definitions! = DEFINITIONS.each_value { |definition| Family.restore(definition) }

      # The service classes one manifest contributes for +capability+: legacy
      # registrations plus family declarations. Used where a manifest is read
      # directly (disable guards, onboarding) rather than through dispatch.
      def self.for_manifest(manifest, capability)
        capability = capability.to_sym
        legacy = Array(manifest.provides[capability] || manifest.provides[capability.to_s])
        declared = manifest.family_provides.select { |declaration| declared?(declaration, capability) }.flat_map do |declaration|
          Array(Object.const_get(declaration.provider).public_send(capability, Context::ServiceContext.new))
        rescue StandardError, ScriptError => error
          Rails.logger.warn("[Plugin::ServiceProvider] #{manifest.name} #{declaration.provider}.#{capability}: #{error.class}: #{error.message}")
          []
        end
        (legacy + declared).compact.uniq
      end

      def self.declared?(declaration, capability)
        FAMILY_FOR[capability.to_sym] == declaration.family && declaration.capabilities.include?(capability.to_sym)
      end

      # Every service class registered for +capability+, in plugin priority
      # order. Callers keep their own selection (by key, repository, or
      # request) on top of this list.
      def self.providers(capability)
        family = FAMILY_FOR.fetch(capability.to_sym)
        Dispatch.call(family, capability, Context::ServiceContext.new).flatten.compact
      end
    end
  end
end
