class LandingBlockerOverride
  # `pr_checks_failing_inherited` is deliberately NOT here. A Job whose every
  # failing check is already failing on its base did not cause that breakage, so
  # an operator who has looked at the evidence (surfaced on the Job page and in
  # the landing-queue payload) may land it. `pr_checks_failing` -- a failure this
  # Job introduced -- stays non-overridable.
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
