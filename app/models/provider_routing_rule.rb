class ProviderRoutingRule < ApplicationRecord
  SCOPE_TYPES = %w[ user repository ].freeze
  DEFAULT_TASK_KEY = "default".freeze

  validates :scope_type, presence: true, inclusion: { in: SCOPE_TYPES }
  validates :scope_id, presence: true
  validates :task_key, presence: true, uniqueness: { scope: [ :scope_type, :scope_id ] }
  validate :candidates_are_valid

  before_validation :normalize_candidates

  def scope_type_user? = scope_type == "user"
  def scope_type_repository? = scope_type == "repository"

  private

  def normalize_candidates
    self.candidates ||= []
  end

  def candidates_are_valid
    unless candidates.is_a?(Array)
      errors.add(:candidates, "must be an array of candidate objects")
      return
    end

    valid_providers = Syrus::PluginRegistry.providers_for(:agent_provider).map(&:provider_key)

    candidates.each_with_index do |candidate, index|
      validate_candidate(candidate, index, valid_providers)
    end
  end

  def validate_candidate(candidate, index, valid_providers)
    unless candidate.is_a?(Hash)
      errors.add(:candidates, "entry #{index} must be an object with a provider key")
      return
    end

    candidate = candidate.stringify_keys
    provider = candidate["provider"].presence

    if provider.blank?
      errors.add(:candidates, "entry #{index} is missing a provider")
      return
    end

    unless valid_providers.include?(provider)
      errors.add(:candidates, "entry #{index} has unknown provider #{provider.inspect}")
      return
    end

    validate_candidate_model(provider, candidate["model"], index) if candidate["model"].present?
  end

  # Soft check: only enforced once a provider actually exposes a model
  # catalog (the model-effort-plumbing Epic). No provider implements
  # `.available_models` yet, so this is a no-op today by design.
  def validate_candidate_model(provider, model, index)
    provider_class = AgentProviders.for(provider)
    return unless provider_class.respond_to?(:available_models)

    catalog = Array(provider_class.available_models)
    return if catalog.blank?
    return if catalog.include?(model)

    errors.add(:candidates, "entry #{index} has model #{model.inspect} not in #{provider}'s known models")
  rescue AgentProviders::ConfigurationError
    nil
  end
end
