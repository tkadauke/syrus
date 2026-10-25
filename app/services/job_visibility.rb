class JobVisibility
  class DuplicateRestriction < StandardError; end

  def self.apply(scope, user:)
    return scope if user&.admin?

    restrictions = Syrus::PluginRegistry.providers_for(:job_visibility_restriction)
    origins = restrictions.map { |provider| provider.origin_key.to_s }
    duplicate = origins.tally.find { |_origin, count| count > 1 }&.first
    raise DuplicateRestriction, "multiple Job visibility restrictions are registered for #{duplicate.inspect}" if duplicate

    restrictions.reduce(scope) do |visible, provider|
      origin = provider.origin_key.to_s
      allowed_ids = provider.visible_origin_ids(user: user)
      visible.where.not(origin: origin).or(visible.where(origin: origin, origin_id: allowed_ids))
    end
  end
end
