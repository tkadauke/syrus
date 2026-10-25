class MainBranchHealthCheck < ApplicationRecord
  include HasConfigurableRetention

  SOURCES = %w[ ci_poll grader_workflow concern_quorum ].freeze
  CONCLUSIVE_GRADER_HEALTH = %w[ healthy broken ].freeze
  SETTLED_CI_HEALTH = %w[ healthy broken not_configured inconclusive ].freeze
  SETTLED_GRADER_HEALTH = %w[ healthy broken inconclusive ].freeze

  configurable_retention setting_key: :main_branch_health_check_retention_days, unit: :days

  belongs_to :repository
  belongs_to :workflow, optional: true

  before_validation :default_branch

  validates :sha, presence: true
  validates :branch, presence: true
  validates :checked_at, presence: true
  validates :source, presence: true, inclusion: { in: SOURCES }

  scope :recent, -> { order(checked_at: :desc) }
  scope :pruneable, -> {
    cutoff = retention_cutoff
    cutoff ? where(checked_at: ..cutoff) : none
  }

  def health
    return "broken" if ci_health == "broken" || grader_health == "broken"
    return "healthy" if grader_health == "healthy" && ci_health.in?(%w[healthy not_configured])
    return "inconclusive" if grader_health == "inconclusive" || ci_health == "inconclusive"

    "unknown"
  end

  private def default_branch
    self.branch ||= repository&.default_branch
  end

  def self.conclusive_grader_result_exists?(repository:, sha:, branch: repository.default_branch)
    where(
      repository: repository,
      branch: branch,
      sha: sha,
      grader_health: CONCLUSIVE_GRADER_HEALTH
    ).exists?
  end

  def self.settled_ci_result_exists?(repository:, sha:, branch: repository.default_branch)
    where(
      repository: repository,
      branch: branch,
      sha: sha,
      ci_health: SETTLED_CI_HEALTH
    ).exists?
  end

  def self.broken_ci_result_exists?(repository:, sha:, branch: repository.default_branch)
    where(repository: repository, branch: branch, sha: sha, ci_health: "broken").exists?
  end

  def self.settled_grader_result_exists?(repository:, sha:, branch: repository.default_branch)
    where(
      repository: repository,
      branch: branch,
      sha: sha,
      grader_health: SETTLED_GRADER_HEALTH
    ).exists?
  end

  def self.broken_grader_result_exists?(repository:, sha:, branch: repository.default_branch)
    where(repository: repository, branch: branch, sha: sha, grader_health: "broken").exists?
  end

  def self.record_ci_poll(repository:, sha:, ci_health:, ci_failed_checks: nil, branch: repository.default_branch)
    existing = where(repository: repository, branch: branch, sha: sha)
                 .where.not(source: "concern_quorum")
                 .recent
                 .first

    if existing
      existing.update!(ci_health: ci_health, ci_failed_checks: ci_failed_checks, checked_at: Time.current)
      return existing
    end

    create!(
      repository: repository,
      branch: branch,
      sha: sha,
      checked_at: Time.current,
      ci_health: ci_health,
      grader_health: branch == repository.default_branch ? repository.grader_health : "unknown",
      ci_failed_checks: ci_failed_checks,
      grader_failed_names: nil,
      source: "ci_poll"
    )
  end

  def self.record_grader_workflow(repository:, sha:, grader_health:, grader_failed_names: nil, workflow: nil, branch: repository.default_branch)
    existing = where(repository: repository, branch: branch, sha: sha)
                 .where.not(source: "concern_quorum")
                 .recent
                 .first

    if existing
      existing.update!(
        grader_health: grader_health,
        grader_failed_names: grader_failed_names,
        workflow: workflow,
        checked_at: Time.current
      )
      return existing
    end

    create!(
      repository: repository,
      branch: branch,
      workflow: workflow,
      sha: sha,
      checked_at: Time.current,
      ci_health: branch == repository.default_branch ? repository.ci_health : "unknown",
      grader_health: grader_health,
      ci_failed_checks: nil,
      grader_failed_names: grader_failed_names,
      source: "grader_workflow"
    )
  end

  def self.record_concern_quorum(repository:, sha:, grader_failed_names: nil, branch: repository.default_branch)
    create!(
      repository: repository,
      branch: branch,
      sha: sha,
      checked_at: Time.current,
      ci_health: repository.ci_health,
      grader_health: "broken",
      ci_failed_checks: nil,
      grader_failed_names: grader_failed_names,
      source: "concern_quorum"
    )
  end
end
