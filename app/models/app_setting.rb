class AppSetting < ApplicationRecord
  DEFAULT_REPORT_ISSUE_REPO_SLUG = "tkadauke/syrus".freeze

  CLEARABLE_SECRETS = {}.freeze

  MODES = %w[advanced simple].freeze
  WORKFLOW_ADMISSION_POLICIES = %w[whole_workflow phase_aware].freeze

  AppSettingRegistry.definitions.each do |definition|
    next unless definition.numericality_options

    validates definition.key, numericality: definition.numericality_options
  end
  validates :rebase_failure_cooldown_minutes, numericality: {
    only_integer: true,
    greater_than_or_equal_to: 0
  }
  validates :workflow_admission_control_enabled, inclusion: { in: [ true, false ] }
  validates :workflow_admission_policy, inclusion: { in: WORKFLOW_ADMISSION_POLICIES }
  validates :mode, inclusion: { in: MODES }

  belongs_to :workflow_admission_control_changed_by_user, class_name: "User", optional: true

  encrypts :github_app_private_key_pem

  # Singleton row. .current returns the only record, creating it if missing.
  # On the very first create (fresh database), SYRUS_BOOT_POLLING_PAUSED seeds
  # polling paused — a side-by-side test stack sets it in its .env so it does
  # not race the production stack to file Jobs on the same repos. It seeds the
  # DB row ONCE, so the operator can still unpause from the admin console when
  # they intend the test stack to work real repositories.
  def self.current
    first || create!(polling_paused: boot_polling_paused_default)
  end

  # Only true when SYRUS_BOOT_POLLING_PAUSED is an explicitly truthy value;
  # otherwise the column's own `default: false` applies. Whitelisted (not
  # ActiveModel::Type::Boolean, which casts every unrecognized non-empty
  # string — including "no"/"off"/"disabled" — to true) so a fresh production
  # boot cannot be seeded paused by an "obviously falsy" env value.
  BOOT_TRUTHY_VALUES = %w[1 true yes on].freeze

  def self.boot_polling_paused_default
    BOOT_TRUTHY_VALUES.include?(ENV["SYRUS_BOOT_POLLING_PAUSED"].to_s.strip.downcase)
  end

  def self.mode
    current.mode
  end

  def self.simple?
    current.simple?
  end

  def self.advanced?
    current.advanced?
  end

  def self.mode_configured?
    current.mode_configured_at.present?
  end

  def simple?
    mode == "simple"
  end

  def advanced?
    mode == "advanced"
  end

  def self.signups_open?
    current.signups_open
  end

  # 0 = unlimited.
  def self.max_concurrent_agent_runs
    current.max_concurrent_agent_runs
  end

  def self.proactive_rebase_commit_threshold
    current.proactive_rebase_commit_threshold
  end

  def self.rebase_failure_cooldown_minutes
    current.rebase_failure_cooldown_minutes
  end

  def self.workflow_admission_control_enabled?
    current.workflow_admission_control_enabled
  end

  def self.workflow_admission_policy
    current.workflow_admission_policy.presence_in(WORKFLOW_ADMISSION_POLICIES) || "whole_workflow"
  end

  def self.workflow_admission_phase_aware?
    workflow_admission_policy == "phase_aware"
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

  # Instance-wide ceiling on total retained Coding-Mode chat checkout bytes
  # (the writable full clone + installed deps, ~1-2 GB each). 0 disables the
  # size cap; the idle-reclaim window (ChatWorkspace::RECLAIM_IDLE_CODING_AFTER)
  # still applies. Enforced by ChatWorkspace.reclaim_coding_over_budget! via
  # LRU eviction of the least-recently-active checkouts.
  def self.chat_coding_workspace_budget_bytes
    mb = current.chat_coding_workspace_budget_mb
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
