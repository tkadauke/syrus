# frozen_string_literal: true

module Syrus
  module Plugin
    # User-interface contributions and filter registrations. Provider constants
    # stay lazy so catalog and health reads never have to load plugin app code.
    module Surface
      ReturnShape = Data.define(:description, :validator) do
        def valid?(value) = validator.call(value)
      end
      OPTIONAL_PROVIDER = ReturnShape.new(
        description: "Module, Array<Module>, or nil",
        validator: ->(value) { value.nil? || value.is_a?(Module) || (value.is_a?(Array) && value.all? { |item| item.is_a?(Module) }) }
      )
      FilterSubject = Data.define(:name, :model, :chips)
      FilterChips = Data.define(:subject, :chips)
      FILTER_SUBJECTS = ReturnShape.new(
        description: "Array<FilterSubject>",
        validator: ->(value) { value.is_a?(Array) && value.all? { |item| item.is_a?(FilterSubject) } }
      )
      FILTER_CHIPS = ReturnShape.new(
        description: "Array<FilterChips>",
        validator: ->(value) { value.is_a?(Array) && value.all? { |item| item.is_a?(FilterChips) } }
      )

      class LegacyAdapter
        DELEGATED_METHODS = %i[
          sidebar_pages admin_pages repo_page_tabs workspace_tabs available_for?
          ui_slots artifact_type renderer_type payload_schema viewer_kinds
        ].freeze
        def initialize(capability) = @capability = capability
        def dispatch(provider, context) = context.enabled ? provider : nil
        def method_missing(name, provider, ...)
          return super unless DELEGATED_METHODS.include?(name.to_sym)
          selected = provider.public_send(@capability, Context::SurfaceContext.new)
          selected = selected.first if selected.is_a?(Array)
          return super unless selected&.respond_to?(name)
          selected.public_send(name, ...)
        end
        def respond_to_missing?(name, _private = false) = DELEGATED_METHODS.include?(name.to_sym)
      end

      def self.provider(key:, display_name:, filter_subjects: {}, filter_chips: {}, **contributions)
        implementations = contributions.values.flatten.compact.freeze
        Class.new do
          define_singleton_method(:key) { key.to_s }
          define_singleton_method(:display_name) { display_name.to_s }
          define_singleton_method(:owns_implementation?) do |candidate|
            candidate_class = candidate.is_a?(Class) ? candidate : candidate.class
            implementations.any? do |implementation|
              implementation.is_a?(String) ? implementation == candidate_class.name : implementation.equal?(candidate_class)
            end
          end
          contributions.each do |capability, names|
            define_singleton_method(capability) do |context|
              next nil unless context.enabled
              resolved = Array(names).map { |name| name.is_a?(String) ? Object.const_get(name) : name }
              names.is_a?(Array) ? resolved : resolved.first
            end
          end
          define_singleton_method(:filter_subjects) do |context|
            next [] unless context.enabled
            filter_subjects.map do |name, definition|
              definition = definition.to_h.symbolize_keys
              model = definition.fetch(:model)
              chips = definition.fetch(:chips)
              FilterSubject.new(name: name.to_sym,
                model: model.is_a?(String) ? Object.const_get(model) : model,
                chips: chips.is_a?(String) ? Object.const_get(chips) : chips)
            end
          end
          define_singleton_method(:filter_chips) do |context|
            next [] unless context.enabled
            filter_chips.map do |subject, chips|
              FilterChips.new(subject: subject.to_sym, chips: chips.is_a?(String) ? Object.const_get(chips) : chips)
            end
          end
        end
      end

      def self.contributions(capability)
        Dispatch.call(:surface, capability, Context::SurfaceContext.new).flatten.compact
      end

      def self.filter_subjects = contributions(:filter_subjects)
      def self.filter_chips = contributions(:filter_chips)
    end

    Surface::DEFINITION = Family.define(:surface, built_in: true) do
      shape :facet
      absorbs :sidebar_page, :admin_page, :repo_page_tab, :workspace_tab, :ui_slot, :artifact_renderer, :preview_panel_viewer
      %i[sidebar_pages admin_pages repo_page_tabs workspace_tabs ui_slots artifact_renderers].each do |name|
        capability name, composition: :collect, absent: [], decline: nil, tier: :stable,
          context: Context::SurfaceContext, returns: Surface::OPTIONAL_PROVIDER
      end
      capability :preview_panel_viewers, composition: :collect, absent: [], decline: nil, tier: :provisional,
        context: Context::SurfaceContext, returns: Surface::OPTIONAL_PROVIDER
      capability :filter_subjects, composition: :collect, absent: [], decline: [], tier: :stable,
        context: Context::SurfaceContext, returns: Surface::FILTER_SUBJECTS
      capability :filter_chips, composition: :collect, absent: [], decline: [], tier: :stable,
        context: Context::SurfaceContext, returns: Surface::FILTER_CHIPS

      { sidebar_page: :sidebar_pages, admin_page: :admin_pages, repo_page_tab: :repo_page_tabs,
        workspace_tab: :workspace_tabs, ui_slot: :ui_slots, artifact_renderer: :artifact_renderers,
        preview_panel_viewer: :preview_panel_viewers }.each do |legacy_point, capability|
        legacy legacy_point, capability:, adapter: Surface::LegacyAdapter.new(capability)
      end
    end

    def Surface.restore_definition! = Family.restore(Surface::DEFINITION)
  end
end
