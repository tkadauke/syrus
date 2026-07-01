class AppSetting < ApplicationRecord
  DEFAULT_REPORT_ISSUE_REPO_SLUG = "tkadauke/syrus".freeze

  CLEARABLE_SECRETS = {
    "telegram_bot_token" => "Telegram bot token",
    "telegram_webhook_secret" => "Telegram webhook secret"
  }.freeze

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

  # Epic merge-train (see docs/plans/landing-merge-train.md). Default
  # off; landing keeps the per-Job auto_merge path until enabled.
  def self.merge_train_enabled?
    current.merge_train_enabled
  end

  def self.merge_train_max_size
    current.merge_train_max_size
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
