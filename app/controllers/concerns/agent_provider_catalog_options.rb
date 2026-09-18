module AgentProviderCatalogOptions
  EFFORT_LEVEL_OPTIONS = %w[ none low medium high ].freeze

  private

  def agent_provider_catalog_options(user = Current.user)
    {
      agent_providers: User.agent_providers.map { |provider| agent_provider_option_json(provider, user: user) },
      effort_levels: EFFORT_LEVEL_OPTIONS.map { |value| { value: value, label: value.titleize } }
    }
  end

  def agent_provider_option_json(provider, user:)
    provider_class = AgentProviders.for(provider)
    {
      value: provider,
      label: agent_provider_label(provider),
      configured: user.agent_provider_configured?(provider),
      models: Array(provider_class.available_models).map { |model| agent_provider_model_json(model) }
    }
  rescue AgentProviders::ConfigurationError
    {
      value: provider,
      label: provider,
      configured: false,
      models: []
    }
  end

  def agent_provider_model_json(model)
    {
      id: model.respond_to?(:id) ? model.id : model.to_s,
      label: model.respond_to?(:display_name) ? model.display_name : model.to_s,
      context_window: model.respond_to?(:context_window) ? model.context_window : nil,
      cost_tier: model.respond_to?(:cost_tier) ? model.cost_tier : nil
    }.compact
  end

  def agent_provider_label(provider)
    ::App::Presentation.agent_provider_label(provider)
  end
end
