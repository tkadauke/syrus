module ReviewerTargets
  ResolutionError = Class.new(StandardError)

  module_function

  def options(user:, repository: nil)
    providers.flat_map { |provider| provider.options(user: user, repository: repository) }
  end

  def resolve(payload, owner:, repository:)
    target = payload.to_h.deep_stringify_keys
    provider = providers.find { |candidate| candidate.target_type == target["type"] }
    raise ResolutionError, "reviewer target plugin is unavailable" unless provider

    provider.resolve(reference: target["reference"], owner: owner, repository: repository)
  rescue ActiveRecord::RecordNotFound => e
    raise ResolutionError, e.message
  end

  def snapshot(payload, owner:, repository:)
    resolution = resolve(payload, owner: owner, repository: repository)
    {
      "type" => resolution.fetch(:type),
      "reference" => resolution.fetch(:reference).to_s,
      "display" => resolution.fetch(:display),
      "record_type" => resolution.fetch(:record).class.polymorphic_name,
      "record_id" => resolution.fetch(:record).id
    }
  end

  def providers = Syrus::PluginRegistry.providers_for(:reviewer_target_provider)
end
