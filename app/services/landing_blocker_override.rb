class LandingBlockerOverride
  # `pr_checks_failing_inherited` is deliberately NOT here. A Job whose every
  # failing check is already failing on its base did not cause that breakage, so
  # an operator who has looked at the evidence (surfaced on the Job page and in
  # the landing-queue payload) may land it. `pr_checks_failing` -- a failure this
  # Job introduced -- stays non-overridable.
  NON_OVERRIDABLE_KEYS = %w[
    approval_not_satisfied
    missing_pull_request
    pr_checks_failing
    pr_checks_pending
    credentials_unavailable
  ].freeze

  def self.overridable?(key)
    key.to_s.present? && !NON_OVERRIDABLE_KEYS.include?(key.to_s)
  end

  # The parameters that identify one instance of a blocker, in the shape
  # stored on the Job when the override is granted: string keys, nil when the
  # blocker has none. `reason` is a landing-queue blocked reason, with symbol
  # or string keys.
  def self.params_for(reason)
    reason = reason.to_h
    normalize_params(reason[:params] || reason["params"])
  end

  def self.normalize_params(params)
    params = params.to_h.deep_stringify_keys.transform_values { |value| value.is_a?(Symbol) ? value.to_s : value }
    params.presence
  end
end
