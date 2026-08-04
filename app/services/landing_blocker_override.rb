class LandingBlockerOverride
  NON_OVERRIDABLE_KEYS = %w[
    missing_pull_request
    pr_checks_failing
    pr_checks_pending
    credentials_unavailable
  ].freeze

  def self.overridable?(key)
    key.to_s.present? && !NON_OVERRIDABLE_KEYS.include?(key.to_s)
  end
end
