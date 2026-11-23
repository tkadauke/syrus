class JobVisibility
  class DuplicateRestriction < StandardError; end

  # Every registered restriction applies. Policy is fail-closed: a restriction
  # that cannot be evaluated (the provider errored, timed out, tripped its
  # circuit breaker, or returned an invalid value) hides every restricted Job
  # from non-admins instead of silently dropping out of the composition.
  def self.apply(scope, user:)
    return scope if user&.admin?

    restrictions = Syrus::Plugin::Policy.restrictions(:job_visibility_restrictions)
    return scope.none if Syrus::Plugin::Policy.fail_closed?(restrictions)

    origins = restrictions.map { |provider| provider.origin_key.to_s }
    duplicate = origins.tally.find { |_origin, count| count > 1 }&.first
    raise DuplicateRestriction, "multiple Job visibility restrictions are registered for #{duplicate.inspect}" if duplicate

    restrictions.reduce(scope) do |visible, provider|
      origin = provider.origin_key.to_s
      allowed_ids = provider.visible_origin_ids(user: user)
      visible.where.not(origin: origin).or(visible.where(origin: origin, origin_id: allowed_ids))
    end
  rescue DuplicateRestriction
    raise
  rescue StandardError => error
    Rails.logger.error("[JobVisibility] restriction failed closed: #{error.class}: #{error.message}")
    scope.none
  end
end
