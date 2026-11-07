module ReviewerTargets
  class ResolutionError < StandardError
    def deterministic? = true
  end
  PluginUnavailable = Class.new(ResolutionError)
  TargetUnavailable = Class.new(ResolutionError)
  DuplicateTarget = Class.new(ResolutionError)

  module_function

  def options(user:, repository: nil)
    providers.flat_map { |provider| provider.options(user: user, repository: repository) }
  end

  def resolve(payload, owner:, repository:)
    target = payload.to_h.deep_stringify_keys
    provider = provider_for(target["type"])
    raise PluginUnavailable, "reviewer target plugin is unavailable" unless provider

    resolution = provider.resolve(reference: target["reference"], owner: owner, repository: repository)
    unless provider.available?(resolution:, owner:, repository:)
      raise TargetUnavailable, "reviewer target is unavailable"
    end
    resolution
  rescue ActiveRecord::RecordNotFound => e
    raise TargetUnavailable, e.message
  end

  def snapshot(payload, owner:, repository:)
    provider = provider_for(payload.to_h.deep_stringify_keys["type"])
    resolution = resolve(payload, owner: owner, repository: repository)
    {
      "type" => resolution.fetch(:type),
      "reference" => resolution.fetch(:reference).to_s,
      "display" => provider.audit_snapshot(resolution:).deep_stringify_keys,
      "uniqueness_key" => provider.uniqueness_key(resolution:).to_s
    }
  end

  def validate_panel!(payloads, owner:, repository:)
    snapshots = payloads.map { |payload| snapshot(payload, owner:, repository:) }
    keys = snapshots.map { |snapshot| snapshot.fetch("uniqueness_key") }
    raise DuplicateTarget, "reviewer panel contains duplicate targets" if keys.uniq.length != keys.length

    snapshots
  end

  def providers = Syrus::PluginRegistry.providers_for(:reviewer_target_provider)
  def provider_for(type) = providers.find { |candidate| candidate.target_type == type }
end
