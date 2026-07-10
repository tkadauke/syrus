class AppSetting < ApplicationRecord
  DEFAULT_REPORT_ISSUE_REPO_SLUG = "tkadauke/syrus".freeze

  CLEARABLE_SECRETS = {}.freeze

  validates :grade_max_iterations, numericality: {
    only_integer: true,
    greater_than_or_equal_to: 1,
    less_than_or_equal_to: 10
  }
  validates :adversarial_review_rounds, numericality: {
    only_integer: true,
    greater_than_or_equal_to: 0,
    less_than_or_equal_to: 10
  }
  # Retention must be >= 1 day: 0 or negative makes the prune cutoff
  # (`video_retention_days.days.ago`) land at/after now, which would purge
  # EVERY stored walkthrough video instance-wide. There is no "keep forever"
  # via 0 — the size budget is the way to relax the cap.
  validates :video_retention_days, numericality: {
    only_integer: true,
    greater_than_or_equal_to: 1
  }
  # 0 = unlimited (size cap disabled); negatives are meaningless.
  validates :video_storage_budget_mb, numericality: {
    only_integer: true,
    greater_than_or_equal_to: 0
  }
  validates :main_concern_report_threshold, numericality: {
    only_integer: true,
    greater_than_or_equal_to: 1
  }

  encrypts :github_app_private_key_pem

  # Singleton row. .current returns the only record, creating it if missing.
  def self.current
    first || create!
  end

  def self.signups_open?
    current.signups_open
  end

  def self.max_job_failures
    current.max_job_failures
  end

  def self.grade_max_iterations
    current.grade_max_iterations
  end

  def self.adversarial_review_rounds
    current.adversarial_review_rounds
  end

  def self.main_concern_report_threshold
    current.main_concern_report_threshold
  end

  # Epic merge-train (see docs/plans/landing-merge-train.md). Default
  # off; landing keeps the per-Job auto_merge path until enabled.
  def self.merge_train_enabled?
    current.merge_train_enabled
  end

  def self.merge_train_max_size
    current.merge_train_max_size
  end

  # Walkthrough-video media management. The analysis + screenshots persist
  # forever (they're the value); only the heavy video is time- and
  # size-bounded by VideoWalkthroughPruneJob.
  def self.video_retention_days
    current.video_retention_days
  end

  # Instance-wide ceiling on total stored walkthrough-video bytes. 0 disables
  # the size cap (time-based retention still applies).
  def self.video_storage_budget_bytes
    mb = current.video_storage_budget_mb
    mb.to_i.positive? ? mb * 1024 * 1024 : 0
  end

  def self.report_issue_repo_slug
    current.report_issue_repo_slug.presence || DEFAULT_REPORT_ISSUE_REPO_SLUG
  end

  # Operator-console kill switches. Polling jobs and RunJob check
  # these and short-circuit / re-enqueue when set. Used to halt
  # the system safely during incident response without hard-killing
  # workers.
  def self.polling_paused?
    current.polling_paused
  end

  def self.runs_paused?
    current.runs_paused
  end

  def self.auto_merge_paused?
    ActiveModel::Type::Boolean.new.cast(ENV["SYRUS_AUTO_MERGE_DISABLED"])
  end

  def self.github_app_registered?
    current.github_app_registered?
  end

  def self.clearable_secrets
    CLEARABLE_SECRETS.select { |key, _label| column_names.include?(key) }
  end

  def github_app_registered?
    github_app_id.present?
  end

  def clear_secret!(secret)
    secret = secret.to_s
    raise ArgumentError, "Unknown secret: #{secret}" unless self.class.clearable_secrets.key?(secret)

    update!(secret => nil)
  end
end
