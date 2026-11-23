# frozen_string_literal: true

module Syrus
  module Plugin
    # Contributions used while composing and executing an interactive chat turn.
    module ChatIntegration
      ReturnShape = Data.define(:description, :validator) do
        def valid?(value) = validator.call(value)
      end
      OPTIONAL_PROVIDER = ReturnShape.new(
        description: "Module, Array<Module>, or nil",
        validator: ->(value) { value.nil? || value.is_a?(Module) || (value.is_a?(Array) && value.all? { |item| item.is_a?(Module) }) }
      )

      CAPABILITY_FOR_LEGACY = {
        chat_payload_contributor: :payload_contributors,
        chat_prompt_injector: :prompt_injectors,
        chat_media_source: :media_sources,
        chat_turn_orientation: :turn_orientations,
        chat_turn_finalizer: :turn_finalizers,
        chat_workspace_lifecycle: :workspace_lifecycles,
        chat_turn_lifecycle: :turn_lifecycles,
        chat_job_status_extension: :job_status_extensions,
        chat_identity_provider: :identity_providers,
        mentionable: :mentionables
      }.freeze

      class LegacyAdapter
        DELEGATED_METHODS = %i[
          chat_payload chat_payload_paths chat_payload_counts chat_message_payload
          chat_prompt_section chat_media_kind chat_media_exists? attach_chat_media list_chat_media
          chat_media_context chat_media_panel chat_turn_orientation after_chat_turn applies_to?
          prepare! finalize! new payload chat_identities chat_turn_identity chat_turn_trigger
          chat_search_ownership chat_group_ownership chat_message_presentations
          chat_status_contributions mentionables find_mentionable find_mentionable_by_handle
          share_candidates autocomplete_mentionables
        ].freeze
        def initialize(capability) = @capability = capability
        def dispatch(provider, _context) = provider
        def legacy_providers(provider)
          Array(provider.public_send(@capability, Context::ChatIntegrationContext.new)).compact
        end
        def method_missing(name, provider, ...)
          selected = provider.public_send(@capability, Context::ChatIntegrationContext.new)
          selected = selected.first if selected.is_a?(Array)
          return super unless selected&.respond_to?(name)
          selected.public_send(name, ...)
        end
        def respond_to_missing?(name, _private = false) = DELEGATED_METHODS.include?(name.to_sym)
      end

      def self.provider(key:, display_name:, **contributions)
        implementations = contributions.values.flatten.compact.freeze
        Class.new do
          define_singleton_method(:key) { key.to_s }
          define_singleton_method(:display_name) { display_name.to_s }
          define_singleton_method(:owns_implementation?) do |candidate|
            candidate_class = candidate.is_a?(Class) ? candidate : candidate.class
            implementations.any? { |item| item.is_a?(String) ? item == candidate_class.name : item.equal?(candidate_class) }
          end
          contributions.each do |capability, names|
            define_singleton_method(capability) do |context|
              next nil unless context.enabled
              resolved = Array(names).map { |name| name.is_a?(String) ? Object.const_get(name) : name }
              names.is_a?(Array) ? resolved : resolved.first
            end
          end
        end
      end

      def self.contributions(capability)
        Dispatch.call(:chat_integration, capability, Context::ChatIntegrationContext.new).flatten.compact
      end
    end

    ChatIntegration::DEFINITION = Family.define(:chat_integration, built_in: true) do
      shape :facet
      absorbs(*ChatIntegration::CAPABILITY_FOR_LEGACY.keys)
      ChatIntegration::CAPABILITY_FOR_LEGACY.each_value do |capability_name|
        capability capability_name, composition: :collect, absent: [], decline: nil, tier: :provisional,
          context: Context::ChatIntegrationContext, returns: ChatIntegration::OPTIONAL_PROVIDER
      end
      ChatIntegration::CAPABILITY_FOR_LEGACY.each do |legacy_point, capability_name|
        legacy legacy_point, capability: capability_name, adapter: ChatIntegration::LegacyAdapter.new(capability_name)
      end
    end

    def ChatIntegration.restore_definition! = Family.restore(ChatIntegration::DEFINITION)
  end
end
