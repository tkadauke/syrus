class MainBranchHealthCheck < ApplicationRecord
  SOURCES = %w[ ci_poll grader_workflow ].freeze
  CONCLUSIVE_GRADER_HEALTH = %w[ healthy broken ].freeze
  RETAIN_AFTER = 7.days

  belongs_to :repository
  belongs_to :workflow, optional: true

  validates :sha, presence: true
  validates :checked_at, presence: true
  validates :source, presence: true, inclusion: { in: SOURCES }

  scope :recent, -> { order(checked_at: :desc) }
  scope :pruneable, -> { where(checked_at: ..RETAIN_AFTER.ago) }

  def self.conclusive_grader_result_exists?(repository:, sha:)
    where(
      repository: repository,
      sha: sha,
      source: "grader_workflow",
      grader_health: CONCLUSIVE_GRADER_HEALTH
    ).exists?
  end

  def self.record_ci_poll(repository:, sha:, ci_health:, ci_failed_checks: nil)
    create!(
      repository: repository,
      sha: sha,
      checked_at: Time.current,
      ci_health: ci_health,
      grader_health: repository.grader_health,
      ci_failed_checks: ci_failed_checks,
      grader_failed_names: nil,
      source: "ci_poll"
    )
  end

  def self.record_grader_workflow(repository:, sha:, grader_health:, grader_failed_names: nil, workflow: nil)
    create!(
      repository: repository,
      workflow: workflow,
      sha: sha,
      checked_at: Time.current,
      ci_health: repository.ci_health,
      grader_health: grader_health,
      ci_failed_checks: nil,
      grader_failed_names: grader_failed_names,
      source: "grader_workflow"
    )
  end
end
