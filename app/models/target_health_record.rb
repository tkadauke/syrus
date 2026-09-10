class TargetHealthRecord < ApplicationRecord
  STATUSES = %w[ passed failed stale unknown timed_out cancelled skipped inconclusive ].freeze
  HEALTHY_STATUSES = %w[ passed skipped ].freeze
  UNHEALTHY_STATUSES = %w[ failed timed_out cancelled inconclusive ].freeze

  belongs_to :repository
  belongs_to :workflow, optional: true
  belongs_to :step, optional: true
  belongs_to :run, optional: true

  validates :target_label, :project_id, :commit_sha, :input_fingerprint,
    :command_fingerprint, :environment_fingerprint, :status, :checked_at,
    presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :target_label, length: { maximum: 255 }
  validates :project_id, length: { maximum: 128 }
  validates :commit_sha, :input_fingerprint, :command_fingerprint,
    :environment_fingerprint, length: { maximum: 64 }
  validates :repository_id, uniqueness: {
    scope: [
      :target_label,
      :commit_sha,
      :input_fingerprint,
      :command_fingerprint,
      :environment_fingerprint
    ]
  }

  after_initialize :default_json_columns, if: :new_record?

  scope :latest_first, -> { order(checked_at: :desc, created_at: :desc) }
  scope :for_lookup, ->(repository:, target_label:, commit_sha:, input_fingerprint:, command_fingerprint:, environment_fingerprint:) {
    where(
      repository: repository,
      target_label: target_label,
      commit_sha: commit_sha,
      input_fingerprint: input_fingerprint,
      command_fingerprint: command_fingerprint,
      environment_fingerprint: environment_fingerprint
    )
  }
  scope :passed, -> { where(status: "passed") }
  scope :failed, -> { where(status: "failed") }
  scope :stale, -> { where(status: "stale") }
  scope :unknown, -> { where(status: "unknown") }
  scope :healthy, -> { where(status: HEALTHY_STATUSES) }
  scope :unhealthy, -> { where(status: UNHEALTHY_STATUSES) }

  def self.latest_for(**lookup)
    for_lookup(**lookup).latest_first.first
  end

  def self.passed_for?(**lookup)
    for_lookup(**lookup).passed.exists?
  end

  def healthy?
    HEALTHY_STATUSES.include?(status)
  end

  def unhealthy?
    UNHEALTHY_STATUSES.include?(status)
  end

  private

  def default_json_columns
    self.artifacts ||= {}
    self.metadata ||= {}
  end
end
